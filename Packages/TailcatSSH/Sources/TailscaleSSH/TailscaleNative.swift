import CTailcat
import Foundation
@_spi(EmbeddedTransport) import TailcatSSH

protocol TailscaleNativeAPI: Sendable {
    func makeNode(_ configuration: TailscaleNodeConfiguration) throws -> UInt64
    func start(node: UInt64, token: UInt64) throws
    func status(node: UInt64, token: UInt64) throws -> TailscaleNodeStatus
    func startLogin(node: UInt64, token: UInt64) throws
    func logout(node: UInt64, token: UInt64) throws
    func dial(node: UInt64, token: UInt64, host: String, port: UInt16) throws -> any BlockingByteStream
    func closeNode(_ node: UInt64)
}

struct LiveTailscaleNativeAPI: TailscaleNativeAPI {
    func makeNode(_ configuration: TailscaleNodeConfiguration) throws -> UInt64 {
        guard mt_abi_version() == 1, tc_abi_version() == 1 else { throw TailscaleSSHTransportError.unsupportedABI }
        let data = try JSONSerialization.data(withJSONObject: [
            "state_directory": configuration.stateDirectory.path,
            "hostname": configuration.hostname,
            "control_url": configuration.controlURL.absoluteString
        ])
        let json = String(decoding: data, as: UTF8.self)
        var node: UInt64 = 0
        let status = configuration.stateEncryptionKey.withUnsafeBytes { key in
            json.withCString {
                mt_node_new(UnsafeMutablePointer(mutating: $0),
                            UnsafeMutablePointer(mutating: key.bindMemory(to: UInt8.self).baseAddress), key.count, &node, nil)
            }
        }
        do { try Self.check(status, operation: .createNode) }
        catch { if node != 0 { tc_close(node, nil) }; throw error }
        guard node != 0 else { throw TailscaleSSHTransportError.invalidNativeStatus }
        return node
    }

    func start(node: UInt64, token: UInt64) throws {
        try Self.check(mt_node_start(node, token, nil), operation: .start)
    }

    func status(node: UInt64, token: UInt64) throws -> TailscaleNodeStatus {
        var output: UnsafeMutablePointer<CChar>?
        let status = mt_node_status(node, token, &output, nil)
        defer { tc_free(output) }
        try Self.check(status, operation: .status)
        guard let output else { throw TailscaleSSHTransportError.invalidNativeStatus }
        return try TailscaleNodeStatus.decode(Data(String(cString: output).utf8))
    }

    func startLogin(node: UInt64, token: UInt64) throws {
        try Self.check(mt_node_start_login(node, token, nil), operation: .startLogin)
    }

    func logout(node: UInt64, token: UInt64) throws {
        try Self.check(mt_node_logout(node, token, nil), operation: .logout)
    }

    func dial(node: UInt64, token: UInt64, host: String, port: UInt16) throws -> any BlockingByteStream {
        var connection: UInt64 = 0
        let status = host.withCString { mt_node_dial(node, token, UnsafeMutablePointer(mutating: $0), port, &connection, nil) }
        do {
            try Self.check(status, operation: .dial)
            guard connection != 0 else { throw TailscaleSSHTransportError.invalidNativeStatus }
            return try TailscaleNativeConnection(handle: connection)
        } catch {
            if connection != 0 { tc_close(connection, nil) }
            throw error
        }
    }

    func closeNode(_ node: UInt64) { tc_close(node, nil) }

    static func check(_ status: Int32, operation: TailscaleNativeOperation) throws {
        switch status {
        case Int32(TC_OK): return
        case Int32(TC_CANCELLED): throw CancellationError()
        case Int32(MT_STORAGE_FAILURE): throw TailscaleSSHTransportError.storageUnavailable
        case Int32(MT_STATE_DECRYPT_FAILED): throw TailscaleSSHTransportError.invalidStoredState
        case Int32(MT_ALREADY_OPEN): throw TailscaleSSHTransportError.nodeAlreadyOpen
        case Int32(MT_AUTH_REQUIRED): throw TailscaleSSHTransportError.authenticationRequired
        case Int32(MT_APPROVAL_REQUIRED): throw TailscaleSSHTransportError.approvalRequired
        case Int32(TC_CLOSED): throw TailscaleSSHTransportError.connectionClosed
        case Int32(TC_INVALID_ARGUMENT) where operation == .dial: throw TailscaleSSHTransportError.invalidHost
        case Int32(TC_INVALID_ARGUMENT) where operation == .createNode: throw TailscaleSSHTransportError.invalidConfiguration
        default: throw TailscaleSSHTransportError.nativeFailure(operation: operation, code: status)
        }
    }
}

/// Synchronous C calls run on workers. Cancellation is a native token, never a
/// detached Swift task that leaves the original C call running unobserved.
final class TailscaleNativeAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var token: UInt64?

    func cancel() {
        lock.lock(); cancelled = true; let token = token; lock.unlock()
        if let token { tc_token_cancel(token, nil) }
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private func run<T>(timeout: Int64, operation: (UInt64) throws -> T, discard: (T) -> Void) throws -> T {
        if isCancelled() { throw CancellationError() }
        var token: UInt64 = 0
        try LiveTailscaleNativeAPI.check(tc_token_new(timeout, &token, nil), operation: .createToken)
        lock.lock(); self.token = token; let alreadyCancelled = cancelled; lock.unlock()
        defer {
            lock.lock(); self.token = nil; lock.unlock()
            tc_close(token, nil)
        }
        if alreadyCancelled { throw CancellationError() }
        let value = try operation(token)
        if isCancelled() { discard(value); throw CancellationError() }
        return value
    }

    static func perform<T: Sendable>(timeout: Int64,
                                    discard: @escaping @Sendable (T) -> Void = { _ in },
                                    _ operation: @escaping @Sendable (UInt64) throws -> T) async throws -> T {
        guard timeout > 0 else { throw TailscaleSSHTransportError.invalidTimeout }
        try Task.checkCancellation()
        let attempt = TailscaleNativeAttempt()
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try attempt.run(timeout: timeout, operation: operation, discard: discard) })
                }
            }
        } onCancel: { attempt.cancel() }
        if Task.isCancelled {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { discard(value); continuation.resume() }
            }
            throw CancellationError()
        }
        return value
    }
}

/// Node handles are not reused. Closing on a cleanup worker can safely race an
/// operation starting on another worker: the native registry rejects/interrupts
/// that call. Concurrent close callers all wait for actual native destruction.
final class TailscaleNodeResource: @unchecked Sendable {
    let api: any TailscaleNativeAPI
    private let lock = NSLock()
    private var node: UInt64?
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(node: UInt64, api: any TailscaleNativeAPI) { self.node = node; self.api = api }

    deinit {
        if let node {
            let api = api
            DispatchQueue.global(qos: .utility).async { api.closeNode(node) }
        }
    }

    func handle() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let node else { throw TailscaleSSHTransportError.connectionClosed }
        return node
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }; return node == nil
    }

    func close() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(); return }
            closeWaiters.append(continuation)
            guard let node else { lock.unlock(); return }
            self.node = nil
            lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                self.api.closeNode(node)
                self.lock.lock(); self.closed = true
                let waiters = self.closeWaiters; self.closeWaiters.removeAll(); self.lock.unlock()
                waiters.forEach { $0.resume() }
            }
        }
    }
}

final class TailscaleNativeConnection: BlockingByteStream, @unchecked Sendable {
    private let handle: UInt64
    private let token: UInt64
    private let lock = NSLock()
    private var closed = false
    private var pendingReadStatus: Int32?

    init(handle: UInt64) throws {
        self.handle = handle
        var token: UInt64 = 0
        try LiveTailscaleNativeAPI.check(tc_token_new(-1, &token, nil), operation: .createToken)
        self.token = token
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let pendingReadStatus {
            if pendingReadStatus == TC_EOF { return 0 }
            try LiveTailscaleNativeAPI.check(pendingReadStatus, operation: .read)
        }
        var count = 0
        let status = tc_conn_read(handle, token, buffer.baseAddress, buffer.count, &count, nil)
        if count > 0 {
            if status != TC_OK { pendingReadStatus = status }
            return count
        }
        if status == TC_EOF { return 0 }
        try LiveTailscaleNativeAPI.check(status, operation: .read)
        return count
    }

    func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            var count = 0
            let status = tc_conn_write(handle, token, UnsafeMutableRawPointer(mutating: buffer.baseAddress!.advanced(by: offset)),
                                       buffer.count - offset, &count, nil)
            offset += count
            try LiveTailscaleNativeAPI.check(status, operation: .write)
            guard count > 0 else { throw TailscaleSSHTransportError.connectionClosed }
        }
    }

    func cancel() { tc_token_cancel(token, nil) }

    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
        tc_token_cancel(token, nil); tc_close(handle, nil); tc_close(token, nil)
    }
}

/// An open stream retains the account node even if the caller releases its
/// reference. Explicit node.close() still closes every child native stream.
final class NodeBoundByteStream: BlockingByteStream, @unchecked Sendable {
    private let node: TailscaleNodeResource
    private let stream: any BlockingByteStream
    init(node: TailscaleNodeResource, stream: any BlockingByteStream) { self.node = node; self.stream = stream }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { try stream.read(into: buffer) }
    func writeAll(_ buffer: UnsafeRawBufferPointer) throws { try stream.writeAll(buffer) }
    func cancel() { stream.cancel() }
    func close() { stream.close() }
}
