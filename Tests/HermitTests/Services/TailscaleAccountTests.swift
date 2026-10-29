import Foundation
import TailscaleSSH
import Testing
@testable import Moshpit

@Suite("Embedded Tailscale account", .serialized)
struct TailscaleAccountTests {
    private func fixture(status: TailscaleNodeStatus = .init(backendState: "NeedsLogin"),
                         grace: Duration = .zero) -> (TailscaleAccountVault, FakeAccountNode, TailscaleRuntime) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-account-test-" + UUID().uuidString)
        let vault = TailscaleAccountVault(backend: InMemoryKeychainBackend(), root: root)
        let node = FakeAccountNode(status)
        return (vault, node, TailscaleRuntime(vault: vault, peerStartupGrace: grace, factory: { _ in node }))
    }

    @Test("Opening settings without an account does not enroll a device")
    func emptyAccountDoesNotStart() async throws {
        let (vault, node, runtime) = fixture()
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.state == .signedOut)
        #expect(snapshot.accountID == nil)
        #expect(try vault.load() == nil)
        #expect(await node.starts == 0)
    }

    @Test("Explicit login preserves a stable identity and never exposes its URL in descriptions")
    func loginStateAndRedaction() async throws {
        let loginURL = URL(string: "https://login.tailscale.com/a/SECRET_LOGIN_SENTINEL")!
        let (vault, node, runtime) = fixture(status: .init(backendState: "NeedsLogin", authURL: loginURL))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let login = try await runtime.snapshot(startLogin: true)
        #expect(login.state == .needsLogin)
        #expect(login.loginURL == loginURL)
        #expect(await node.logins == 1)
        #expect(!String(reflecting: login).contains("SECRET_LOGIN_SENTINEL"))
        let first = try #require(try vault.load())
        #expect(!String(reflecting: first).contains(first.encryptionKey.base64EncodedString()))
        await node.update(.init(backendState: "Running", accountIdentity: "tailnet-A/user-1", peers: [Self.peerA]))
        let connected = try await runtime.snapshot()
        #expect(connected.state == .connected)
        #expect(connected.accountID == first.id)
        #expect(connected.loginURL == nil)
        #expect(try vault.load()?.identity == "tailnet-A/user-1")
        #expect(await node.starts == 1)
        await runtime.restart()
    }

    @Test("Login links are constrained to the actual HTTPS Tailscale login origin")
    func loginOriginValidation() {
        for bad in ["http://login.tailscale.com/a/x", "https://login.tailscale.com.evil.test/a/x",
                    "https://user:secret@login.tailscale.com/a/x", "https://login.tailscale.com:444/a/x",
                    "file:///tmp/tailscale-login"] {
            #expect(TailscaleRuntime.validLoginURL(URL(string: bad)) == nil)
        }
        #expect(TailscaleRuntime.validLoginURL(URL(string: "https://login.tailscale.com/a/x")) != nil)
    }

    @Test("SSH uses the selected stable peer identity even after its display hostname changes")
    func peerBindingAndHostTrust() async throws {
        let (vault, _, runtime) = fixture(status: .init(backendState: "Running", accountIdentity: "net/user", peers: [Self.peerA]))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = try await runtime.snapshot(startLogin: true)
        let id = try #require(account.accountID)
        let selected = TailscaleConnectionSettings(accountID: id, peerID: Self.peerA.id)
        let prepared = try await runtime.prepare(settings: selected, host: "old-name")
        #expect(prepared.host == "100.80.1.2")
        #expect(prepared.hostKeyIdentity == "tailscale:" + id + ":peer:" + Self.peerA.id)
        let manual = try await runtime.prepare(settings: .init(accountID: id, peerID: nil), host: "MAC-MINI.example.ts.net.")
        #expect(manual.host == "mac-mini.example.ts.net")
        #expect(manual.hostKeyIdentity != prepared.hostKeyIdentity)
        await #expect(throws: TailscaleAccountError.peerUnavailable) {
            try await runtime.prepare(settings: .init(accountID: id, peerID: "missing-peer"), host: "100.80.1.2")
        }
        await #expect(throws: TailscaleAccountError.accountMismatch) {
            try await runtime.prepare(settings: .init(accountID: UUID().uuidString, peerID: nil), host: "mac-mini")
        }
        await runtime.restart()
    }

    @Test("Different tailnet identity rotates the binding and closes existing streams")
    func accountChangeFailsClosed() async throws {
        let (vault, node, runtime) = fixture(status: .init(backendState: "Running", accountIdentity: "net-A/user"))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let first = try await runtime.snapshot(startLogin: true)
        await node.update(.init(backendState: "Running", accountIdentity: "net-B/user"))
        await #expect(throws: TailscaleAccountError.accountChanged) { try await runtime.snapshot() }
        let replaced = try #require(try vault.load())
        #expect(replaced.id != first.accountID)
        #expect(replaced.identity == "net-B/user")
        #expect(await node.closes == 1)
        await #expect(throws: TailscaleAccountError.accountMismatch) {
            try await runtime.prepare(settings: .init(accountID: first.accountID!, peerID: nil), host: "mac-mini")
        }
    }

    @Test("A pending device approval cannot reach SSH or trigger an implicit login")
    func approvalBlocksDial() async throws {
        let (vault, node, runtime) = fixture(status: .init(backendState: "NeedsMachineAuth"))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let record = try vault.create()
        await #expect(throws: TailscaleAccountError.approvalRequired) {
            try await runtime.prepare(settings: .init(accountID: record.id, peerID: nil), host: "mac-mini")
        }
        #expect(await node.logins == 0)
        await runtime.restart()
    }

    @Test("Concurrent first-login responses cannot overwrite an already bound account")
    func staleInitialAccountResponseFailsClosed() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let initial = try await runtime.snapshot(startLogin: true)
        await node.holdNextStatus()
        let stale = Task { try await runtime.snapshot() }
        for _ in 0..<100 {
            if await node.statusIsWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await node.statusIsWaiting)
        await node.update(.init(backendState: "Running", accountIdentity: "first-account"))
        _ = try await runtime.snapshot()
        await node.releaseStatus(.init(backendState: "Running", accountIdentity: "second-account"))
        await #expect(throws: TailscaleAccountError.accountChanged) { try await stale.value }
        let bound = try #require(try vault.load())
        #expect(bound.id != initial.accountID)
        #expect(bound.identity == "second-account")
        #expect(await node.closes == 1)
    }

    @Test("Sign-out closes the node and discards the only state decryption key")
    func logoutCleanup() async throws {
        let (vault, node, runtime) = fixture()
        _ = try await runtime.snapshot(startLogin: true)
        let previous = try #require(try vault.load())
        let directory = try vault.directory(for: previous)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        try await runtime.logout()
        #expect(try vault.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await node.closes == 1)
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.state == .signedOut)
    }

    @Test("Sign-out during native startup cannot leak a late node or resurrect credentials")
    func logoutDuringStartup() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        await node.holdStart()
        let login = Task { try await runtime.snapshot(startLogin: true) }
        for _ in 0..<100 {
            if await node.starts > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await node.starts == 1)
        let logout = Task { try await runtime.logout() }
        // Let logout capture and cancel the shared startup before release.
        try await Task.sleep(for: .milliseconds(30))
        await node.releaseStart()
        try await logout.value
        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(try vault.load() == nil)
        #expect(await node.closes == 1)
    }

    @Test("Long suspension rebuilds from the same device identity")
    func restartRetainsAccount() async throws {
        let (vault, node, runtime) = fixture(status: .init(backendState: "Running", accountIdentity: "net/user"))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let first = try await runtime.snapshot(startLogin: true)
        await runtime.restart()
        let second = try await runtime.snapshot()
        #expect(first.accountID == second.accountID)
        #expect(await node.starts == 2)
        #expect(await node.closes == 1)
        await runtime.restart()
    }

    @MainActor
    @Test("An older refresh cannot overwrite a newer connected UI state")
    func staleUIRefreshIsIgnored() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = TailscaleAccount(runtime: runtime)
        await account.startLogin()
        await node.holdNextStatus()
        let stale = Task { await account.refresh() }
        for _ in 0..<100 {
            if await node.statusIsWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await node.statusIsWaiting)
        await node.update(.init(backendState: "Running", accountIdentity: "net/user"))
        await account.refresh()
        await node.releaseStatus(.init(backendState: "NeedsLogin"))
        await stale.value
        #expect(account.state == .connected)
        #expect(account.loginURL == nil)
        await account.logout()
        #expect(account.state == .signedOut)
    }

    @MainActor
    @Test("A delayed login link ends acquisition and keeps waiting for browser authentication")
    func delayedLoginURL() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = TailscaleAccount(runtime: runtime, loginURLTimeout: .milliseconds(200),
                                       pollInterval: .milliseconds(5))
        await account.startLogin()
        let identity = try #require(try vault.load())
        #expect(account.isRequestingLoginURL)
        #expect(account.loginURL == nil)
        // Repeated actions while acquiring a link must not enroll again or
        // extend the original deadline.
        await account.startLogin()
        #expect(await node.logins == 1)
        let url = URL(string: "https://login.tailscale.com/a/DELAYED_LOGIN_SENTINEL")!
        await node.update(.init(backendState: "NeedsLogin", authURL: url))
        #expect(await eventually { account.loginURL == url })
        #expect(!account.isRequestingLoginURL)
        #expect(account.state == .needsLogin)
        try await Task.sleep(for: .milliseconds(220))
        #expect(account.state == .needsLogin)
        #expect(account.errorMessage == nil)
        #expect(try vault.load()?.id == identity.id)
        await account.logout()
    }

    @MainActor
    @Test("Missing login links time out with diagnostics and retry on the same node identity")
    func loginURLTimeoutAndRetry() async throws {
        let (vault, node, runtime) = fixture(status: .init(backendState: "NeedsLogin", healthIssues: [.dnsUnavailable]))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = TailscaleAccount(runtime: runtime, loginURLTimeout: .milliseconds(60),
                                       pollInterval: .milliseconds(5))
        await account.startLogin()
        let identity = try #require(try vault.load())
        #expect(account.diagnosticMessage != nil)
        #expect(await eventually { account.state == .failed })
        #expect(!account.isRequestingLoginURL)
        #expect(account.errorMessage == TailscaleAccountError.loginURLTimedOut.localizedDescription)
        #expect(account.healthIssues == [.dnsUnavailable])
        #expect(account.diagnosticMessage != nil)
        #expect(try vault.load()?.id == identity.id)
        #expect(try vault.load()?.stateID == identity.stateID)
        #expect(await node.closes == 0)

        let url = URL(string: "https://login.tailscale.com/a/RETRY_LOGIN_SENTINEL")!
        await node.update(.init(backendState: "NeedsLogin", authURL: url))
        await account.startLogin()
        #expect(account.state == .needsLogin)
        #expect(account.loginURL == url)
        #expect(account.errorMessage == nil)
        #expect(account.diagnosticMessage == nil)
        #expect(try vault.load()?.id == identity.id)
        #expect(try vault.load()?.stateID == identity.stateID)
        #expect(await node.starts == 1)
        #expect(await node.logins == 2)
        await account.logout()
    }

    @MainActor
    @Test("A timed-out status response cannot overwrite the next explicit login")
    func timedOutLoginIgnoresLateStatus() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = TailscaleAccount(runtime: runtime, loginURLTimeout: .milliseconds(80),
                                       pollInterval: .milliseconds(5))
        await account.startLogin()
        await node.holdNextStatus()
        #expect(await eventually { await node.statusIsWaiting })
        #expect(await eventually { account.state == .failed })
        let currentURL = URL(string: "https://login.tailscale.com/a/CURRENT_LOGIN_SENTINEL")!
        await node.update(.init(backendState: "NeedsLogin", authURL: currentURL))
        await account.startLogin()
        await node.releaseStatus(.init(backendState: "NeedsLogin", authURL: URL(string: "https://login.tailscale.com/a/OLD_LOGIN_SENTINEL")!))
        try await Task.sleep(for: .milliseconds(30))
        #expect(account.loginURL == currentURL)
        #expect(account.state == .needsLogin)
        #expect(!account.isRequestingLoginURL)
        #expect(account.errorMessage == nil)
        await account.logout()
    }

    @MainActor
    @Test("Cancelling link acquisition ignores late responses and retains the account identity")
    func cancelLoginURLAcquisition() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let account = TailscaleAccount(runtime: runtime, loginURLTimeout: .milliseconds(80),
                                       pollInterval: .milliseconds(5))
        await account.startLogin()
        let identity = try #require(try vault.load())
        await node.holdNextStatus()
        #expect(await eventually { await node.statusIsWaiting })
        await account.cancelLogin()
        await node.releaseStatus(.init(backendState: "NeedsLogin", authURL: URL(string: "https://login.tailscale.com/a/CANCELLED_LOGIN_SENTINEL")!))
        try await Task.sleep(for: .milliseconds(100))
        #expect(account.state == .signedOut)
        #expect(!account.isRequestingLoginURL)
        #expect(account.loginURL == nil)
        #expect(account.errorMessage == nil)
        #expect(try vault.load()?.id == identity.id)
        #expect(try vault.load()?.stateID == identity.stateID)
        #expect(await node.closes == 1)
        await account.logout()
    }

    @MainActor
    @Test("Restoring an unsigned node does not request login or start a login deadline")
    func restoringDoesNotStartLoginDeadline() async throws {
        let (vault, node, runtime) = fixture()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        _ = try vault.create()
        let account = TailscaleAccount(runtime: runtime, loginURLTimeout: .milliseconds(30),
                                       pollInterval: .milliseconds(5))
        await account.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(account.state == .needsLogin)
        #expect(!account.isRequestingLoginURL)
        #expect(account.errorMessage == nil)
        #expect(await node.logins == 0)
        await account.logout()
    }

    @MainActor
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return await condition()
    }

    @Test("A running node waits briefly for its first peer map, for selected and manual hosts")
    func runningBeforePeerMap() async throws {
        for selected in [true, false] {
            let (vault, node, runtime) = fixture(status: .init(backendState: "Running", accountIdentity: "net/user"),
                                                 grace: .seconds(2))
            defer { try? FileManager.default.removeItem(at: vault.root) }
            let account = try await runtime.snapshot(startLogin: true)
            let id = try #require(account.accountID)
            let preparing = Task {
                try await runtime.prepare(settings: .init(accountID: id, peerID: selected ? Self.peerA.id : nil),
                                          host: selected ? "old-label" : "mac-mini.example.ts.net")
            }
            try await Task.sleep(for: .milliseconds(40))
            await node.update(.init(backendState: "Running", accountIdentity: "net/user", peers: [Self.peerA]))
            let prepared = try await preparing.value
            #expect(prepared.host == (selected ? "100.80.1.2" : "mac-mini.example.ts.net"))
            await runtime.restart()
        }
    }

    @Test("Cancelling peer discovery does not close the shared node or launch login")
    func cancelPeerDiscovery() async throws {
        let (vault, node, runtime) = fixture(status: .init(backendState: "Running", accountIdentity: "net/user"),
                                             grace: .seconds(2))
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let record = try vault.create()
        let preparing = Task { try await runtime.prepare(settings: .init(accountID: record.id, peerID: Self.peerA.id), host: "alias") }
        try await Task.sleep(for: .milliseconds(40))
        preparing.cancel()
        await #expect(throws: CancellationError.self) { try await preparing.value }
        #expect(await node.closes == 0)
        #expect(await node.logins == 0)
        await runtime.restart()
    }

    private static let peerA = TailscalePeer(id: "n123456789", hostname: "mac-mini", dnsName: "mac-mini.example.ts.net.",
                                              addresses: ["100.80.1.2"], isOnline: true)
}

private actor FakeAccountNode: TailscaleAccountNode {
    nonisolated var nativeNode: TailscaleNode? { nil }
    private var value: TailscaleNodeStatus
    private(set) var starts = 0
    private(set) var logins = 0
    private(set) var closes = 0
    private var hold = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var holdsNextStatus = false
    private var statusContinuation: CheckedContinuation<TailscaleNodeStatus, Never>?
    var statusIsWaiting: Bool { statusContinuation != nil }
    init(_ value: TailscaleNodeStatus) { self.value = value }
    func start() async throws {
        starts += 1
        if hold { await withCheckedContinuation { startContinuation = $0 } }
    }
    func status() async throws -> TailscaleNodeStatus {
        if holdsNextStatus {
            holdsNextStatus = false
            return await withCheckedContinuation { statusContinuation = $0 }
        }
        return value
    }
    func startLogin() async throws -> TailscaleNodeStatus { logins += 1; return value }
    func logout() async throws {}
    func close() async { closes += 1 }
    func update(_ value: TailscaleNodeStatus) { self.value = value }
    func holdStart() { hold = true }
    func releaseStart() { hold = false; startContinuation?.resume(); startContinuation = nil }
    func holdNextStatus() { holdsNextStatus = true }
    func releaseStatus(_ value: TailscaleNodeStatus) { statusContinuation?.resume(returning: value); statusContinuation = nil }
}
