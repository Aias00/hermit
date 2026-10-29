import Foundation
import Testing
@testable import Moshpit

@Suite("Session review regressions", .serialized)
@MainActor
struct SessionReviewRegressionTests {
    private func connection() -> ServerConnection {
        var config = ServerConnection(name: "review", host: "192.0.2.1", port: 22,
                                      username: "tester", authMethod: .password)
        config.multiplexer = .none
        return config
    }

    @Test("Unsent input survives navigation and reconnect, but belongs only to its connection")
    func composerDraftLifetime() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let config = connection()
        let first = hub.prepare(config)
        let draft = first.composerDraft
        draft.text = "unsent private input"
        draft.isSending = true
        #expect(hub.prepare(config).composerDraft === draft)
        var otherConfig = config
        otherConfig.id = UUID()
        let other = hub.prepare(otherConfig)
        #expect(other.composerDraft !== draft)
        #expect(other.composerDraft.text.isEmpty)
        let replacement = await hub.replaceConnection(config, force: true)
        #expect(replacement.composerDraft === draft)
        #expect(replacement.composerDraft.text == "unsent private input")
        #expect(replacement.composerDraft.isSending)
        // Completion on the retired screen updates the same draft, so reopening
        // cannot replay or resurrect input already acknowledged by the server.
        draft.text = ""
        draft.isSending = false
        #expect(replacement.composerDraft.text.isEmpty)
        await hub.disconnect(config.id)
        let reopened = hub.prepare(config)
        #expect(reopened.composerDraft !== draft)
        #expect(reopened.composerDraft.text.isEmpty)
        await hub.disconnect(config.id)
        await hub.disconnect(otherConfig.id)
    }

    @Test("A launch command waits for a live session and is consumed only once across views")
    func initialCommandBelongsToSession() {
        let session = SessionHub.ActiveSession(connection: connection())
        session.pendingInitialCommand = "echo launch"
        #expect(session.consumeInitialCommand() == nil)
        session.viewModel.markConnected()
        #expect(session.consumeInitialCommand() == "echo launch")
        #expect(session.consumeInitialCommand() == nil)
        session.viewModel.resetForReconnect()
        session.viewModel.markConnected()
        #expect(session.consumeInitialCommand() == nil)
    }

    @Test("A missing herdr degrades to a shell that accepts both keyboard and composer")
    func degradedHerdrStillAcceptsKeyboard() async throws {
        var config = connection()
        config.multiplexer = .herdr
        let transport = SessionLifecycleTests.ScriptedTransport(.reply(""))
        let script = DialScript { config in SSHSession(connection: config, transport: transport) }
        let session = SessionHub.ActiveSession(connection: config, dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(session.degrade?.missing == .herdr)
        #expect(session.viewModel.connState == .live)
        let keyboard = Data("echo keyboard\r".utf8)
        session.sendInput(keyboard)
        try await session.submitLine("echo composer")
        #expect(transport.writer.written.contains(keyboard))
        #expect(transport.writer.written.contains(Data("echo composer\r".utf8)))
        await session.stop()
        HostCapabilityCache.shared.invalidate(config.id)
    }

    private func moshSession(hadContact: Bool) throws -> (SessionHub.ActiveSession, MoshTransport) {
        let config = connection()
        let session = SessionHub.ActiveSession(connection: config)
        let transport = try MoshTransport(
            credentials: MoshCredentials(host: config.host, udpPort: 60001, key: Data(repeating: 7, count: 16)),
            channel: SessionLifecycleTests.IdleDatagramChannel())
        session.installForTesting(moshTransport: transport, moshServerPid: 4242,
                                  moshHadFirstContact: hadContact)
        return (session, transport)
    }

    @Test("A stalled established Mosh session never dials SSH to reap its server")
    func establishedMoshIsNeverReaped() async throws {
        let (session, transport) = try moshSession(hadContact: true)
        let calls = SessionLifecycleTests.Counter()
        session.sidecarConnect = { _ in calls.bump(); throw SSHError.connectionFailed }
        await session.handleMoshReturnPathDead(transport, serverPid: 4242)
        #expect(session.moshReturnPathDead)
        #expect(calls.count == 0)
        await session.stop()
    }

    @Test("Mosh first contact during the cleanup SSH dial cancels the kill")
    func moshContactWhileCleanupDials() async throws {
        let (session, transport) = try moshSession(hadContact: false)
        let gate = DialGate()
        let calls = SessionLifecycleTests.Counter()
        let reapTransport = SessionLifecycleTests.ScriptedTransport(.reply(""))
        session.sidecarConnect = { _ in calls.bump(); return try await gate.wait().get() }
        let cleanup = Task { await session.handleMoshReturnPathDead(transport, serverPid: 4242) }
        while calls.count == 0 { await Task.yield() }
        // Read directly from the transport so a delayed main-actor diagnostics
        // notification cannot cause a healthy session to be killed.
        await transport.handleDatagram(Data([0]))
        gate.finish(.success(SSHSession(connection: connection(), transport: reapTransport)))
        await cleanup.value
        #expect(!reapTransport.commands.contains { $0.contains("kill ") })
        session.installForTesting(moshTransport: transport, moshServerPid: 4242, moshHadFirstContact: true)
        await session.stop()
    }

    @Test("A late cleanup cannot kill a replacement Mosh generation")
    func moshCleanupDoesNotCrossGenerations() async throws {
        let (session, transport) = try moshSession(hadContact: false)
        let gate = DialGate()
        let calls = SessionLifecycleTests.Counter()
        let reapTransport = SessionLifecycleTests.ScriptedTransport(.reply(""))
        session.sidecarConnect = { _ in calls.bump(); return try await gate.wait().get() }
        let cleanup = Task { await session.handleMoshReturnPathDead(transport, serverPid: 4242) }
        while calls.count == 0 { await Task.yield() }
        let (_, replacement) = try moshSession(hadContact: true)
        session.installForTesting(moshTransport: replacement, moshServerPid: 5252, moshHadFirstContact: true)
        gate.finish(.success(SSHSession(connection: connection(), transport: reapTransport)))
        await cleanup.value
        #expect(!reapTransport.commands.contains { $0.contains("kill ") })
        await transport.close()
        await session.stop()
    }

    @Test("Changing the saved host replaces even a live session")
    func editedConnectionReplacesLiveSession() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        var config = connection()
        let first = hub.prepare(config)
        first.viewModel.markConnected()
        config.host = "192.0.2.2"
        let second = await hub.replaceConnection(config)
        #expect(first !== second)
        #expect(hub.session(for: config) === second)
        #expect(second.connection.host == "192.0.2.2")
        await hub.disconnect(config.id)
    }

    @Test("Metadata updates preserve the session; an explicit credential retest replaces it")
    func metadataAndForcedReplacement() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        var config = connection()
        let first = hub.prepare(config)
        first.viewModel.markConnected()
        config.name = "renamed"
        config.lastConnectedAt = Date()
        #expect(await hub.replaceConnection(config) === first)
        let replacement = await hub.replaceConnection(config, force: true)
        #expect(replacement !== first)
        await hub.disconnect(config.id)
    }

    @Test("Overlapping replacements leave the latest requested configuration registered")
    func replacementOrdering() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        var config = connection()
        let initial = hub.prepare(config)
        initial.viewModel.markConnected()
        var intermediate = config
        intermediate.host = "192.0.2.2"
        config.host = "192.0.2.3"
        let first = Task { await hub.replaceConnection(intermediate) }
        await Task.yield()
        let second = Task { await hub.replaceConnection(config) }
        _ = await first.value
        let last = await second.value
        #expect(hub.session(for: config) === last)
        #expect(last.connection.host == "192.0.2.3")
        await hub.disconnect(config.id)
    }
    @Test("Raw Mosh input is blocked while the renderer changes panes")
    func moshSwitchBlocksRawInput() async throws {
        let fixture = MoshTransportStateMachineTests()
        let (transport, _, _) = try fixture.makeTransport()
        let session = SessionHub.ActiveSession(connection: connection())
        let client = HerdrControlClient(runner: HerdrControlClientTests.FakeRunner(response: "__moshpit_rc=0"))
        client.selectPane("w1:p1")
        session.installForTesting(moshTransport: transport, herdrControl: client, moshSwitchInFlight: true)
        do {
            try await client.rawInputWriter?(Data("must not reach old pane".utf8), "w1:p1")
            Issue.record("input during a renderer switch must fail")
        } catch {}
        #expect(await transport.currentDiagnostics.lastUserNum == 0)
        await session.stop()
    }

    @Test("Queued raw Mosh input rechecks pane-switch state after earlier writes finish")
    func queuedMoshInputRechecksSwitch() async throws {
        let fixture = MoshTransportStateMachineTests()
        let (transport, _, crypto) = try fixture.makeTransport()
        let session = SessionHub.ActiveSession(connection: connection())
        let client = HerdrControlClient(runner: HerdrControlClientTests.FakeRunner(response: "__moshpit_rc=0"))
        client.selectPane("w1:p1")
        session.installForTesting(moshTransport: transport, herdrControl: client)
        let writer = try #require(client.rawInputWriter)
        let first = Task { try await writer(Data("before switch".utf8), "w1:p1") }
        while await transport.currentDiagnostics.lastUserNum == 0 { await Task.yield() }
        var secondStarted = false
        let queued = Task {
            secondStarted = true
            try await writer(Data("must not reach old pane".utf8), "w1:p1")
        }
        while !secondStarted { await Task.yield() }
        session.installForTesting(moshTransport: transport, herdrControl: client, moshSwitchInFlight: true)
        let ack = try fixture.makeDatagram(crypto: crypto, seq: 0, id: 1,
                                          oldNum: 0, newNum: 0, ackNum: 1)
        await transport.handleDatagram(ack)
        try await first.value
        do { try await queued.value; Issue.record("queued input must recheck the switch") } catch {}
        #expect(await transport.currentDiagnostics.lastUserNum == 1)
        await session.stop()
    }

    private actor PausedShutdownTransport: SSHClientTransport {
        private(set) var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func run(_ command: String) async throws -> Data { Data() }
        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            QuietTransport.Writer()
        }
        func shutdown() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func pauseTeardown(of session: SessionHub.ActiveSession) -> PausedShutdownTransport {
        let transport = PausedShutdownTransport()
        let sidecar = SSHSession(connection: session.connection, transport: transport)
        session.installForTesting(moshTransport: nil, sidecarSSH: sidecar)
        session.viewModel.markConnected()
        return transport
    }

    @Test("Disconnect requested during replacement wins and stale results cannot start")
    func disconnectAfterReplacement() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let dials = SessionLifecycleTests.Counter()
        let script = DialScript { _ in dials.bump(); throw SSHError.connectionFailed }
        hub.makeSession = { SessionHub.ActiveSession(connection: $0, dial: script.dialer) }
        var config = connection()
        let initial = hub.prepare(config)
        let gate = pauseTeardown(of: initial)
        config.host = "192.0.2.2"
        let replacing = Task { await hub.replaceConnection(config) }
        while !(await gate.entered) { await Task.yield() }
        var disconnectStarted = false
        let disconnecting = Task {
            disconnectStarted = true
            await hub.disconnect(config.id)
        }
        while !disconnectStarted { await Task.yield() }
        await gate.release()
        let stale = await replacing.value
        await disconnecting.value
        #expect(hub.session(for: config) == nil)
        // An older open can resume after disconnect. Even if it resets its
        // retired view model, it must not start an unregistered transport.
        stale.viewModel.resetForReconnect()
        await hub.start(stale, theme: .githubDark, fontSize: 14)
        #expect(dials.count == 0)
        #expect(hub.session(for: config) == nil)
    }

    @Test("A later replacement waits for an explicit disconnect and remains registered")
    func replacementAfterDisconnect() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        var config = connection()
        let initial = hub.prepare(config)
        let gate = pauseTeardown(of: initial)
        let disconnecting = Task { await hub.disconnect(config.id) }
        while !(await gate.entered) { await Task.yield() }
        config.host = "192.0.2.2"
        var replacementStarted = false
        let replacing = Task {
            replacementStarted = true
            return await hub.replaceConnection(config)
        }
        while !replacementStarted { await Task.yield() }
        await gate.release()
        await disconnecting.value
        let replacement = await replacing.value
        #expect(hub.session(for: config) === replacement)
        #expect(replacement.connection.host == "192.0.2.2")
        #expect(!replacement.isStopping)
        await hub.disconnect(config.id)
    }

    @Test("Late teardown cannot remove a different session registered by prepare")
    func teardownOwnsCapturedIdentity() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        var config = connection()
        let initial = hub.prepare(config)
        let gate = pauseTeardown(of: initial)
        let disconnecting = Task { await hub.disconnect(config.id) }
        while !(await gate.entered) { await Task.yield() }
        initial.viewModel.resetForReconnect()
        config.host = "192.0.2.2"
        let replacement = hub.prepare(config)
        #expect(replacement !== initial)
        hub.visibleSession = replacement
        await gate.release()
        await disconnecting.value
        #expect(hub.session(for: config) === replacement)
        #expect(hub.visibleSession === replacement)
        await hub.disconnect(config.id)
    }

    @Test("Two disconnect callers share ordering instead of stopping the same object concurrently")
    func repeatedDisconnectsAreOrdered() async {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let config = connection()
        let initial = hub.prepare(config)
        let gate = pauseTeardown(of: initial)
        let first = Task { await hub.disconnect(config.id) }
        while !(await gate.entered) { await Task.yield() }
        var secondStarted = false
        var secondFinished = false
        let second = Task {
            secondStarted = true
            await hub.disconnect(config.id)
            secondFinished = true
        }
        while !secondStarted { await Task.yield() }
        await Task.yield()
        #expect(!secondFinished)
        await gate.release()
        await first.value
        await second.value
        #expect(secondFinished)
        #expect(hub.session(for: config) == nil)
    }

}
