import Foundation
import Observation
import MoshpitKit

/// Unsent input belongs to the live connection, including while its screen is
/// offscreen. Keep it in memory only; terminal text may contain credentials.
@Observable
@MainActor
final class TerminalComposerDraft {
    var text = ""
    var isSending = false
    var errorMessage: String?
}

/// View model that owns the SSH session lifecycle for a single terminal screen.
///
/// Responsibilities:
///   - Open the ``SSHSession`` via ``SSHService`` and request a PTY.
///   - Expose coarse-grained ``Status`` for the status bar.
///   - Surface fatal errors through ``errorMessage`` so the view can alert.
///   - Forward user input and resize events back into the live session.
///
/// All UI-visible state mutates on the main actor; calls into ``SSHService``
/// hop to the service actor as needed.
@Observable
@MainActor
final class TerminalViewModel {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting   // transport dropped; auto-reconnect in progress
        case disconnected
        case failed(String)
    }

    /// A host-key decision the user must make before the connection proceeds.
    /// Set on the main actor while the SSH handshake awaits `decide`.
    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let fingerprint: String
        /// Non-nil when the host's key CHANGED (potential MITM) — carries the
        /// previously trusted fingerprint.
        let previousFingerprint: String?
        let decide: (Bool) -> Void
    }

    let connection: ServerConnection
    /// Correlate recovery with the configured route without logging a host,
    /// username, credential or user-authored connection name.
    var diagnosticSessionLabel: String {
        "session[\(connection.id.uuidString)] route=\(connection.transport?.rawValue ?? "unsupported")"
    }

    private func logConnectionPhase(_ phase: String, generation: Int,
                                    recovery: ConnectionFailure.Recovery? = nil) {
        let decision = recovery.map { String(describing: $0) } ?? "-"
        Log.ssh.notice("\(self.diagnosticSessionLabel, privacy: .public) primary-attempt=\(generation) phase=\(phase, privacy: .public) automatic=\(self.isAutoReconnectInFlight) recovery=\(decision, privacy: .public)")
    }

    private(set) var status: Status = .idle
    var errorMessage: String?
    private(set) var connectionFailure: ConnectionFailure?
    var allowsAutomaticRetry: Bool { connectionFailure?.recovery == .retry || connectionFailure == nil }
    var requiresAccessLogin: Bool { connectionFailure?.recovery == .login }

    /// What every surface showing this session's health should read.
    ///
    /// Lives here because it used to live in three places — the Terminal
    /// screen, the transport pill and the home card's row each derived it, and
    /// each derived it differently, so one reconnect could be blue on one
    /// surface, red on another and amber on a third. `status` alone is not
    /// enough to derive it (see the collapse below), which is exactly why
    /// duplicating the derivation went wrong.
    var connState: TransportConnState {
        // One state for the whole automatic reconnect, however many attempts it
        // takes: `status` flips connecting → failed → connecting on every
        // keepalive tick, and letting that through made the screen alternate
        // between "opening the pit" and "line dropped".
        //
        // It collapses to `.reconnecting` and not `.offline` because the app is
        // dialling — `.offline` means nothing is being attempted. Reporting
        // offline here turned the connecting screen red mid-reconnect, and since
        // this flag and `status` change on their own schedules, a single
        // reconnect crossed from blue to red partway through.
        if isAutoReconnectInFlight { return .reconnecting }
        switch status {
        case .connected: return .live
        case .reconnecting: return .reconnecting
        case .connecting, .idle: return .connecting
        case .failed, .disconnected: return .offline
        }
    }

    /// True from the moment the app starts re-establishing a transport the user
    /// didn't ask to re-establish, until it's back.
    ///
    /// A failure the user asked for is news — they tapped connect and it didn't
    /// happen, so a modal saying why is right. A failure inside an automatic
    /// retry is not news: the hub is already trying again on the next keepalive
    /// tick, and the connecting screen has copy for exactly this. Surfacing both
    /// meant a dropped line showed a modal error card over the terminal, then
    /// the card vanished and "opening the pit" took its place, then the card
    /// came back — two things saying the same thing, in a loop, neither of them
    /// dismissable in any way that helped.
    ///
    /// Set by ``SessionHub/ActiveSession/start(theme:fontSize:fontName:cursorShape:cursorColorId:cursorBlink:automatic:)``,
    /// cleared here the moment a transport comes up.
    private(set) var isAutoReconnectInFlight = false
    private(set) var session: SSHSession?
    /// Pending TOFU confirmation; the Terminal screen presents it as an alert.
    var hostKeyPrompt: HostKeyPrompt?

    @ObservationIgnored private let sshService: SSHService
    /// How the primary transport is dialed. Production goes through
    /// `sshService.connect`; tests inject a dialer that hands back a session
    /// over a scripted transport — or hangs, which is what a SYN into a
    /// black hole looks like from here.
    typealias Dialer = @Sendable (ServerConnection,
                                  @escaping SSHService.TrustNewHostHandler,
                                  @escaping SSHService.AcceptChangedHostHandler) async throws -> SSHSession
    @ObservationIgnored private let dial: Dialer
    /// Which dial the in-flight `start()` / `connectForExec()` belongs to.
    /// `disconnect()` while a dial is still out bumps this, and that dial's
    /// eventual verdict — success or failure — is then nobody's business:
    /// the session it returns is closed, the error it throws is dropped.
    /// Without it a dial parked on a SYN nobody answers (a VPN address with
    /// the tunnel down: 30s to the connect timeout) landed on top of the
    /// redial that had replaced it — as a stale `.failed`, or as a second
    /// session adopted over the live one.
    @ObservationIgnored private var dialGeneration = 0
    @ObservationIgnored private var awaitingSSHGeneration: Int?
    /// A tunnel's dial/auth deadlines apply until SSH returns. Opening its
    /// PTY is a separate phase and must retain the existing stalled recovery.
    var isAwaitingSSHConnection: Bool { awaitingSSHGeneration == dialGeneration }
    @ObservationIgnored private var rejectedHostKey = false
    /// Chains outgoing writes so rapid-fire input (type a word, then
    /// immediately tap an arrow key) can't reorder at the transport —
    /// independently-spawned `Task`s have no FIFO guarantee relative to each
    /// other (see TmuxSessionController.enqueue's `writeChain` for the same
    /// bug, already fixed on the -CC control path).
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    init(connection: ServerConnection, sshService: SSHService = .shared, dial: Dialer? = nil) {
        self.connection = connection
        self.sshService = sshService
        if let dial {
            self.dial = dial
        } else {
            self.dial = { connection, onUnknown, onChanged in
                try await sshService.connect(connection, onUnknownHost: onUnknown, onChangedHost: onChanged)
            }
        }
    }

    /// Suspend the SSH handshake until the user answers the host-key prompt.
    private func promptForHostKey(host: String, port: Int,
                                  fingerprint: String,
                                  previous: String?, generation: Int) async -> Bool {
        guard generation == dialGeneration else { return false }
        return await withCheckedContinuation { continuation in
            var decided = false
            hostKeyPrompt = HostKeyPrompt(
                host: host, port: port,
                fingerprint: fingerprint,
                previousFingerprint: previous
            ) { [weak self] trusted in
                guard !decided else { return }
                decided = true
                let current = self?.dialGeneration == generation
                if current {
                    self?.hostKeyPrompt = nil
                    if !trusted {
                        // Citadel can surface only a later channel timeout.
                        // Keep the user's decision and stop retries immediately.
                        self?.rejectedHostKey = true
                        self?.fail(HostKeyRejected())
                    }
                }
                continuation.resume(returning: trusted && current)
            }
        }
    }

    /// Build TOFU handlers that surface real confirmation UI: unknown hosts
    /// ask the user; CHANGED keys ask with a loud warning (default deny is the
    /// alert's cancel action). Returned fresh for each `connect()` call and
    /// passed as parameters (not installed as separate, mutable state on the
    /// shared `SSHService`) — see `SSHService.connect`'s doc comment for why
    /// that used to race concurrent sessions.
    private func hostKeyHandlers() -> (onUnknown: SSHService.TrustNewHostHandler,
                                       onChanged: SSHService.AcceptChangedHostHandler) {
        let generation = dialGeneration
        let onUnknown: SSHService.TrustNewHostHandler = { [weak self] host, port, fingerprint in
            guard let self else { return false }
            return await self.promptForHostKey(
                host: host, port: port, fingerprint: fingerprint, previous: nil, generation: generation)
        }
        let onChanged: SSHService.AcceptChangedHostHandler = { [weak self] host, port, newFingerprint, oldFingerprint in
            guard let self else { return false }
            return await self.promptForHostKey(
                host: host, port: port, fingerprint: newFingerprint, previous: oldFingerprint, generation: generation)
        }
        return (onUnknown, onChanged)
    }

    /// Flag the UI that a live transport dropped and we're auto-reconnecting.
    /// Only from a previously-live state — never interrupts an initial connect.
    func markReconnecting() {
        guard allowsAutomaticRetry else { return }
        switch status {
        case .connected, .disconnected, .failed:
            status = .reconnecting
        default:
            break
        }
    }

    /// Allow a fresh `start()` after the transport died (app suspension,
    /// network drop). Only valid from a terminal state — never interrupts a
    /// live connection.
    func resetForReconnect() {
        switch status {
        case .connecting:
            return
        default:
            // A TOFU prompt the user never answered would otherwise leak its
            // continuation into the next attempt (and re-present a stale
            // alert). Deny it so the old handshake fails cleanly.
            hostKeyPrompt?.decide(false)
            hostKeyPrompt = nil
            session = nil
            status = .idle
            errorMessage = nil
            connectionFailure = nil
        }
    }

    /// Declare who asked for the attempt about to run — see
    /// ``isAutoReconnectInFlight``. Call once, before `start`/`connectForExec`.
    func beginAttempt(automatic: Bool) {
        isAutoReconnectInFlight = automatic
    }

    /// Opens the SSH connection and requests a PTY of the given size. Safe to
    /// call only once per view-model lifetime; subsequent calls while not
    /// `.idle` are no-ops so re-renders don't trigger duplicate connects.
    func start(rows: Int = 24, cols: Int = 80) async {
        guard case .idle = status else { return }
        status = .connecting
        dialGeneration += 1
        rejectedHostKey = false
        let generation = dialGeneration
        awaitingSSHGeneration = generation
        defer {
            if awaitingSSHGeneration == generation { awaitingSSHGeneration = nil }
        }
        var pendingSession: SSHSession?
        var phase = "ssh"
        logConnectionPhase("pty-dial.started", generation: generation)
        do {
            let handlers = hostKeyHandlers()
            let newSession = try await dial(connection, handlers.onUnknown, handlers.onChanged)
            if awaitingSSHGeneration == generation { awaitingSSHGeneration = nil }
            pendingSession = newSession
            guard generation == dialGeneration else { await newSession.close(); return }
            if rejectedHostKey { throw HostKeyRejected() }
            phase = "pty"
            logConnectionPhase("ssh.connected", generation: generation)
            try await newSession.requestPTY(rows: rows, cols: cols)
            guard generation == dialGeneration else { await newSession.close(); return }
            if rejectedHostKey { throw HostKeyRejected() }
            self.session = newSession
            self.status = .connected
            self.isAutoReconnectInFlight = false
            self.connectionFailure = nil
            logConnectionPhase("pty.ready", generation: generation)
        } catch {
            await pendingSession?.close()
            // A superseded dial's failure is not this attempt's failure.
            guard generation == dialGeneration else { return }
            let failure = ConnectionFailure(rejectedHostKey ? HostKeyRejected() : error)
            logConnectionPhase("\(phase).failed", generation: generation, recovery: failure.recovery)
            connectionFailure = failure
            let message = failure.message
            self.status = .failed(message)
            if failure.recovery != .retry { isAutoReconnectInFlight = false }
            // The status carries the reason either way; only a connect the user
            // asked for earns a modal on top of it.
            if !isAutoReconnectInFlight { self.errorMessage = message }
        }
    }

    /// Connect SSH **without** requesting a PTY, for the mosh bootstrap path
    /// (we only need an exec channel to run `mosh-server`). Sets `status` and
    /// surfaces auth/connect errors exactly like `start()`.
    func connectForExec() async -> SSHSession? {
        guard case .idle = status else { return session }
        status = .connecting
        dialGeneration += 1
        rejectedHostKey = false
        let generation = dialGeneration
        awaitingSSHGeneration = generation
        defer {
            if awaitingSSHGeneration == generation { awaitingSSHGeneration = nil }
        }
        logConnectionPhase("exec-dial.started", generation: generation)
        do {
            let handlers = hostKeyHandlers()
            let newSession = try await dial(connection, handlers.onUnknown, handlers.onChanged)
            if awaitingSSHGeneration == generation { awaitingSSHGeneration = nil }
            guard generation == dialGeneration else { await newSession.close(); return nil }
            if rejectedHostKey { await newSession.close(); throw HostKeyRejected() }
            self.session = newSession
            logConnectionPhase("exec-ssh.ready", generation: generation)
            return newSession
        } catch {
            guard generation == dialGeneration else { return nil }
            let failure = ConnectionFailure(rejectedHostKey ? HostKeyRejected() : error)
            logConnectionPhase("exec-ssh.failed", generation: generation, recovery: failure.recovery)
            connectionFailure = failure
            let message = failure.message
            self.status = .failed(message)
            if failure.recovery != .retry { isAutoReconnectInFlight = false }
            if !isAutoReconnectInFlight { self.errorMessage = message }
            return nil
        }
    }

    /// Mark the session live once the mosh UDP transport is up.
    func markConnected() {
        status = .connected
        isAutoReconnectInFlight = false
        connectionFailure = nil
    }

    func fail(_ error: Error) {
        let failure = ConnectionFailure(rejectedHostKey ? HostKeyRejected() : error)
        logConnectionPhase("session.failed", generation: dialGeneration, recovery: failure.recovery)
        connectionFailure = failure
        status = .failed(failure.message)
        if failure.recovery != .retry { isAutoReconnectInFlight = false }
        if !isAutoReconnectInFlight { errorMessage = failure.message }
    }

    /// Surface a fatal mosh error through the same path as SSH failures.
    func fail(_ message: String) {
        if rejectedHostKey { fail(HostKeyRejected()); return }
        status = .failed(message)
        if !isAutoReconnectInFlight { errorMessage = message }
    }

    /// Forwards bytes from the input bar / terminal coordinator down to the
    /// remote shell. Failures are swallowed — a closed session simply drops
    /// the write and the view will reflect the new status independently.
    func send(_ data: Data) {
        guard let session else { return }
        let previous = writeChain
        writeChain = Task { [session] in
            await previous?.value
            try? await session.write(data)
        }
    }

    func sendConfirmed(_ data: Data) async throws {
        guard connState == .live, let session else { throw SSHError.sessionClosed }
        let previous = writeChain
        let operation = Task { @MainActor [weak self] in
            await previous?.value
            try Task.checkCancellation()
            guard let self, self.connState == .live, self.session === session else { throw SSHError.sessionClosed }
            try await session.write(data)
        }
        writeChain = Task { _ = try? await operation.value }
        try await operation.value
    }

    /// Propagates a viewport size change to the remote PTY. As with ``send``,
    /// transient errors are ignored; persistent failures will surface via the
    /// status path when the read loop tears down.
    func resize(rows: Int, cols: Int) {
        guard let session else { return }
        Task { [session] in
            try? await session.resize(rows: rows, cols: cols)
        }
    }

    /// Tears down the session cleanly: closes the underlying SSH client (which
    /// also breaks its `dataStream`, ending whichever pump loop is reading it)
    /// and clears local session state. The pump task itself lives on
    /// `SessionHub.ActiveSession.pumpTask`, not here — this view model owns
    /// the SSH session, not the byte-pump that feeds the terminal, and
    /// `ActiveSession.stop()` cancels its own pump task before calling this.
    func disconnect() async {
        // Disown a dial still in flight — see `dialGeneration`.
        dialGeneration += 1
        hostKeyPrompt?.decide(false)
        hostKeyPrompt = nil
        if let session {
            await session.close()
        }
        session = nil
        if case .failed = status {
            // Keep the failure visible to the user — don't overwrite with
            // "disconnected" because the alert is keyed off `errorMessage`.
        } else {
            status = .disconnected
        }
    }
}
