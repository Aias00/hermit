import Foundation
import Testing
@testable import Moshpit

@Suite("SSH session transport ownership")
struct SSHSessionShutdownTests {
    @Test("PTY EOF closes its owned SSH transport even before explicit cleanup")
    func eofClosesOwnedTransport() async throws {
        let transport = ControlledTransport()
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let notice = Counter()
        await session.setOnUnexpectedClose { notice.increment() }
        try await session.requestPTY(rows: 24, cols: 80)
        await transport.endPTY()
        await eventually { await !session.isConnected }
        await eventually { await transport.shutdownCalls == 1 }
        #expect(await transport.shutdownCalls == 1)
        #expect(notice.value == 1)
        await session.close()
        #expect(await transport.shutdownCalls == 1)
    }

    @Test("Explicit cleanup after a PTY EOF cannot skip shutdown because the session is logically closed")
    func closeAfterEOFStillShutsDown() async throws {
        let transport = ControlledTransport()
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        try await session.requestPTY(rows: 24, cols: 80)
        await transport.endPTY()
        await eventually { await !session.isConnected }
        await session.close()
        #expect(await transport.shutdownCalls == 1)
    }

    @Test("A PTY setup that completes after close cannot report an attached terminal")
    func latePTYDoesNotSucceedAfterClose() async throws {
        let transport = ControlledTransport(delayPTY: true)
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let opening = Task { try await session.requestPTY(rows: 24, cols: 80) }
        await eventually { await transport.ptyStarted }
        await session.close()
        await transport.releasePTY()
        await #expect(throws: SSHError.self) { try await opening.value }
        #expect(await !session.isConnected)
        #expect(await transport.shutdownCalls == 1)
    }

    @Test("Concurrent close callers wait for the same transport shutdown")
    func closeWaitsForOwnedShutdown() async throws {
        let transport = ControlledTransport(delayShutdown: true)
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let completed = Counter()
        let first = Task { await session.close(); completed.increment() }
        await eventually { await transport.shutdownCalls == 1 }
        let second = Task { await session.close(); completed.increment() }
        for _ in 0..<20 { await Task.yield() }
        #expect(completed.value == 0)
        await transport.releaseShutdown()
        await first.value
        await second.value
        #expect(completed.value == 2)
        #expect(await transport.shutdownCalls == 1)
    }

    @Test("Cancelling a pending PTY setup closes its owned transport and rejects the late writer")
    func cancelledPTYClosesTransport() async throws {
        let transport = ControlledTransport(delayPTY: true)
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let opening = Task { try await session.requestPTY(rows: 24, cols: 80) }
        await eventually { await transport.ptyStarted }
        opening.cancel()
        await eventually { await transport.shutdownCalls == 1 }
        #expect(await transport.shutdownCalls == 1)
        await transport.releasePTY()
        await #expect(throws: CancellationError.self) { try await opening.value }
        await session.close()
        #expect(await transport.shutdownCalls == 1)
    }

    @Test("PTY EOF closes only the owning session, leaving a second SSH connection usable")
    func sessionOwnershipIsIndependent() async throws {
        let firstTransport = ControlledTransport()
        let secondTransport = ControlledTransport()
        let first = SSHSession(connection: ServerConnection(), transport: firstTransport)
        let second = SSHSession(connection: ServerConnection(), transport: secondTransport)
        try await first.requestPTY(rows: 24, cols: 80)
        try await second.requestPTY(rows: 24, cols: 80)
        await firstTransport.endPTY()
        await eventually { await firstTransport.shutdownCalls == 1 }
        await first.close()
        #expect(await firstTransport.shutdownCalls == 1)
        #expect(await secondTransport.shutdownCalls == 0)
        #expect(await second.isConnected)
        _ = try await second.executeCommand("true")
        await second.close()
        #expect(await secondTransport.shutdownCalls == 1)
    }

    private func eventually(_ predicate: @Sendable () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private actor ControlledTransport: SSHClientTransport {
        private let delayPTY: Bool
        private let delayShutdown: Bool
        private var ended: (@Sendable () -> Void)?
        private var ptyWaiter: CheckedContinuation<Void, Never>?
        private var shutdownWaiter: CheckedContinuation<Void, Never>?
        private(set) var ptyStarted = false
        private(set) var shutdownCalls = 0

        init(delayPTY: Bool = false, delayShutdown: Bool = false) {
            self.delayPTY = delayPTY
            self.delayShutdown = delayShutdown
        }

        func run(_ command: String) async throws -> Data { Data() }

        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            ended = onEnd
            ptyStarted = true
            if delayPTY { await withCheckedContinuation { ptyWaiter = $0 } }
            return Writer()
        }

        func endPTY() { ended?() }

        func releasePTY() {
            ptyWaiter?.resume()
            ptyWaiter = nil
        }

        func shutdown() async {
            shutdownCalls += 1
            if delayShutdown { await withCheckedContinuation { shutdownWaiter = $0 } }
        }

        func releaseShutdown() {
            shutdownWaiter?.resume()
            shutdownWaiter = nil
        }
    }

    private struct Writer: SSHPTYWriter {
        func write(_ data: Data) async throws {}
        func resize(cols: Int, rows: Int) async throws {}
    }
}
