import Foundation
import Testing
@testable import Moshpit

@Suite("Herdr frame stdin ownership", .serialized)
@MainActor
struct HerdrFrameLifecycleTests {
    private final class Transport: SSHClientTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var output: (@Sendable (Data) -> Void)?
        private var end: (@Sendable () -> Void)?
        private var pane = "w1:p1"
        private var stopped = false
        let writer = Writer()

        var isStopped: Bool { lock.withLock { stopped } }
        func focus(_ pane: String) { lock.withLock { self.pane = pane } }
        func emit(_ line: String) {
            let callback = lock.withLock { output }
            callback?(Data((line + "\n").utf8))
        }
        func run(_ command: String) async throws -> Data {
            if command.contains("command -v") { return Data("/usr/local/bin/herdr\n::Darwin::".utf8) }
            if command.contains("api snapshot") {
                let pane = lock.withLock { self.pane }
                return Data("""
                {"id":"cli:api:snapshot","result":{"snapshot":{
                "workspaces":[{"workspace_id":"w1","label":"test","focused":true}],
                "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"focused":true,"pane_count":2}],
                "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","focused":\(pane == "w1:p1"),"width":80,"height":24},
                         {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","focused":\(pane == "w1:p2"),"width":80,"height":24}],
                "layouts":[],"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"\(pane)"}}}
                \n__moshpit_rc=0
                """.utf8)
            }
            return Data("__moshpit_rc=0".utf8)
        }
        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            lock.withLock { output = onOutput; end = onEnd }
            return writer
        }
        func shutdown() async {
            let callback = lock.withLock { stopped = true; return end }
            await writer.release()
            callback?()
        }
    }

    private actor Writer: SSHPTYWriter {
        private var records: [Data] = []
        private var pauseNext = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var rejectNextWrite = false
        func write(_ data: Data) async throws {
            records.append(data)
            if rejectNextWrite { rejectNextWrite = false; throw SSHError.sessionClosed }
            if pauseNext {
                pauseNext = false
                await withCheckedContinuation { waiter = $0 }
            }
        }
        func resize(cols: Int, rows: Int) async throws {}
        func pause() { pauseNext = true }
        func failNext() { rejectNextWrite = true }
        func release() { waiter?.resume(); waiter = nil }
        func written() -> [String] { records.map { String(decoding: $0, as: UTF8.self) } }
        var isPaused: Bool { waiter != nil }
    }

    private struct Fixture {
        let active: SessionHub.ActiveSession
        let transport: Transport
        let dials: SessionLifecycleTests.Counter
    }

    private func makeFixture(bootTimeout: Duration? = .seconds(2),
                             releaseTimeout: Duration? = .seconds(1),
                             pauseBootWrite: Bool = false,
                             writeTimeout: Duration? = nil,
                             queuedBootBarrier: Task<Void, Never>? = nil,
                             waitForBoot: Bool = true) async throws -> Fixture {
        var connection = ServerConnection(name: "herdr frame fixture", host: "192.0.2.1", port: 22,
                                          username: "test", authMethod: .password)
        connection.multiplexer = .herdr
        let transport = Transport()
        if pauseBootWrite { await transport.writer.pause() }
        let dials = SessionLifecycleTests.Counter()
        let script = DialScript { configuration in
            dials.bump()
            guard dials.count == 1 else { throw SSHError.connectionFailed }
            return SSHSession(connection: configuration, transport: transport)
        }
        let active = SessionHub.ActiveSession(connection: connection, dial: script.dialer)
        if let bootTimeout { active.herdrFirstFrameTimeout = bootTimeout }
        if let releaseTimeout { active.herdrReleaseTimeout = releaseTimeout }
        if let writeTimeout { active.herdrWriteTimeout = writeTimeout }
        if let queuedBootBarrier {
            active.installForTesting(moshTransport: nil, herdrWriteBarrier: queuedBootBarrier)
        }
        active.sidecarConnect = { _ in throw SSHError.connectionFailed }
        await active.start(theme: .githubDark, fontSize: 14)
        let fixture = Fixture(active: active, transport: transport, dials: dials)
        if waitForBoot {
            #expect(await eventually { await transport.writer.written().contains { $0.contains("/bin/sh -c") } })
        }
        return fixture
    }

    private func finish(_ fixture: Fixture) async {
        await fixture.transport.writer.release()
        await fixture.active.stop()
        HostCapabilityCache.shared.invalidate(fixture.active.connection.id)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func paint(_ fixture: Fixture, cols: Int = 81) async {
        fixture.transport.emit(HerdrFrameCommand.readyMarker)
        fixture.transport.emit("""
        {"type":"terminal.frame","seq":1,"width":\(cols),"height":25,"full":true,"bytes":""}
        """)
        #expect(await eventually { fixture.active.herdrRemoteGrid?.cols == cols })
        // The frame parser commits the grid and its input gate on the main actor.
        await Task.yield()
    }

    private func selectSecondPane(_ fixture: Fixture) async {
        fixture.transport.focus("w1:p2")
        fixture.active.herdrControl?.selectPane("w1:p2")
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.contains("terminal.release") }
        })
    }

    @Test("A delayed boot response never injects a shell fallback into an unknown stdin owner")
    func silentBootRebuilds() async throws {
        let fixture = try await makeFixture(bootTimeout: .milliseconds(80))
        #expect(await eventually { fixture.dials.count == 2 })
        let writes = await fixture.transport.writer.written()
        #expect(writes.filter { $0.contains("terminal session control") }.count == 1)
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("terminal.closed alone does not authorize a raw retarget")
    func closedWaitsForReaderReady() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        await selectSecondPane(fixture)
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        // A late old frame must not reopen the input gate for the new pane.
        fixture.transport.emit(#"{"type":"terminal.frame","width":99,"height":25,"full":true,"bytes":""}"#)
        try await Task.sleep(for: .milliseconds(40))
        #expect(!(await fixture.transport.writer.written()).contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") })
        #expect(fixture.active.herdrRemoteGrid?.cols != 99)
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") }
        })
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("A release timeout rebuilds the channel without sending a raw target")
    func releaseTimeoutRebuilds() async throws {
        let fixture = try await makeFixture(releaseTimeout: .milliseconds(80))
        await paint(fixture)
        await selectSecondPane(fixture)
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        #expect(await eventually { fixture.dials.count == 2 })
        #expect(!(await fixture.transport.writer.written()).contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") })
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("Ignored JSON input is a warning; the live attachment continues accepting encoded keys")
    func inputWarningKeepsAttachment() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        let warning = "terminal session control input ignored: invalid json command: expected value at line 1 column 1"
        fixture.transport.emit("herdr: " + warning)
        #expect(await eventually { fixture.active.herdrNotice == warning })
        fixture.active.sendInput(Data("hello\r".utf8))
        #expect(await eventually {
            await fixture.transport.writer.written().contains {
                $0 == HerdrFrameCommand.input(Data("hello\r".utf8)) + "\n"
            }
        })
        let writes = await fixture.transport.writer.written()
        #expect(writes.filter { $0.contains("terminal session control") }.count == 1)
        #expect(!writes.contains { $0.contains("terminal.release") || $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p1 ") })
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("Queued resize from the old pane is dropped after a target switch")
    func queuedResizeChecksTargetGeneration() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        // Drain the first-frame viewport correction before pausing the writer.
        try await Task.sleep(for: .milliseconds(20))
        await fixture.transport.writer.pause()
        fixture.active.coordinator.onViewportSizeChange?(90, 30)
        #expect(await eventually { await fixture.transport.writer.isPaused })
        fixture.active.coordinator.onViewportSizeChange?(91, 31)
        fixture.transport.focus("w1:p2")
        fixture.active.herdrControl?.selectPane("w1:p2")
        await fixture.transport.writer.release()
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.contains("terminal.release") }
        })
        #expect(!(await fixture.transport.writer.written()).contains {
            $0 == HerdrFrameCommand.resize(cols: 91, rows: 31) + "\n"
        })
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") }
        })
        await finish(fixture)
    }

    @Test("Foreground resume waits for the reader marker, not terminal.closed")
    func backgroundReleaseRequiresReaderReady() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        fixture.active.herdrForegroundRecoveryDeadline = .seconds(1)
        fixture.active.releaseWindowPinsForBackground()
        await fixture.active.flushBackgroundTeardown()
        fixture.active.resumeHerdrFrames()
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await fixture.transport.writer.written()).contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p1 ") })
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p1 ") }
        })
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("Background cancellation drops an already queued raw retarget without consuming reader readiness")
    func queuedRetargetIsInvalidatedOnBackground() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        await fixture.transport.writer.pause()
        fixture.active.coordinator.onViewportSizeChange?(90, 30)
        #expect(await eventually { await fixture.transport.writer.isPaused })
        fixture.transport.focus("w1:p2")
        fixture.active.herdrControl?.selectPane("w1:p2")
        // Emulate the old CLI exit while its write completion is delayed.
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        try await Task.sleep(for: .milliseconds(30))
        fixture.active.releaseWindowPinsForBackground()
        await fixture.transport.writer.release()
        await fixture.active.flushBackgroundTeardown()
        #expect(!(await fixture.transport.writer.written()).contains { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") })
        fixture.active.resumeHerdrFrames()
        #expect(await eventually {
            await fixture.transport.writer.written().filter { $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ") }.count == 1
        })
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("Default startup budget allows a healthy shell whose first output takes over three seconds")
    func slowInitialOutputKeepsConnection() async throws {
        let fixture = try await makeFixture(bootTimeout: nil, releaseTimeout: nil)
        try await Task.sleep(for: .milliseconds(3200))
        await paint(fixture)
        #expect(fixture.dials.count == 1)
        #expect(!fixture.transport.isStopped)
        #expect(fixture.active.viewModel.connState == .live)
        await finish(fixture)
    }

    @Test("Startup response budget begins after the boot write completes, not while it is queued")
    func queuedBootDoesNotConsumeResponseBudget() async throws {
        let fixture = try await makeFixture(bootTimeout: .milliseconds(80), pauseBootWrite: true)
        #expect(await eventually { await fixture.transport.writer.isPaused })
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.dials.count == 1)
        #expect(!fixture.transport.isStopped)
        await fixture.transport.writer.release()
        await paint(fixture)
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("A startup marker without a first frame still has a bounded startup deadline")
    func readyWithoutFrameIsBounded() async throws {
        let fixture = try await makeFixture(bootTimeout: .milliseconds(80))
        fixture.transport.emit(HerdrFrameCommand.readyMarker)
        #expect(await eventually { fixture.dials.count == 2 })
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("Repeated snapshot polls cannot release a healthy startup while its first frame is pending")
    func pollingDoesNotRestartPendingFirstFrame() async throws {
        let fixture = try await makeFixture(bootTimeout: nil, releaseTimeout: nil)
        fixture.transport.emit(HerdrFrameCommand.readyMarker)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(850))
            fixture.active.herdrControl?.quicken()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await fixture.transport.writer.written()).contains { $0.contains("terminal.release") })
        await paint(fixture)
        #expect(fixture.dials.count == 1)
        #expect(!fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("A slow reader handoff retains the same healthy connection until the explicit marker")
    func slowReaderReadyDoesNotReconnectEarly() async throws {
        let fixture = try await makeFixture(bootTimeout: nil, releaseTimeout: nil)
        await paint(fixture)
        await selectSecondPane(fixture)
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        try await Task.sleep(for: .milliseconds(1700))
        #expect(fixture.dials.count == 1)
        #expect(!fixture.transport.isStopped)
        #expect(!(await fixture.transport.writer.written()).contains {
            $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ")
        })
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually {
            await fixture.transport.writer.written().contains {
                $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ")
            }
        })
        await finish(fixture)
    }


    private actor QueueBarrier {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test("A queued boot replaced by a newer focus does not falsely claim the wrapper started")
    func queuedBootCancelledByFocus() async throws {
        let barrier = QueueBarrier()
        let pending = Task { await barrier.wait() }
        let fixture = try await makeFixture(queuedBootBarrier: pending, waitForBoot: false)
        #expect(await eventually { fixture.active.herdrControl?.snapshot.panes.count == 2 })
        // The first focus has queued its boot behind the barrier.
        try await Task.sleep(for: .milliseconds(25))
        #expect((await fixture.transport.writer.written()).isEmpty)
        fixture.transport.focus("w1:p2")
        fixture.active.herdrControl?.selectPane("w1:p2")
        await barrier.release()
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.contains("moshpit-herdr 'w1:p2'") }
        })
        let writes = await fixture.transport.writer.written()
        #expect(writes.filter { $0.contains("terminal session control") }.count == 1)
        #expect(!writes.contains { $0.contains("terminal.release") })
        await paint(fixture)
        #expect(fixture.dials.count == 1)
        await finish(fixture)
    }

    @Test("An acknowledged retarget without a first frame has its own bounded deadline")
    func retargetWithoutFrameIsBounded() async throws {
        let fixture = try await makeFixture(bootTimeout: .milliseconds(100))
        await paint(fixture)
        await selectSecondPane(fixture)
        fixture.transport.emit(#"{"type":"terminal.closed"}"#)
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually {
            await fixture.transport.writer.written().contains {
                $0.hasPrefix("\(HerdrFrameCommand.retargetPrefix) w1:p2 ")
            }
        })
        #expect(await eventually { fixture.dials.count == 2 })
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("A CLI exit that emits only reader_ready cannot strand an attached target")
    func readerReadyWithoutClosedRecovers() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        fixture.transport.emit(HerdrFrameCommand.readerReadyMarker)
        #expect(await eventually { fixture.dials.count == 2 })
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }

    @Test("An actual boot write that never completes is bounded independently of the response deadline")
    func hungWriteClosesParentAndReconnects() async throws {
        let fixture = try await makeFixture(bootTimeout: .seconds(30), pauseBootWrite: true,
                                            writeTimeout: .milliseconds(80))
        #expect(await eventually { fixture.dials.count == 2 })
        #expect(fixture.transport.isStopped)
        #expect(!(await fixture.transport.writer.isPaused))
        await finish(fixture)
    }

    @Test("Reconnect does not wait on a failing courtesy release from the old channel")
    func failingReleaseCannotDeadlockReconnect() async throws {
        let fixture = try await makeFixture()
        await paint(fixture)
        try await Task.sleep(for: .milliseconds(20))
        await fixture.transport.writer.failNext()
        let completed = await withTimeoutValue(2) { @MainActor in
            await fixture.active.reconnect(automatic: false)
            return true
        }
        #expect(completed == true)
        #expect(fixture.dials.count == 2)
        #expect(fixture.transport.isStopped)
        await finish(fixture)
    }


    @Test("Backgrounding an unwritten boot never sends release JSON into the login shell")
    func backgroundBeforeQueuedBootWrites() async throws {
        let barrier = QueueBarrier()
        let pending = Task { await barrier.wait() }
        let fixture = try await makeFixture(queuedBootBarrier: pending, waitForBoot: false)
        #expect(await eventually { fixture.active.herdrControl?.snapshot.panes.count == 2 })
        try await Task.sleep(for: .milliseconds(25))
        #expect((await fixture.transport.writer.written()).isEmpty)
        fixture.active.releaseWindowPinsForBackground()
        fixture.active.resumeHerdrFrames()
        await barrier.release()
        #expect(await eventually {
            await fixture.transport.writer.written().contains { $0.contains("moshpit-herdr 'w1:p1'") }
        })
        let writes = await fixture.transport.writer.written()
        #expect(writes.filter { $0.contains("terminal session control") }.count == 1)
        #expect(!writes.contains { $0.contains("terminal.release") })
        await paint(fixture)
        #expect(fixture.dials.count == 1)
        #expect(!fixture.transport.isStopped)
        await finish(fixture)
    }

}
