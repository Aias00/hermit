import CTailcat
import Foundation

/// One userspace WireGuard node per identity. Independent SSH/control/push TCP
/// streams must share it: creating two nodes with the same key makes their DERP
/// registrations displace each other.
final class NativeClientPool: @unchecked Sendable {
    struct Key: Hashable { let address: String; let privateKey: String }
    private struct Entry {
        let handle: UInt64
        let startup: NativeStartupGate
        var leases: Int
        var closing: Bool
    }
    static let shared = NativeClientPool()
    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    private let create: (Key) throws -> UInt64
    private let destroy: (UInt64) -> Void

    init(create: @escaping (Key) throws -> UInt64 = {
        try NativeAPI.makeClient(address: $0.address, privateKey: $0.privateKey)
    }, destroy: @escaping (UInt64) -> Void = { tc_close($0, nil) }) {
        self.create = create
        self.destroy = destroy
    }

    // Called only on workers. A retiring identity remains reserved until its
    // native node finishes closing, preventing an overlapping new registration.
    func acquire(key: Key, deadline: UInt64 = .max, cancelled: () -> Bool) throws -> NativeClientLease {
        condition.lock()
        defer { condition.unlock() }
        while entries[key]?.closing == true {
            try NativeStartupGate.check(deadline: deadline, cancelled: cancelled)
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        try NativeStartupGate.check(deadline: deadline, cancelled: cancelled)
        if var entry = entries[key] {
            entry.leases += 1
            entries[key] = entry
            return NativeClientLease(handle: entry.handle, startup: entry.startup, key: key, pool: self)
        }
        let handle = try create(key)
        let startup = NativeStartupGate()
        entries[key] = Entry(handle: handle, startup: startup, leases: 1, closing: false)
        return NativeClientLease(handle: handle, startup: startup, key: key, pool: self)
    }

    fileprivate func release(key: Key) {
        condition.lock()
        guard var entry = entries[key], !entry.closing else { condition.unlock(); return }
        entry.leases -= 1
        let last = entry.leases == 0
        entry.closing = last
        entries[key] = entry
        condition.unlock()
        guard last else { return }
        destroy(entry.handle)
        condition.lock()
        entries.removeValue(forKey: key)
        condition.broadcast()
        condition.unlock()
    }
}

final class NativeClientLease: @unchecked Sendable {
    let handle: UInt64
    let startup: NativeStartupGate
    private let key: NativeClientPool.Key
    private let pool: NativeClientPool
    private let lock = NSLock()
    private var released = false

    fileprivate init(handle: UInt64, startup: NativeStartupGate, key: NativeClientPool.Key, pool: NativeClientPool) {
        self.handle = handle; self.startup = startup; self.key = key; self.pool = pool
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        pool.release(key: key)
    }
}

/// The Go client's first startup holds a non-cancellable mutex while resolving
/// relay metadata. Queue first-use callers here, where their own cancellation
/// and deadline remain observable; established nodes can dial concurrently.
final class NativeStartupGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var starting = false
    private var ready = false

    static func check(deadline: UInt64, cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw TailcatSSHTransportError.nativeFailure(operation: .dial, code: Int32(TC_TIMEOUT))
        }
    }

    func dial<T>(deadline: UInt64, cancelled: () -> Bool, _ operation: () throws -> T) throws -> T {
        condition.lock()
        do {
            while starting && !ready {
                try Self.check(deadline: deadline, cancelled: cancelled)
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            try Self.check(deadline: deadline, cancelled: cancelled)
        } catch { condition.unlock(); throw error }
        if ready { condition.unlock(); return try operation() }
        starting = true
        condition.unlock()
        var succeeded = false
        defer {
            condition.lock()
            starting = false
            ready = succeeded
            condition.broadcast()
            condition.unlock()
        }
        let result = try operation()
        succeeded = true
        return result
    }
}

/// Only the two pump threads call read/write. cancel is nonblocking and may be
/// called anywhere. close runs on a cleanup worker and joins native operations.
@_spi(EmbeddedTransport) public protocol BlockingByteStream: AnyObject, Sendable {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func writeAll(_ buffer: UnsafeRawBufferPointer) throws
    func cancel()
    func close()
}

final class NativeConnection: BlockingByteStream, @unchecked Sendable {
    private let lease: NativeClientLease
    private let connection: UInt64
    private let ioToken: UInt64
    private let lock = NSLock()
    private var closed = false
    // Confined to the read pump. Data returned alongside EOF/error must reach
    // the caller before that terminal status is observed on the next read.
    private var pendingReadStatus: Int32?

    init(lease: NativeClientLease, connection: UInt64) throws {
        self.lease = lease
        self.connection = connection
        var token: UInt64 = 0
        try NativeAPI.check(tc_token_new(-1, &token, nil), operation: .createToken)
        self.ioToken = token
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let pendingReadStatus {
            if pendingReadStatus == TC_EOF { return 0 }
            try NativeAPI.check(pendingReadStatus, operation: .read)
        }
        var count = 0
        let status = tc_conn_read(connection, ioToken, buffer.baseAddress, buffer.count, &count, nil)
        if count > 0 {
            if status != TC_OK { pendingReadStatus = status }
            return count
        }
        if status == TC_EOF { return 0 }
        try NativeAPI.check(status, operation: .read)
        return count
    }

    func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            var count = 0
            let status = tc_conn_write(connection, ioToken, UnsafeMutableRawPointer(mutating: buffer.baseAddress!.advanced(by: offset)),
                                       buffer.count - offset, &count, nil)
            // Count may be nonzero on failure. Never replay the original buffer.
            offset += count
            try NativeAPI.check(status, operation: .write)
            guard count > 0 else { throw TailcatSSHTransportError.connectionClosed }
        }
    }

    func cancel() { tc_token_cancel(ioToken, nil) }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        tc_token_cancel(ioToken, nil)
        tc_close(connection, nil)
        tc_close(ioToken, nil)
        lease.release()
    }
}

final class NativeDialAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var token: UInt64?

    func cancel() {
        lock.lock()
        isCancelled = true
        let handle = token
        lock.unlock()
        // Tokens are never reused. If the worker has just retired it this is
        // a harmless TC_CLOSED, not a cancellation of some unrelated call.
        if let handle { tc_token_cancel(handle, nil) }
    }

    private func cancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    func run(address: String, privateKey: String, port: UInt16, timeout: Int64) throws -> NativeConnection {
        if cancelled() { throw CancellationError() }
        let (deadlineValue, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(timeout))
        let deadline = overflow ? UInt64.max : deadlineValue
        var token: UInt64 = 0
        try NativeAPI.check(tc_token_new(timeout, &token, nil), operation: .createToken)
        lock.lock()
        self.token = token
        let alreadyCancelled = isCancelled
        lock.unlock()
        defer {
            lock.lock(); self.token = nil; lock.unlock()
            tc_close(token, nil)
        }
        if alreadyCancelled { throw CancellationError() }
        let lease = try NativeClientPool.shared.acquire(
            key: .init(address: address, privateKey: privateKey), deadline: deadline, cancelled: cancelled)
        var connection: UInt64 = 0
        do {
            try lease.startup.dial(deadline: deadline, cancelled: cancelled) {
                try NativeAPI.check(tc_client_dial(lease.handle, token, port, Int32(TC_TCP), &connection, nil), operation: .dial)
            }
            if cancelled() { throw CancellationError() }
            return try NativeConnection(lease: lease, connection: connection)
        } catch {
            if connection != 0 { tc_close(connection, nil) }
            lease.release()
            throw error
        }
    }
}
