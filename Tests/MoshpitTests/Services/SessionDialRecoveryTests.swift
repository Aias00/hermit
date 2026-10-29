import Foundation
import Testing
@testable import Moshpit

/// Coming back to a session that has nothing up. The field case: the app is
/// opened with the Tailscale tunnel down, the dial hangs on a SYN nobody
/// answers, the user goes to turn the tunnel on and returns — and expects
/// the connection to come up now, not after the connect timeout and the
/// next keepalive tick.
@Suite("session dial recovery")
@MainActor
struct SessionDialRecoveryTests {

    @Test("Composer submit while offline throws instead of reporting success and losing a draft")
    func offlineSubmitFails() async {
        let session = SessionHub.ActiveSession(connection: connection())
        do { try await session.submitLine("keep draft"); Issue.record("must reject offline submission") }
        catch {}
        await session.stop()
    }

    @Test("Lost herdr release acknowledgement is bounded and reconnects without leaving the screen")
    func herdrLostReleaseAckRecovers() async throws {
        var config = connection()
        config.multiplexer = .herdr
        let script = DialScript { _ in throw SSHError.connectionFailed }
        let session = SessionHub.ActiveSession(connection: config, dial: script.dialer)
        let frame = SSHSession(connection: config, transport: QuietTransport())
        session.installForTesting(moshTransport: nil, herdrFrameSession: frame, pendingHerdrCloses: 1)
        session.herdrForegroundRecoveryDeadline = .milliseconds(10)
        session.releaseWindowPinsForBackground()
        session.repinForeground()
        for _ in 0..<250 {
            if script.dials > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(script.dials > 0, "foreground recovery must not wait forever for an old close frame")
        await session.stop()
    }

    @Test("Herdr input during detached rendering never falls through into the SSH shell")
    func detachedHerdrInputIsBlocked() async {
        var config = connection()
        config.multiplexer = .herdr
        let session = SessionHub.ActiveSession(connection: config)
        let frame = SSHSession(connection: config, transport: QuietTransport())
        session.installForTesting(moshTransport: nil, herdrFrameSession: frame)
        session.viewModel.markConnected()
        session.sendInput(Data([0x0D]))
        #expect(session.herdrNotice != nil)
        await session.stop()
    }

    private func connection() -> ServerConnection {
        var connection = ServerConnection(
            name: "recovery",
            host: "192.0.2.1",   // RFC5737 TEST-NET-1 — never routable
            port: 22,
            username: "tester",
            authMethod: .password)
        connection.multiplexer = .none   // a plain shell: the shortest start() path
        return connection
    }

    private func makeSession(_ script: DialScript) -> SessionHub.ActiveSession {
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        session.probeTimeout = 0.2
        session.foregroundProbeTimeout = 0.2
        return session
    }

    @Test("foreground return redials a dial that is still out")
    func foregroundReturnRedials() async throws {
        let gate = DialGate()
        let script = DialScript { _ in try await gate.wait().get() }
        let session = makeSession(script)
        session.stalledDialGrace = 0

        let first = Task { await session.start(theme: .githubDark, fontSize: 14) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.isDialing)
        #expect(!session.viewModel.isAutoReconnectInFlight, "the user asked for this connect")

        script.behavior = { connection in SSHSession(connection: connection, transport: QuietTransport()) }
        await session.resumeIfNeeded(probeTimeout: 0.2)

        #expect(script.dials == 2, "the stuck dial is replaced on the spot")
        #expect(session.viewModel.status == .connected)
        #expect(!session.viewModel.isAutoReconnectInFlight,
                "a redial of a connect the user asked for is still theirs")

        // The abandoned dial finally gives up: nothing changes.
        gate.finish(.failure(DialFailed()))
        await first.value
        #expect(session.viewModel.status == .connected)
        #expect(session.viewModel.errorMessage == nil)
        await session.stop()
    }

    @Test("a dial younger than the grace is left to finish")
    func freshDialIsLeftAlone() async throws {
        let gate = DialGate()
        let script = DialScript { _ in try await gate.wait().get() }
        let session = makeSession(script)
        session.stalledDialGrace = 60

        let first = Task { await session.start(theme: .githubDark, fontSize: 14) }
        try await Task.sleep(for: .milliseconds(50))
        await session.resumeIfNeeded(probeTimeout: 0.2)
        #expect(script.dials == 1)
        #expect(session.isDialing)

        gate.finish(.success(SSHSession(connection: connection(), transport: QuietTransport())))
        await first.value
        #expect(session.viewModel.status == .connected)
        await session.stop()
    }

    @Test("foreground return reconnects a failed session without waiting for the tick")
    func foregroundReturnRetriesFailed() async throws {
        let script = DialScript { _ in throw DialFailed() }
        let session = makeSession(script)
        await session.start(theme: .githubDark, fontSize: 14)
        guard case .failed = session.viewModel.status else {
            Issue.record("expected .failed, got \(session.viewModel.status)")
            return
        }

        script.behavior = { connection in SSHSession(connection: connection, transport: QuietTransport()) }
        await session.resumeIfNeeded(probeTimeout: 0.2)
        #expect(script.dials == 2)
        #expect(session.viewModel.status == .connected)
        await session.stop()
    }

    @Test("a network path change kicks the hub's down sessions")
    func pathChangeKicksDownSessions() async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let gate = DialGate()
        let failing = DialScript { _ in throw DialFailed() }
        let hanging = DialScript { _ in try await gate.wait().get() }
        let scripts = ["down": failing, "dialing": hanging]
        hub.makeSession = { connection in
            let session = SessionHub.ActiveSession(connection: connection, dial: scripts[connection.name]!.dialer)
            session.probeTimeout = 0.2
            return session
        }
        var down = connection()
        down.name = "down"
        var dialing = connection()
        dialing.name = "dialing"

        let downSession = hub.prepare(down)
        await hub.start(downSession, theme: .githubDark, fontSize: 14)
        let dialingSession = hub.prepare(dialing)
        let dialingStart = Task { await hub.start(dialingSession, theme: .githubDark, fontSize: 14) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(dialingSession.isDialing)

        // Too young for a path change to restart: it most likely began on
        // the new path already.
        hub.pathRedialAfter = 60
        failing.behavior = { connection in SSHSession(connection: connection, transport: QuietTransport()) }
        hanging.behavior = { connection in SSHSession(connection: connection, transport: QuietTransport()) }
        await hub.kickSessionsAfterPathChange()
        #expect(downSession.viewModel.status == .connected, "the failed session reconnects at once")
        #expect(hanging.dials == 1, "the fresh dial is left to finish")

        hub.pathRedialAfter = 0
        await hub.kickSessionsAfterPathChange()
        #expect(hanging.dials == 2, "an older dial is restarted on the new path")
        #expect(dialingSession.viewModel.status == .connected)

        gate.finish(.failure(DialFailed()))
        await dialingStart.value
        #expect(dialingSession.viewModel.status == .connected)
        await hub.disconnect(down.id)
        await hub.disconnect(dialing.id)
    }

    @Test("A later path notification cannot cancel the SSH recovery already underway")
    func laterPathChangeKeepsRecoveryAlive() async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        hub.isForeground = true
        hub.pathDebounceDelay = .milliseconds(10)
        let gate = DialGate()
        defer { gate.finish(.failure(DialFailed())) }
        let cancellations = SessionLifecycleTests.Counter()
        let script = DialScript { _ in throw DialFailed() }
        hub.makeSession = { SessionHub.ActiveSession(connection: $0, dial: script.dialer) }
        let configuration = connection()
        let session = hub.prepare(configuration)
        await session.start(theme: .githubDark, fontSize: 14)
        script.behavior = { _ in
            try await withTaskCancellationHandler {
                try await gate.wait().get()
            } onCancel: {
                cancellations.bump()
            }
        }

        hub.networkPathChanged()
        #expect(try await waitUntil { script.dials == 2 })
        // The first debounce has fired, but its real SSH handshake has not
        // finished. New path updates must neither cancel nor replace it.
        hub.networkPathChanged()
        hub.networkPathChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancellations.count == 0)
        #expect(script.dials == 2)
        #expect(session.isDialing)

        gate.finish(.success(SSHSession(connection: configuration, transport: QuietTransport())))
        #expect(try await waitUntil { session.viewModel.status == .connected })
        #expect(session.viewModel.connectionFailure == nil)
        #expect(session.viewModel.errorMessage == nil)
        hub.isForeground = false
        await hub.disconnect(configuration.id)
    }

    @Test("A burst of path notifications is debounced before recovery begins")
    func pathChangesRemainDebounced() async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        hub.isForeground = true
        hub.pathDebounceDelay = .milliseconds(100)
        let script = DialScript { _ in throw DialFailed() }
        hub.makeSession = { SessionHub.ActiveSession(connection: $0, dial: script.dialer) }
        let configuration = connection()
        let session = hub.prepare(configuration)
        await session.start(theme: .githubDark, fontSize: 14)
        script.behavior = { SSHSession(connection: $0, transport: QuietTransport()) }

        for _ in 0..<5 { hub.networkPathChanged() }
        await Task.yield()
        #expect(script.dials == 1, "A path burst must not bypass the debounce wait")
        #expect(try await waitUntil { session.viewModel.status == .connected })
        #expect(script.dials == 2)
        hub.isForeground = false
        await hub.disconnect(configuration.id)
    }

    @Test("Pending path recovery respects background and explicit disconnect", arguments: [false, true])
    func pendingPathRecoveryStops(disconnect: Bool) async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        hub.isForeground = true
        hub.pathDebounceDelay = .milliseconds(30)
        let script = DialScript { _ in throw DialFailed() }
        hub.makeSession = { SessionHub.ActiveSession(connection: $0, dial: script.dialer) }
        let configuration = connection()
        let session = hub.prepare(configuration)
        await session.start(theme: .githubDark, fontSize: 14)
        script.behavior = { SSHSession(connection: $0, transport: QuietTransport()) }

        hub.networkPathChanged()
        if disconnect {
            await hub.disconnect(configuration.id)
        } else {
            hub.setForeground(false)
            hub.networkPathChanged()
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(script.dials == 1)
        #expect(session.viewModel.status != .connected)
        hub.isForeground = false
        await hub.disconnect(configuration.id)
    }

    @Test("Disconnect retires a path recovery even when its SSH result arrives late")
    func disconnectRetiresRunningPathRecovery() async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        hub.isForeground = true
        hub.pathDebounceDelay = .milliseconds(10)
        let gate = DialGate()
        defer { gate.finish(.failure(DialFailed())) }
        let script = DialScript { _ in throw DialFailed() }
        hub.makeSession = { SessionHub.ActiveSession(connection: $0, dial: script.dialer) }
        let configuration = connection()
        let session = hub.prepare(configuration)
        await session.start(theme: .githubDark, fontSize: 14)
        script.behavior = { _ in try await gate.wait().get() }
        hub.networkPathChanged()
        #expect(try await waitUntil { script.dials == 2 })

        await hub.disconnect(configuration.id)
        let lateTransport = QuietTransport()
        gate.finish(.success(SSHSession(connection: configuration, transport: lateTransport)))
        #expect(try await waitUntil { lateTransport.shutdowns == 1 })
        #expect(hub.session(for: configuration) == nil)
        #expect(session.viewModel.status != .connected)
        #expect(script.dials == 2)
        hub.isForeground = false
    }

    @Test("Path and short foreground changes leave bounded tunnel handshakes in flight",
          arguments: [ConnectionTransport.cloudflareSSH, .tailcat, .tailscale])
    func tunnelHandshakeKeepsItsDeadline(transport: ConnectionTransport) async throws {
        var configuration = connection()
        configuration.selectTransport(transport)
        configuration.cloudflareHostname = "terminal.example.com"
        configuration.tailcatCredentialRef = TailcatCredentials.newReference()
        configuration.tailcatServerPublicKey = "nodekey:" + String(repeating: "a", count: 64)
        configuration.tailscaleAccountID = UUID().uuidString.lowercased()
        let gate = DialGate()
        defer { gate.finish(.failure(DialFailed())) }
        let script = DialScript { _ in try await gate.wait().get() }
        let session = SessionHub.ActiveSession(connection: configuration, dial: script.dialer)
        session.stalledDialGrace = 0
        let first = Task { await session.start(theme: .githubDark, fontSize: 14) }
        #expect(try await waitUntil { script.dials == 1 })

        #expect(!(await session.retryIfDown(stalledDialAfter: 0, reason: "path")))
        await session.resumeIfNeeded()
        #expect(script.dials == 1, "A path hint must not abandon a still-bounded handshake")
        #expect(session.isDialing)

        gate.finish(.success(SSHSession(connection: configuration, transport: QuietTransport())))
        await first.value
        #expect(session.viewModel.status == .connected)
        await session.stop()
    }

    @Test("Tunnel recovery still replaces an SSH session whose PTY setup is stuck",
          arguments: [false, true])
    func stalledTunnelPTYRemainsRecoverable(foreground: Bool) async throws {
        var configuration = connection()
        configuration.selectTransport(.cloudflareSSH)
        configuration.cloudflareHostname = "terminal.example.com"
        let oldTransport = DelayedPTYTransport()
        defer { oldTransport.releasePTY() }
        let oldSSH = SSHSession(connection: configuration, transport: oldTransport)
        let script = DialScript { _ in oldSSH }
        let session = SessionHub.ActiveSession(connection: configuration, dial: script.dialer)
        session.stalledDialGrace = 0
        let first = Task { await session.start(theme: .githubDark, fontSize: 14) }
        #expect(try await waitUntil { oldTransport.ptyStarted })
        #expect(session.isDialing)
        #expect(!session.viewModel.isAwaitingSSHConnection,
                "The SSH handshake returned; only PTY setup remains pending")

        let newTransport = QuietTransport()
        let replacement = SSHSession(connection: configuration, transport: newTransport)
        script.behavior = { _ in replacement }
        if foreground {
            await session.resumeIfNeeded()
        } else {
            #expect(await session.retryIfDown(stalledDialAfter: 0, reason: "path"))
        }
        #expect(script.dials == 2)
        #expect(session.viewModel.status == .connected)
        #expect(session.viewModel.session === replacement)

        // A late PTY acknowledgement belongs to the retired SSH connection.
        // It must close that transport and never replace the new terminal.
        oldTransport.releasePTY()
        await first.value
        #expect(oldTransport.shutdowns == 1)
        #expect(newTransport.shutdowns == 0)
        #expect(session.viewModel.session === replacement)
        #expect(session.viewModel.status == .connected)
        #expect(session.viewModel.errorMessage == nil)
        await session.stop()
    }

    private final class DelayedPTYTransport: SSHClientTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        private var started = false
        private var closes = 0
        var ptyStarted: Bool { lock.withLock { started } }
        var shutdowns: Int { lock.withLock { closes } }

        func run(_ command: String) async throws -> Data { Data() }

        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            await withCheckedContinuation { continuation in
                let release = lock.withLock {
                    started = true
                    guard !released else { return true }
                    waiter = continuation
                    return false
                }
                if release { continuation.resume() }
            }
            return QuietTransport.Writer()
        }

        func releasePTY() {
            let pending = lock.withLock {
                released = true
                defer { waiter = nil }
                return waiter
            }
            pending?.resume()
        }

        // Deliberately let the acknowledgement arrive after close, as an
        // uncancellable library callback can. The test releases it explicitly.
        func shutdown() async { lock.withLock { closes += 1 } }
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
