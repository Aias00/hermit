import Foundation
import Observation
import TailscaleSSH
import MoshpitKit

enum TailscaleAccountState: Equatable, Sendable {
    case signedOut, starting, needsLogin, needsApproval, connected, failed
}

struct TailscaleAccountPeer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let dnsName: String
    let addresses: [String]
    let isOnline: Bool
}

enum TailscaleAccountError: Error, Equatable, LocalizedError, Sendable {
    case loginRequired, accountMismatch, approvalRequired, storageUnavailable
    case invalidStoredState, peerUnavailable, starting, accountChanged, loginURLTimedOut

    var isRetryable: Bool { self == .starting }
    var errorDescription: String? {
        switch self {
        case .loginRequired: return String(localized: "Sign in to Tailscale in Settings before connecting.")
        case .accountMismatch: return String(localized: "This connection belongs to a different Tailscale account. Sign in to that account or explicitly rebind the connection.")
        case .approvalRequired: return String(localized: "Approve this Hermit device in the Tailscale admin console before connecting.")
        case .storageUnavailable: return String(localized: "Tailscale secure storage is unavailable. Unlock this device and try again.")
        case .invalidStoredState: return String(localized: "The saved Tailscale account cannot be read. Sign out and sign in again.")
        case .peerUnavailable: return String(localized: "The selected Tailscale device is no longer visible to this account. Check access permissions or select the device again.")
        case .starting: return String(localized: "Tailscale is still connecting. Please try again shortly.")
        case .accountChanged: return String(localized: "The Tailscale account changed. Review the account binding before reconnecting.")
        case .loginURLTimedOut: return String(localized: "Could not get a Tailscale login link within 30 seconds. Check your network and try signing in again.")
        }
    }
}

/// A small injectable boundary for account-state tests. Production transports
/// always use the same native node held by this manager.
protocol TailscaleAccountNode: AnyObject, Sendable {
    var nativeNode: TailscaleNode? { get }
    func start() async throws
    func status() async throws -> TailscaleNodeStatus
    func startLogin() async throws -> TailscaleNodeStatus
    func logout() async throws
    func close() async
}

final class NativeTailscaleAccountNode: TailscaleAccountNode, @unchecked Sendable {
    let node: TailscaleNode
    var nativeNode: TailscaleNode? { node }
    init(configuration: TailscaleNodeConfiguration) async throws { node = try await TailscaleNode(configuration: configuration) }
    func start() async throws { try await node.start() }
    func status() async throws -> TailscaleNodeStatus { try await node.status() }
    func startLogin() async throws -> TailscaleNodeStatus { try await node.startLogin() }
    func logout() async throws { try await node.logout() }
    func close() async { await node.close() }
}

struct TailscaleAccountSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accountID: String?
    let state: TailscaleAccountState
    let loginURL: URL?
    let peers: [TailscaleAccountPeer]
    var healthIssues: [TailscaleHealthIssue] = []
    static let signedOut = Self(accountID: nil, state: .signedOut, loginURL: nil, peers: [])
    var description: String { "TailscaleAccountSnapshot(<redacted>)" }
    var debugDescription: String { description }
}

struct TailscalePreparedConnection: Sendable {
    let client: any TailscaleAccountNode
    let host: String
    let hostKeyIdentity: String
}

actor TailscaleRuntime {
    static let shared = TailscaleRuntime()
    typealias Factory = @Sendable (TailscaleNodeConfiguration) async throws -> any TailscaleAccountNode
    private let vault: TailscaleAccountVault
    private let factory: Factory
    private var node: (any TailscaleAccountNode)?
    private var starting: (id: UUID, task: Task<any TailscaleAccountNode, Error>)?
    private var closing: Task<Void, Never>?
    private var generation = UUID()
    private var signOutOperations = 0
    private var firstRunningAt: ContinuousClock.Instant?
    private let peerStartupGrace: Duration

    init(vault: TailscaleAccountVault = TailscaleAccountVault(), peerStartupGrace: Duration = .seconds(10),
         factory: @escaping Factory = { try await NativeTailscaleAccountNode(configuration: $0) }) {
        self.vault = vault
        self.factory = factory
        self.peerStartupGrace = peerStartupGrace
    }

    private func getNode(create: Bool) async throws -> (TailscaleAccountRecord, any TailscaleAccountNode) {
        guard signOutOperations == 0 else { throw TailscaleAccountError.loginRequired }
        let currentGeneration = generation
        if let closing { await closing.value }
        try Task.checkCancellation()
        guard generation == currentGeneration, signOutOperations == 0 else { throw CancellationError() }
        guard let record = try (create ? vault.create() : vault.load()) else {
            throw TailscaleAccountError.loginRequired
        }
        if let node { return (record, node) }
        let work: (id: UUID, task: Task<any TailscaleAccountNode, Error>)
        if let starting { work = starting }
        else {
            let directory = try vault.directory(for: record)
            let configuration = try TailscaleNodeConfiguration(stateDirectory: directory,
                                                               stateEncryptionKey: record.encryptionKey,
                                                               hostname: "moshpit-" + String(record.stateID.prefix(8)))
            let factory = self.factory
            work = (UUID(), Task {
                let created = try await factory(configuration)
                do { try await created.start(); return created }
                catch { await created.close(); throw error }
            })
            starting = work
        }
        do {
            let created = try await work.task.value
            guard generation == currentGeneration else { throw CancellationError() }
            node = created
            if starting?.id == work.id { starting = nil }
            try Task.checkCancellation()
            return (record, created)
        } catch {
            if starting?.id == work.id { starting = nil }
            throw error
        }
    }

    func snapshot(startLogin: Bool = false) async throws -> TailscaleAccountSnapshot {
        if !startLogin, try vault.load() == nil { return .signedOut }
        let currentGeneration = generation
        let (record, node) = try await getNode(create: startLogin)
        let status = try await (startLogin ? node.startLogin() : node.status())
        guard generation == currentGeneration else { throw CancellationError() }
        return try await accept(status, record: record)
    }

    private func accept(_ status: TailscaleNodeStatus, record: TailscaleAccountRecord) async throws -> TailscaleAccountSnapshot {
        // status() is asynchronous. Another caller may have bound the first
        // authenticated identity while this response was in flight.
        guard let latest = try vault.load(), latest.id == record.id else { throw TailscaleAccountError.accountMismatch }
        var record = latest
        if status.backendState == "Running", let identity = status.accountIdentity, !identity.isEmpty {
            if let previous = record.identity, previous != identity {
                // A new tailnet/user must never inherit an old connection's
                // authorization just because it contains the same host name.
                record.id = UUID().uuidString.lowercased()
                record.identity = identity
                try vault.save(record)
                await stopNode()
                throw TailscaleAccountError.accountChanged
            }
            if record.identity == nil { record.identity = identity; try vault.save(record) }
        }
        let state: TailscaleAccountState
        switch status.backendState {
        case "Running":
            if firstRunningAt == nil { firstRunningAt = .now }
            // The first map can trail backend startup. Do not expose peers or
            // allow SSH until the account identity is available and bound.
            state = record.identity != nil && status.accountIdentity == record.identity ? .connected : .starting
        case "NeedsLogin": state = .needsLogin
        case "NeedsMachineAuth": state = .needsApproval
        default: state = .starting
        }
        let peers = status.peers.map {
            TailscaleAccountPeer(id: $0.id, name: $0.hostname, dnsName: $0.dnsName,
                                 addresses: $0.addresses, isOnline: $0.isOnline)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return TailscaleAccountSnapshot(accountID: record.id, state: state,
                                        loginURL: state == .needsLogin ? Self.validLoginURL(status.authURL) : nil,
                                        peers: state == .connected ? peers : [], healthIssues: status.healthIssues)
    }

    static func validLoginURL(_ url: URL?) -> URL? {
        guard let url, TailscaleNodeStatus.isTrustedLoginURL(url) else { return nil }
        return url
    }

    func prepare(settings: TailscaleConnectionSettings, host: String) async throws -> TailscalePreparedConnection {
        let currentGeneration = generation
        guard let saved = try vault.load() else { throw TailscaleAccountError.loginRequired }
        guard saved.id == settings.accountID else { throw TailscaleAccountError.accountMismatch }
        let (record, node) = try await getNode(create: false)
        let manualHost = settings.peerID == nil ? try TailscaleSSHDialer.normalizedHost(host) : nil
        while true {
            try Task.checkCancellation()
            let status = try await node.status()
            guard generation == currentGeneration else { throw CancellationError() }
            let snapshot = try await accept(status, record: record)
            guard snapshot.accountID == settings.accountID else { throw TailscaleAccountError.accountMismatch }
            switch snapshot.state {
            case .connected: break
            case .needsApproval: throw TailscaleAccountError.approvalRequired
            case .signedOut, .needsLogin: throw TailscaleAccountError.loginRequired
            default: throw TailscaleAccountError.starting
            }
            let peer = snapshot.peers.first { candidate in
                if let peerID = settings.peerID { return candidate.id == peerID && !candidate.addresses.isEmpty }
                guard let manualHost else { return false }
                let dns = candidate.dnsName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return candidate.addresses.contains(manualHost) || dns == manualHost
                    || dns.split(separator: ".").first.map(String.init) == manualHost
                    || candidate.name.lowercased() == manualHost
            }
            if let peer {
                let target = manualHost ?? peer.addresses[0]
                let identity = settings.peerID.map { "peer:" + $0 } ?? "host:" + target
                return TailscalePreparedConnection(client: node, host: target,
                                                   hostKeyIdentity: "tailscale:" + settings.accountID + ":" + identity)
            }
            // A restored node can report Running with a cached/self-only map
            // before its peers arrive. This was reproduced in the live SSH
            // restart test. Give only a new node a bounded discovery window;
            // an established node losing a peer still requires user action.
            guard let firstRunningAt, ContinuousClock.now < firstRunningAt.advanced(by: peerStartupGrace) else {
                throw TailscaleAccountError.peerUnavailable
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Close first, then rebuild from encrypted state. Creating a second node
    /// for the same directory while the old one is closing is forbidden.
    func restart() async {
        await stopNode()
    }

    func cancelLogin() async { await stopNode() }

    func logout() async throws {
        // Stop all streams before discarding their account. Local sign-out
        // works offline and never claims to revoke a server-side node.
        signOutOperations += 1
        defer { signOutOperations -= 1 }
        await stopNode()
        try vault.delete()
    }

    private func stopNode() async {
        generation = UUID()
        let previousClose = closing
        let existing = node
        let pending = starting?.task
        node = nil
        firstRunningAt = nil
        starting = nil
        pending?.cancel()
        let task = Task {
            if let previousClose { await previousClose.value }
            if let existing { await existing.close() }
            if let pending, let created = try? await pending.value { await created.close() }
        }
        closing = task
        await task.value
    }
}

@MainActor @Observable
final class TailscaleAccount {
    static let shared = TailscaleAccount()
    private(set) var state: TailscaleAccountState = .signedOut
    private(set) var peers: [TailscaleAccountPeer] = []
    private(set) var accountID: String?
    private(set) var loginURL: URL?
    private(set) var errorMessage: String?
    private(set) var healthIssues: [TailscaleHealthIssue] = []
    private(set) var isRequestingLoginURL = false
    @ObservationIgnored private let runtime: TailscaleRuntime
    @ObservationIgnored private let loginURLTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var loginDeadline: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var refreshRequest = UUID()

    init(runtime: TailscaleRuntime = .shared, loginURLTimeout: Duration = .seconds(30),
         pollInterval: Duration = .seconds(2)) {
        self.runtime = runtime
        self.loginURLTimeout = loginURLTimeout
        self.pollInterval = pollInterval
    }

    /// Only fixed native classifications reach the UI; control-plane messages
    /// can contain a login capability or account details and must stay private.
    var diagnosticMessage: String? {
        guard isRequestingLoginURL || state == .failed else { return nil }
        if healthIssues.contains(.networkUnavailable) {
            return String(localized: "Tailscale cannot find an available network connection.")
        }
        if healthIssues.contains(.dnsUnavailable) {
            return String(localized: "Tailscale cannot resolve its login server. Check your network's DNS settings.")
        }
        if healthIssues.contains(.tlsFailure) {
            return String(localized: "Tailscale could not establish a secure connection to its login server.")
        }
        if healthIssues.contains(.timeout) {
            return String(localized: "The Tailscale login server is taking too long to respond.")
        }
        if healthIssues.contains(.controlUnreachable) {
            return String(localized: "Tailscale cannot reach its login server on this network.")
        }
        return nil
    }

    func refresh() async {
        let id = operation
        let request = UUID()
        refreshRequest = request
        do {
            let snapshot = try await runtime.snapshot()
            guard operation == id, refreshRequest == request else { return }
            apply(snapshot)
            pollIfNeeded()
        } catch is CancellationError { }
        catch { if operation == id, refreshRequest == request { fail(error) } }
    }

    func startLogin() async {
        // One explicit action owns one deadline. Repeated taps must not restart
        // enrollment or extend an attempt that cannot obtain a login link.
        guard !isRequestingLoginURL else { return }
        polling?.cancel(); polling = nil
        operation = UUID()
        refreshRequest = UUID()
        let id = operation
        state = .starting
        errorMessage = nil
        loginURL = nil
        healthIssues = []
        isRequestingLoginURL = true
        startLoginDeadline(operationID: id)
        Log.ssh.notice("tailscale: requesting login link")
        do {
            let snapshot = try await runtime.snapshot(startLogin: true)
            guard operation == id else { return }
            refreshRequest = UUID()
            apply(snapshot)
            pollIfNeeded()
        } catch is CancellationError { }
        catch { if operation == id { fail(error) } }
    }

    func cancelLogin() async {
        finishLoginURLRequest()
        operation = UUID()
        refreshRequest = UUID()
        let id = operation
        polling?.cancel(); polling = nil
        loginURL = nil
        state = .starting
        peers = []
        await runtime.cancelLogin()
        guard operation == id else { return }
        state = .signedOut
        peers = []
        errorMessage = nil
        healthIssues = []
    }

    func logout() async {
        finishLoginURLRequest()
        operation = UUID()
        refreshRequest = UUID()
        let id = operation
        polling?.cancel(); polling = nil
        loginURL = nil
        state = .starting
        peers = []
        do {
            try await runtime.logout()
            guard operation == id else { return }
            apply(.signedOut)
        } catch { if operation == id { fail(error) } }
    }

    func resume(forceRebuild: Bool = false) async {
        if forceRebuild { await runtime.restart() }
        await refresh()
        pollIfNeeded()
    }

    private func apply(_ snapshot: TailscaleAccountSnapshot) {
        if state != snapshot.state || healthIssues != snapshot.healthIssues || (loginURL != nil) != (snapshot.loginURL != nil) {
            let stateName = String(describing: snapshot.state)
            let healthCodes = snapshot.healthIssues.map(\.rawValue).joined(separator: ",")
            Log.ssh.notice("tailscale: state=\(stateName, privacy: .public) login_link=\(snapshot.loginURL != nil, privacy: .public) health=\(healthCodes, privacy: .public)")
        }
        state = snapshot.state
        peers = snapshot.peers
        accountID = snapshot.accountID
        loginURL = snapshot.loginURL
        healthIssues = snapshot.healthIssues
        errorMessage = nil
        if snapshot.loginURL != nil || snapshot.state == .connected || snapshot.state == .needsApproval {
            finishLoginURLRequest()
        }
    }

    private func fail(_ error: Error) {
        finishLoginURLRequest()
        state = .failed
        loginURL = nil
        peers = []
        if let account = error as? TailscaleAccountError { errorMessage = account.localizedDescription }
        else if let transport = error as? TailscaleSSHTransportError { errorMessage = transport.moshpitMessage }
        else { errorMessage = String(localized: "Tailscale could not connect. Check your network and try again.") }
    }

    private func startLoginDeadline(operationID: UUID) {
        loginDeadline?.cancel()
        let timeout = loginURLTimeout
        loginDeadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.operation == operationID, self.isRequestingLoginURL else { return }
            // Invalidate late startup/status responses without deleting the
            // account or stopping its node. A retry uses the same identity.
            self.operation = UUID()
            self.refreshRequest = UUID()
            self.polling?.cancel(); self.polling = nil
            self.fail(TailscaleAccountError.loginURLTimedOut)
            Log.ssh.notice("tailscale: login link request timed out")
        }
    }

    private func finishLoginURLRequest() {
        loginDeadline?.cancel()
        loginDeadline = nil
        isRequestingLoginURL = false
    }

    private func pollIfNeeded() {
        guard polling == nil, state == .starting || state == .needsLogin || state == .needsApproval else { return }
        let id = operation
        let interval = pollInterval
        polling = Task { [weak self] in
            defer { if self?.operation == id { self?.polling = nil } }
            for _ in 0..<300 {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.operation == id else { return }
                await self.refresh()
                if self.state == .connected || self.state == .signedOut || self.state == .failed { return }
            }
        }
    }
}
