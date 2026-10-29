import CTailcat
import Foundation
import NIOCore
import NIOPosix
import XCTest
@_spi(EmbeddedTransport) @testable import TailcatSSH

final class TailcatSSHTests: XCTestCase {
    func testNativeABIAndGeneratedKey() throws {
        XCTAssertEqual(tc_abi_version(), 1)
        let first = try TailcatIdentity.generateClientKey()
        let second = try TailcatIdentity.generateClientKey()
        XCTAssertTrue(first.privateKey.hasPrefix("privkey:"))
        XCTAssertTrue(first.publicKey.hasPrefix("nodekey:"))
        XCTAssertNotEqual(first.publicKey, second.publicKey)
        XCTAssertNotEqual(first.privateKey, second.privateKey)
        let metadata = try TailcatIdentity.parseAddress(offlineTailcatAddress)
        XCTAssertTrue(metadata.hasPresharedKey)
        XCTAssertTrue(metadata.serverPublicKey.hasPrefix("nodekey:"))
        XCTAssertEqual(try TailcatIdentity.publicKey(forPrivateKey: first.privateKey, address: offlineTailcatAddress), first.publicKey)
    }

    func testInvalidAddressesAreRejectedWithoutEchoingSecrets() {
        for value in ["", "https://secret.example/psk", "tcSECRET\u{0}suffix", "tcSECRET\n", "tcSECRET"] {
            XCTAssertThrowsError(try TailcatIdentity.parseAddress(value)) { error in
                XCTAssertEqual(error as? TailcatSSHTransportError, .invalidAddress)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
        // Historical README example has no separate discovery key; report an
        // invalid address at form validation, not a misleading client-key error.
        XCTAssertThrowsError(try TailcatIdentity.parseAddress("tcomFwWCCcjS5nKNqAod034nWoJZW0LZqDhhC8U_dKdnDRYQ8uNGFpGQEu")) {
            XCTAssertEqual($0 as? TailcatSSHTransportError, .invalidAddress)
        }
        XCTAssertFalse(TailcatSSHTransportError.invalidAddress.isRetryable)
        XCTAssertFalse(TailcatSSHTransportError.nativeFailure(operation: .dial, code: Int32(TC_INVALID_ARGUMENT)).isRetryable)
        XCTAssertTrue(TailcatSSHTransportError.nativeFailure(operation: .dial, code: Int32(TC_TIMEOUT)).isRetryable)
    }

    func testNativeDialDeadlineWithUnavailableLocalRelay() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let key = try TailcatIdentity.generateClientKey()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await TailcatSSHDialer().connect(address: offlineTailcatAddress, clientKey: key.privateKey,
                                                    port: 22, on: group, timeout: .milliseconds(150))
            XCTFail("unavailable relay unexpectedly connected")
        } catch {
            XCTAssertTrue((error as? TailcatSSHTransportError)?.isTimeout == true)
        }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        try await group.shutdownGracefully()
    }

    func testNativeDialCancellationInterruptsRelayWait() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let key = try TailcatIdentity.generateClientKey()
        let task = Task {
            try await TailcatSSHDialer().connect(address: offlineTailcatAddress, clientKey: key.privateKey,
                                               port: 22, on: group, timeout: .seconds(20))
        }
        // Exercise an in-progress native wait, beyond the separately tested
        // pre-handoff cancellation. This fixture only targets loopback port 9.
        try await Task.sleep(for: .milliseconds(100))
        let start = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled native dial returned a stream") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        try await group.shutdownGracefully()
    }

    func testEarlyBannerWaitsForActivation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let banner = Data("SSH-2.0-fixture\r\n".utf8)
        let readStarted = expectation(description: "pump consumed banner")
        let received = expectation(description: "SSH consumer got banner")
        let stream = TestByteStream(inbound: banner, onRead: { readStarted.fulfill() })
        let connection = try await TailcatSSHDialer.adapt(stream: stream, on: group)
        let recorder = Recorder(expected: banner.count, reached: { received.fulfill() })
        try await connection.channel.pipeline.addHandler(recorder).get()
        await fulfillment(of: [readStarted], timeout: 2)
        let before = try await connection.channel.eventLoop.submit { recorder.bytes }.get()
        XCTAssertTrue(before.isEmpty)
        try await connection.activate()
        await fulfillment(of: [received], timeout: 2)
        let after = try await connection.channel.eventLoop.submit { recorder.bytes }.get()
        XCTAssertEqual(after, banner)
        await connection.close()
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testBinaryRoundTripAndFinalBytesBeforeEOF() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let payload = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let received = expectation(description: "all binary bytes")
        let stream = TestByteStream(echo: true, readChunk: 113)
        let connection = try await TailcatSSHDialer.adapt(stream: stream, on: group)
        let recorder = Recorder(expected: payload.count, reached: { received.fulfill() })
        try await connection.channel.pipeline.addHandler(recorder).get()
        try await connection.activate()
        var buffer = connection.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try await connection.channel.writeAndFlush(buffer).get()
        await fulfillment(of: [received], timeout: 5)
        stream.finishReading()
        try await connection.channel.closeFuture.get()
        let actual = try await connection.channel.eventLoop.submit { recorder.bytes }.get()
        XCTAssertEqual(actual, payload)
        XCTAssertEqual(stream.written, payload)
        await connection.close()
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testCloseUnblocksBothPumpsAndIsIdempotent() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let reading = expectation(description: "read blocked")
        let writing = expectation(description: "write blocked")
        let stream = TestByteStream(blockWrites: true, onRead: { reading.fulfill() }, onWrite: { writing.fulfill() })
        let connection = try await TailcatSSHDialer.adapt(stream: stream, on: group)
        var buffer = connection.channel.allocator.buffer(capacity: 1)
        buffer.writeInteger(UInt8(42))
        try await connection.channel.writeAndFlush(buffer).get()
        await fulfillment(of: [reading, writing], timeout: 2)
        let done = expectation(description: "all workers joined")
        Task { await connection.close(); await connection.close(); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(stream.closeCount, 1)
        XCTAssertFalse(connection.channel.isActive)
        try await group.shutdownGracefully()
    }

    func testFinalBytesThenErrorBeforeActivationAreNotDiscarded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let payload = Data("SSH-2.0-final-bytes\r\n".utf8)
        let failure = TailcatSSHTransportError.nativeFailure(operation: .read, code: Int32(TC_FAILURE))
        let terminated = expectation(description: "native read ended before activation")
        let stream = TestByteStream(inbound: payload, readChunk: 3, terminalError: failure,
                                    onReadEnd: { terminated.fulfill() })
        stream.finishReading()
        let connection = try await TailcatSSHDialer.adapt(stream: stream, on: group)
        let recorder = Recorder(expected: payload.count, reached: {})
        try await connection.channel.pipeline.addHandler(recorder).get()
        await fulfillment(of: [terminated], timeout: 2)
        try await connection.activate()
        try await connection.channel.closeFuture.get()
        let actual = try await connection.channel.eventLoop.submit { recorder.bytes }.get()
        XCTAssertEqual(actual, payload)
        await connection.close()
        try await group.shutdownGracefully()
    }

    func testCancellationBeforeHandoffReleasesNativeStream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let stream = TestByteStream()
        let ready = expectation(description: "ready")
        let proceed = AsyncGate()
        let task = Task {
            ready.fulfill()
            await proceed.wait()
            return try await TailcatSSHDialer.adapt(stream: stream, on: group)
        }
        await fulfillment(of: [ready], timeout: 2)
        task.cancel()
        await proceed.open()
        do { _ = try await task.value; XCTFail("cancelled dial returned a stream") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testUnflushedWritesHaveHardMemoryLimit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let stream = TestByteStream(blockWrites: true)
        let connection = try await TailcatSSHDialer.adapt(stream: stream, on: group)
        var bytes = connection.channel.allocator.buffer(capacity: WriteBudgetHandler.limit + 1)
        bytes.writeRepeatingByte(1, count: WriteBudgetHandler.limit + 1)
        do { try await connection.channel.write(bytes).get(); XCTFail("oversized write accepted") }
        catch { XCTAssertEqual(error as? TailcatSSHTransportError, .backpressureExceeded) }
        await connection.close()
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testConcurrentStreamsShareOneNodeAndClosingOneDoesNotCloseOthers() throws {
        let counts = LockedCounts()
        let pool = NativeClientPool(create: { _ in counts.created(); return 77 }, destroy: { _ in counts.destroyed() })
        let key = NativeClientPool.Key(address: "secret-test-address", privateKey: "secret-test-key")
        let leases = LockedLeases()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            do { leases.append(try pool.acquire(key: key, cancelled: { false })) }
            catch { XCTFail("local lease acquisition failed") }
        }
        XCTAssertEqual(counts.createCount, 1)
        XCTAssertTrue(leases.values.allSatisfy { $0.handle == 77 })
        leases.values.dropLast().forEach { $0.release(); $0.release() }
        XCTAssertEqual(counts.destroyCount, 0)
        leases.values.last!.release()
        XCTAssertEqual(counts.destroyCount, 1)
        let reopened = try pool.acquire(key: key, cancelled: { false })
        XCTAssertEqual(counts.createCount, 2)
        reopened.release()
        XCTAssertEqual(counts.destroyCount, 2)
    }

    func testCancelledLeaseDoesNotRetireSibling() throws {
        let counts = LockedCounts()
        let pool = NativeClientPool(create: { _ in counts.created(); return 55 }, destroy: { _ in counts.destroyed() })
        let key = NativeClientPool.Key(address: "test", privateKey: "test")
        let live = try pool.acquire(key: key, cancelled: { false })
        XCTAssertThrowsError(try pool.acquire(key: key, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(counts.destroyCount, 0)
        live.release()
        XCTAssertEqual(counts.destroyCount, 1)
    }

    func testWaitingForRetiringNodeHonorsDialDeadline() async throws {
        let retiring = expectation(description: "old node retiring")
        let retired = expectation(description: "old node retired")
        let release = DispatchSemaphore(value: 0)
        let pool = NativeClientPool(create: { _ in 1 }, destroy: { _ in
            retiring.fulfill(); release.wait(); retired.fulfill()
        })
        let key = NativeClientPool.Key(address: "test", privateKey: "test")
        let lease = try pool.acquire(key: key, cancelled: { false })
        DispatchQueue.global().async { lease.release() }
        await fulfillment(of: [retiring], timeout: 2)
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000
        XCTAssertThrowsError(try pool.acquire(key: key, deadline: deadline, cancelled: { false })) {
            XCTAssertEqual($0 as? TailcatSSHTransportError, .nativeFailure(operation: .dial, code: Int32(TC_TIMEOUT)))
        }
        release.signal()
        await fulfillment(of: [retired], timeout: 2)
    }

    func testConcurrentInitialStartupWaitHasOwnDeadline() async throws {
        let gate = NativeStartupGate()
        let starting = expectation(description: "first startup blocked")
        let finished = expectation(description: "first startup completed")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try gate.dial(deadline: .max, cancelled: { false }) {
                    starting.fulfill(); release.wait()
                }
            } catch { XCTFail("first startup failed") }
            finished.fulfill()
        }
        await fulfillment(of: [starting], timeout: 2)
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000
        XCTAssertThrowsError(try gate.dial(deadline: deadline, cancelled: { false }) {
            XCTFail("entered the non-cancellable native startup lock")
        }) {
            XCTAssertEqual($0 as? TailcatSSHTransportError, .nativeFailure(operation: .dial, code: Int32(TC_TIMEOUT)))
        }
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(try gate.dial(deadline: .max, cancelled: { false }) { 42 }, 42)
    }
}

private final class Recorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var bytes = Data()
    private let expected: Int
    private let reached: () -> Void
    private var notified = false
    init(expected: Int, reached: @escaping () -> Void) { self.expected = expected; self.reached = reached }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        if bytes.count >= expected, !notified { notified = true; reached() }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class TestByteStream: BlockingByteStream, @unchecked Sendable {
    private let condition = NSCondition()
    private var inbound: Data
    private var outbound = Data()
    private var ended = false
    private var cancelled = false
    private var closes = 0
    private var readNotified = false
    private var writeNotified = false
    private let echo: Bool
    private let blockWrites: Bool
    private let readChunk: Int
    private let onRead: (() -> Void)?
    private let onWrite: (() -> Void)?
    private let terminalError: Error?
    private let onReadEnd: (() -> Void)?

    init(inbound: Data = Data(), echo: Bool = false, blockWrites: Bool = false, readChunk: Int = 32_768,
         onRead: (() -> Void)? = nil, onWrite: (() -> Void)? = nil,
         terminalError: Error? = nil, onReadEnd: (() -> Void)? = nil) {
        self.inbound = inbound; self.echo = echo; self.blockWrites = blockWrites
        self.readChunk = readChunk; self.onRead = onRead; self.onWrite = onWrite
        self.terminalError = terminalError; self.onReadEnd = onReadEnd
    }
    var written: Data { condition.lock(); defer { condition.unlock() }; return outbound }
    var closeCount: Int { condition.lock(); defer { condition.unlock() }; return closes }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        condition.lock(); defer { condition.unlock() }
        if !readNotified { readNotified = true; onRead?() }
        while inbound.isEmpty && !cancelled && !ended { condition.wait() }
        if cancelled { throw CancellationError() }
        if inbound.isEmpty && ended { onReadEnd?(); if let terminalError { throw terminalError } }
        let count = min(buffer.count, inbound.count, readChunk)
        inbound.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
        inbound.removeFirst(count)
        return count
    }
    func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        condition.lock(); defer { condition.unlock() }
        if !writeNotified { writeNotified = true; onWrite?() }
        while blockWrites && !cancelled { condition.wait() }
        if cancelled { throw CancellationError() }
        outbound.append(contentsOf: buffer)
        if echo { inbound.append(contentsOf: buffer); condition.broadcast() }
    }
    func finishReading() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func close() { condition.lock(); closes += 1; cancelled = true; condition.broadcast(); condition.unlock() }
}

private final class LockedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var creates = 0
    private var destroys = 0
    func created() { lock.lock(); creates += 1; lock.unlock() }
    func destroyed() { lock.lock(); destroys += 1; lock.unlock() }
    var createCount: Int { lock.lock(); defer { lock.unlock() }; return creates }
    var destroyCount: Int { lock.lock(); defer { lock.unlock() }; return destroys }
}

private final class LockedLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeClientLease] = []
    func append(_ lease: NativeClientLease) { lock.lock(); storage.append(lease); lock.unlock() }
    var values: [NativeClientLease] { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
