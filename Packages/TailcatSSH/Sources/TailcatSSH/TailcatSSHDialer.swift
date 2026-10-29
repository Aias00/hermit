import Darwin
import Foundation
import NIOCore
import NIOPosix

public struct TailcatSSHDiagnosticEvent: Sendable {
    public enum Kind: String, Sendable { case dialStarted, tunnelConnected, streamActivated, connectionClosed }
    public let kind: Kind
    public let elapsedMilliseconds: UInt64
}

final class TailcatDiagnostics: @unchecked Sendable {
    private let started = DispatchTime.now().uptimeNanoseconds
    private let observer: (@Sendable (TailcatSSHDiagnosticEvent) -> Void)?
    init(_ observer: (@Sendable (TailcatSSHDiagnosticEvent) -> Void)?) { self.observer = observer }
    func record(_ kind: TailcatSSHDiagnosticEvent.Kind) {
        observer?(.init(kind: kind, elapsedMilliseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
    }
}

/// Owns one TCP stream, not the shared Tailcat node. Install SSH and its auth
/// observer before activate(): early server banners remain in bounded buffers.
public struct TailcatSSHConnection: Sendable {
    public let channel: any Channel
    private let bridge: SocketPairBridge

    init(channel: any Channel, bridge: SocketPairBridge) {
        self.channel = channel; self.bridge = bridge
    }

    public func activate() async throws {
        try Task.checkCancellation()
        guard channel.isActive else { throw TailcatSSHTransportError.connectionClosed }
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        bridge.diagnostics.record(.streamActivated)
        try Task.checkCancellation()
    }

    public func close() async {
        try? await channel.close().get()
        bridge.stop()
        await bridge.waitUntilClosed()
    }
}

public struct TailcatSSHDialer: Sendable {
    public init() {}

    /// Package-internal integration point shared by embedded network backends.
    /// It keeps activation gating, bounded buffering, and EOF ordering in one
    /// implementation. This does not create or own a Tailcat node.
    @_spi(EmbeddedTransport) public static func adaptByteStream(
        _ stream: any BlockingByteStream, on group: any EventLoopGroup,
        onDiagnostic: (@Sendable (TailcatSSHDiagnosticEvent) -> Void)? = nil
    ) async throws -> TailcatSSHConnection {
        try await adapt(stream: stream, on: group, diagnostics: TailcatDiagnostics(onDiagnostic))
    }

    public func connect(address: String, clientKey: String, port: Int,
                        on group: any EventLoopGroup, timeout: TimeAmount = .seconds(20),
                        onDiagnostic: (@Sendable (TailcatSSHDiagnosticEvent) -> Void)? = nil) async throws -> TailcatSSHConnection {
        _ = try TailcatIdentity.parseAddress(address)
        guard (1...65535).contains(port) else { throw TailcatSSHTransportError.invalidPort }
        guard timeout.nanoseconds > 0 else { throw TailcatSSHTransportError.invalidTimeout }
        try Task.checkCancellation()
        let diagnostics = TailcatDiagnostics(onDiagnostic)
        let attempt = NativeDialAttempt()
        diagnostics.record(.dialStarted)
        let stream: NativeConnection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try attempt.run(address: address, privateKey: clientKey, port: UInt16(port), timeout: timeout.nanoseconds)
                    })
                }
            }
        } onCancel: { attempt.cancel() }
        diagnostics.record(.tunnelConnected)
        return try await Self.adapt(stream: stream, on: group, diagnostics: diagnostics)
    }

    /// A socketpair has no filesystem path or listening port, so another app
    /// cannot attach to the private plaintext SSH stream. Kernel buffers apply
    /// backpressure while each direction uses one fixed 32 KiB scratch buffer.
    static func adapt(stream: any BlockingByteStream, on group: any EventLoopGroup,
                      diagnostics: TailcatDiagnostics = TailcatDiagnostics(nil)) async throws -> TailcatSSHConnection {
        let descriptors: (Int32, Int32)
        do { try Task.checkCancellation(); descriptors = try SocketPairBridge.makePair() }
        catch {
            await closeNative(stream)
            throw error
        }
        let bridge = SocketPairBridge(stream: stream, descriptor: descriptors.1, diagnostics: diagnostics)
        return try await withTaskCancellationHandler {
            do {
                // After this call NIO owns descriptor 0, including failed
                // registration. Descriptor 1 remains exclusively bridge-owned.
                // Always hand off even if cancellation just won: stop() shuts
                // down the other end and attach() then closes this channel.
                let channel = try await ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelOption(ChannelOptions.writeBufferWaterMark,
                                   value: WriteBufferWaterMark(low: 64 * 1024, high: 256 * 1024))
                    .channelInitializer { channel in
                        bridge.attach(channel)
                        return channel.pipeline.addHandlers(ReadTerminationHandler(bridge: bridge), WriteBudgetHandler())
                    }
                    .withConnectedSocket(descriptors.0).get()
                bridge.start()
                try Task.checkCancellation()
                return TailcatSSHConnection(channel: channel, bridge: bridge)
            } catch {
                bridge.stop()
                await bridge.waitUntilClosed()
                throw error
            }
        } onCancel: { bridge.stop() }
    }

    private static func closeNative(_ stream: any BlockingByteStream) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { stream.cancel(); stream.close(); continuation.resume() }
        }
    }
}

final class SocketPairBridge: @unchecked Sendable {
    let diagnostics: TailcatDiagnostics
    private let stream: any BlockingByteStream
    private let descriptor: Int32
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var stopping = false
    private var started = false
    private var finished = false
    private var readFailure: Error?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private weak var channel: (any Channel)?

    init(stream: any BlockingByteStream, descriptor: Int32, diagnostics: TailcatDiagnostics) {
        self.stream = stream; self.descriptor = descriptor; self.diagnostics = diagnostics
    }

    static func makePair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw TailcatSSHTransportError.bridgeFailure(code: errno)
        }
        do {
            for fd in pair {
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw TailcatSSHTransportError.bridgeFailure(code: errno) }
                var yes: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw TailcatSSHTransportError.bridgeFailure(code: errno)
                }
                var size: Int32 = 64 * 1024
                guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw TailcatSSHTransportError.bridgeFailure(code: errno)
                }
            }
            return (pair[0], pair[1])
        } catch { Darwin.close(pair[0]); Darwin.close(pair[1]); throw error }
    }

    func attach(_ channel: any Channel) {
        lock.lock(); self.channel = channel; let closeNow = stopping; lock.unlock()
        channel.closeFuture.whenComplete { _ in self.stop() }
        if closeNow { channel.close(promise: nil) }
    }

    func start() {
        lock.lock()
        guard !stopping, !started else { lock.unlock(); return }
        started = true
        workers.enter(); workers.enter()
        lock.unlock()
        // Dedicated blocking workers avoid starving Swift's cooperative pool
        // or the NIO event loop; there is no task/dispatch allocation per packet.
        Thread.detachNewThread { self.readPump(); self.workers.leave() }
        Thread.detachNewThread { self.writePump(); self.workers.leave() }
    }

    func stop(error: Error? = nil) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let channel = channel
        Darwin.shutdown(descriptor, SHUT_RDWR)
        lock.unlock()
        stream.cancel()
        if let channel {
            channel.eventLoop.execute {
                if let error { channel.pipeline.fireErrorCaught(error) }
                channel.close(promise: nil)
            }
        }
        DispatchQueue.global(qos: .utility).async {
            // Wake both native and Unix reads/writes before joining them.
            self.stream.close()
            self.workers.wait()
            Darwin.close(self.descriptor)
            self.lock.lock()
            self.finished = true
            let waiters = self.closeWaiters
            self.closeWaiters.removeAll()
            self.lock.unlock()
            self.diagnostics.record(.connectionClosed)
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished { lock.unlock(); continuation.resume() }
            else { closeWaiters.append(continuation); lock.unlock() }
        }
    }

    var terminalReadError: Error? {
        lock.lock(); defer { lock.unlock() }
        return readFailure
    }

    private func finishReading(error: Error?) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        readFailure = error
        // Preserve every byte already written to the socket. NIO sees FIN
        // after those bytes; ReadTerminationHandler then reports this failure.
        Darwin.shutdown(descriptor, SHUT_WR)
        lock.unlock()
    }

    private func readPump() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        do {
            while true {
                let count = try bytes.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 {
                    // FIN follows already-written bytes. Let NIO consume those
                    // before its EOF closes the channel and triggers cleanup.
                    finishReading(error: nil)
                    return
                }
                try bytes.withUnsafeBytes { pointer in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw TailcatSSHTransportError.bridgeFailure(code: errno) }
                        offset += written
                    }
                }
            }
        } catch { finishReading(error: error) }
    }

    private func writePump() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        do {
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count == 0 { stop(); return }
                guard count > 0 else { throw TailcatSSHTransportError.bridgeFailure(code: errno) }
                try bytes.withUnsafeBytes { try stream.writeAll(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
        } catch { stop(error: error) }
    }
}

/// A native read may return final bytes AND an error. Report that error only
/// after NIO's Unix socket has delivered those bytes, including before activate.
final class ReadTerminationHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let bridge: SocketPairBridge
    init(bridge: SocketPairBridge) { self.bridge = bridge }
    func channelInactive(context: ChannelHandlerContext) {
        if let error = bridge.terminalReadError { context.fireErrorCaught(error) }
        context.fireChannelInactive()
    }
}

/// NIO watermarks are advisory. Bound unflushed/queued writes even if a caller
/// ignores isWritable, without dropping or replaying a partially sent message.
final class WriteBudgetHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    private var pending = 0
    static let limit = 1024 * 1024

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let size = unwrapOutboundIn(data).readableBytes
        guard size <= Self.limit - pending else {
            let error = TailcatSSHTransportError.backpressureExceeded
            promise?.fail(error)
            context.fireErrorCaught(error)
            context.close(promise: nil)
            return
        }
        pending += size
        let completion = promise ?? context.eventLoop.makePromise(of: Void.self)
        completion.futureResult.whenComplete { _ in self.pending -= size }
        context.write(data, promise: completion)
    }
}
