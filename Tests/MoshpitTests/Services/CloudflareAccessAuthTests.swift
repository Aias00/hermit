import CloudflareAccess
import Foundation
import Testing
@testable import Moshpit

@Suite("Cloudflare Access credential lifecycle", .serialized)
struct CloudflareAccessAuthTests {
    private func settings(host: String = "terminal.example.com", audience: String = "aud-one") -> CloudflareConnectionSettings {
        CloudflareConnectionSettings(hostname: host, teamDomain: "test.cloudflareaccess.com", audience: audience)
    }

    /// Deliberately synthetic credentials: these tests inject the validator and
    /// exercise persistence/concurrency, not Cloudflare authentication.
    private func credentials(_ settings: CloudflareConnectionSettings, subject: String = "user-one",
                             expiry: Date = Date().addingTimeInterval(3600)) throws -> AccessCredentials {
        let application = try CloudflareAccessAuth.application(settings)
        let data = try JSONSerialization.data(withJSONObject: [
            "application": ["hostname": application.hostname, "audience": application.audience, "teamDomain": application.teamDomain],
            "applicationToken": "synthetic-unit-test-credential",
            "identity": ["subject": subject, "email": subject + "@example.invalid", "issuer": application.issuer,
                         "audiences": [application.audience], "expiresAt": expiry.timeIntervalSinceReferenceDate],
        ])
        return try JSONDecoder().decode(AccessCredentials.self, from: data)
    }

    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }

    private actor Gate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    /// Pauses the account-index write to distinguish a fully persisted shared
    /// task from a task that merely finishes browser login and validation.
    private final class RecordingBackend: KeychainBackend, @unchecked Sendable {
        let inner = InMemoryKeychainBackend()
        private let lock = NSLock()
        private let releaseWrite = DispatchSemaphore(value: 0)
        private var paused = false
        private var accounts: Set<String> = []
        private var shouldPause = false
        private var deletionFails = false
        private var failBindingWrite = false
        private var gateRollbackRead = false
        private var pauseAccountRead = false
        private var accountReadPaused = false
        var rollbackReadEntered: Bool { lock.withLock { accountReadPaused } }
        var indexWriteEntered: Bool { lock.withLock { paused } }
        var recordedAccounts: Set<String> { lock.withLock { accounts } }
        func pauseNextIndexWrite() { lock.withLock { shouldPause = true } }
        func release() { releaseWrite.signal() }
        func failDeletion() { lock.withLock { deletionFails = true } }
        func failNextBindingWrite(pauseRollbackRead: Bool = false) {
            lock.withLock { failBindingWrite = true; gateRollbackRead = pauseRollbackRead }
        }
        func save(secret: Data, account: String, requireBiometry: Bool) throws {
            let pause = lock.withLock { () -> Bool in
                accounts.insert(account)
                guard shouldPause, account.hasSuffix(".account") else { return false }
                shouldPause = false; paused = true
                return true
            }
            if pause { _ = releaseWrite.wait(timeout: .now() + 10) }
            let failBinding = lock.withLock { () -> Bool in
                guard failBindingWrite, account.hasPrefix("moshpit.cloudflare.binding.v1.") else { return false }
                failBindingWrite = false
                if gateRollbackRead { pauseAccountRead = true; gateRollbackRead = false }
                return true
            }
            if failBinding {
                // System Keychain replacement deletes the old item before add.
                try inner.delete(account: account)
                throw KeychainError.invalidData
            }
            try inner.save(secret: secret, account: account, requireBiometry: requireBiometry)
        }
        func load(account: String, prompt: String) throws -> Data {
            let pause = lock.withLock { () -> Bool in
                guard pauseAccountRead, account.hasSuffix(".account") else { return false }
                pauseAccountRead = false; accountReadPaused = true
                return true
            }
            if pause { _ = releaseWrite.wait(timeout: .now() + 10) }
            return try inner.load(account: account, prompt: prompt)
        }
        func delete(account: String) throws {
            if lock.withLock({ deletionFails }) { throw KeychainError.notFound }
            try inner.delete(account: account)
        }
        func exists(account: String) -> Bool { inner.exists(account: account) }
    }

    @Test("Concurrent callers await one login and the completed Keychain write")
    func concurrentLoginIncludesPersistence() async throws {
        let configuration = settings(), token = try credentials(configuration), calls = Counter()
        let backend = RecordingBackend(), keychain = KeychainService(backend: backend)
        backend.pauseNextIndexWrite()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in await calls.increment(); return token }, validate: { credentials, _ in credentials })
        let first = Task { try await auth.authorize(settings: configuration) }
        while !backend.indexWriteEntered { await Task.yield() }
        let completed = Counter(), joined = Counter()
        let second = Task {
            await joined.increment()
            let result = try await auth.authorize(settings: configuration)
            await completed.increment()
            return result
        }
        while await joined.count == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await completed.count == 0)
        backend.release()
        #expect(try await first.value == "user-one@example.invalid")
        #expect(try await second.value == "user-one@example.invalid")
        #expect(await calls.count == 1)
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired }, validate: { credentials, _ in credentials })
        #expect(try await restored.credentials(settings: configuration).identity.subject == "user-one")
    }

    @Test("Sign-out during an uncooperative login cannot republish credentials")
    func signOutDuringLogin() async throws {
        let configuration = settings(), token = try credentials(configuration), gate = Gate()
        let keychain = KeychainService.inMemory()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in await gate.wait(); return token }, validate: { credentials, _ in credentials })
        let login = Task { try await auth.authorize(settings: configuration) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: configuration)
        await gate.release()
        do { _ = try await login.value; Issue.record("cancelled login must not succeed") } catch {}
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: configuration) }
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired }, validate: { credentials, _ in credentials })
        await #expect(throws: CloudflareAuthError.loginRequired) { try await restored.credentials(settings: configuration) }
    }

    @Test("Sign-out waits for an index write and removes its late result")
    func signOutDuringPersistence() async throws {
        let configuration = settings(), token = try credentials(configuration)
        let backend = RecordingBackend(), keychain = KeychainService(backend: backend)
        backend.pauseNextIndexWrite()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in token }, validate: { credentials, _ in credentials })
        let login = Task { try await auth.authorize(settings: configuration) }
        while !backend.indexWriteEntered { await Task.yield() }
        let started = Counter()
        let logout = Task { await started.increment(); try await auth.signOut(settings: configuration) }
        while await started.count == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        backend.release()
        try await logout.value
        do { _ = try await login.value; Issue.record("retired login must not succeed") } catch {}
        #expect(backend.recordedAccounts.allSatisfy { !backend.exists(account: $0) })
    }

    @Test("Hostname, team and audience changes cannot reuse another scope")
    func scopeIsolation() async throws {
        let original = settings(), token = try credentials(original)
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in token }, validate: { credentials, _ in credentials })
        _ = try await auth.authorize(settings: original)
        var otherTeam = original; otherTeam.teamDomain = "other.cloudflareaccess.com"
        for changed in [settings(host: "other.example.com"), settings(audience: "aud-two"), otherTeam] {
            await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: changed) }
        }
        #expect(try await auth.credentials(settings: original).identity.subject == "user-one")
    }

    @Test("Restart revalidates once and a failed signature or expired session is not cached")
    func restartAndExpiredToken() async throws {
        let configuration = settings(), token = try credentials(configuration), keychain = KeychainService.inMemory()
        let first = CloudflareAccessAuth(keychain: keychain, login: { _ in token }, validate: { credentials, _ in credentials })
        _ = try await first.authorize(settings: configuration)
        let calls = Counter()
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired },
            validate: { credentials, _ in await calls.increment(); return credentials })
        _ = try await restored.credentials(settings: configuration)
        _ = try await restored.credentials(settings: configuration)
        #expect(await calls.count == 1)
        let invalid = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired }, validate: { _, _ in throw AccessError.expiredToken })
        await #expect(throws: AccessError.expiredToken) { try await invalid.credentials(settings: configuration) }
        await #expect(throws: AccessError.expiredToken) { try await invalid.credentials(settings: configuration) }
        let expired = try credentials(configuration, expiry: Date().addingTimeInterval(-1))
        let expiredLogin = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in expired }, validate: { credentials, _ in credentials })
        await #expect(throws: CloudflareAuthError.loginRequired) { try await expiredLogin.authorize(settings: configuration) }
    }

    @Test("Changing the account replaces only that scope's previous credential")
    func accountReplacement() async throws {
        let configuration = settings(), firstToken = try credentials(configuration), secondToken = try credentials(configuration, subject: "user-two")
        let backend = RecordingBackend(), keychain = KeychainService(backend: backend)
        let first = CloudflareAccessAuth(keychain: keychain, login: { _ in firstToken }, validate: { credentials, _ in credentials })
        _ = try await first.authorize(settings: configuration)
        let previous = backend.recordedAccounts.filter { !$0.hasSuffix(".account") }
        let second = CloudflareAccessAuth(keychain: keychain, login: { _ in secondToken }, validate: { credentials, _ in credentials })
        _ = try await second.authorize(settings: configuration)
        #expect(previous.allSatisfy { !backend.exists(account: $0) })
        #expect(try await second.credentials(settings: configuration).identity.subject == "user-two")
    }

    @Test("An invalidated scope stays blocked in memory even if Keychain deletion fails")
    func failedDeletionDoesNotRestoreRevokedToken() async throws {
        let configuration = settings(), token = try credentials(configuration)
        let backend = RecordingBackend()
        let auth = CloudflareAccessAuth(keychain: KeychainService(backend: backend),
            login: { _ in token }, validate: { credentials, _ in credentials })
        _ = try await auth.authorize(settings: configuration)
        backend.failDeletion()
        await auth.invalidate(settings: configuration)
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: configuration) }
    }

    @Test("User cancellation produces no credential record")
    func cancelledBrowser() async throws {
        let backend = RecordingBackend()
        let auth = CloudflareAccessAuth(keychain: KeychainService(backend: backend),
            login: { _ in throw CloudflareAuthError.cancelled }, validate: { credentials, _ in credentials })
        await #expect(throws: CloudflareAuthError.cancelled) { try await auth.authorize(settings: settings()) }
        #expect(backend.recordedAccounts.isEmpty)
    }

    @Test("A restart validation finishing after sign-out cannot restore memory")
    func lateValidationAfterSignOut() async throws {
        let configuration = settings(), token = try credentials(configuration), gate = Gate()
        let keychain = KeychainService.inMemory()
        let first = CloudflareAccessAuth(keychain: keychain, login: { _ in token }, validate: { credentials, _ in credentials })
        _ = try await first.authorize(settings: configuration)
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired },
            validate: { credentials, _ in await gate.wait(); return credentials })
        let loading = Task { try await restored.credentials(settings: configuration) }
        while !(await gate.entered) { await Task.yield() }
        try await restored.signOut(settings: configuration)
        await gate.release()
        await #expect(throws: CloudflareAuthError.loginRequired) { try await loading.value }
        await #expect(throws: CloudflareAuthError.loginRequired) { try await restored.credentials(settings: configuration) }
    }

    @Test("A retired login cannot overwrite a new login for the same scope")
    func lateLoginAfterNewAuthorization() async throws {
        let configuration = settings(), old = try credentials(configuration), newer = try credentials(configuration, subject: "user-two")
        let gate = Gate(), calls = Counter(), keychain = KeychainService.inMemory()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in
                await calls.increment()
                if await calls.count == 1 { await gate.wait(); return old }
                return newer
            }, validate: { credentials, _ in credentials })
        let retired = Task { try await auth.authorize(settings: configuration) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: configuration)
        #expect(try await auth.authorize(settings: configuration) == "user-two@example.invalid")
        await gate.release()
        do { _ = try await retired.value; Issue.record("retired login must not succeed") } catch {}
        #expect(try await auth.credentials(settings: configuration).identity.subject == "user-two")
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired }, validate: { credentials, _ in credentials })
        #expect(try await restored.credentials(settings: configuration).identity.subject == "user-two")
    }

    @Test("Cancelling the owning caller cancels an uncooperative login and prevents persistence")
    func cancelledOwnerCannotPersist() async throws {
        let configuration = settings(), token = try credentials(configuration), gate = Gate()
        let backend = RecordingBackend(), cancellation = SessionLifecycleTests.Counter()
        let auth = CloudflareAccessAuth(keychain: KeychainService(backend: backend), login: { _ in
            await withTaskCancellationHandler {
                await gate.wait() // Deliberately ignores cancellation until released.
                return token
            } onCancel: { cancellation.bump() }
        }, validate: { credentials, _ in credentials })
        let owner = Task { try await auth.authorize(settings: configuration) }
        while !(await gate.entered) { await Task.yield() }
        owner.cancel()
        for _ in 0..<100 where cancellation.count == 0 { await Task.yield() }
        #expect(cancellation.count == 1)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(backend.recordedAccounts.isEmpty)
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: configuration) }
    }

    @Test("Cancelling a joined caller leaves the owning browser login intact")
    func cancelledJoinerDoesNotCancelOwner() async throws {
        let configuration = settings(), token = try credentials(configuration), gate = Gate()
        let cancellation = SessionLifecycleTests.Counter(), joined = Counter()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in
            await withTaskCancellationHandler {
                await gate.wait()
                return token
            } onCancel: { cancellation.bump() }
        }, validate: { credentials, _ in credentials })
        let owner = Task { try await auth.authorize(settings: configuration) }
        while !(await gate.entered) { await Task.yield() }
        let joiner = Task { await joined.increment(); return try await auth.authorize(settings: configuration) }
        while await joined.count == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        joiner.cancel()
        await gate.release()
        #expect(try await owner.value == "user-one@example.invalid")
        await #expect(throws: CancellationError.self) { try await joiner.value }
        #expect(cancellation.count == 0)
        #expect(try await auth.credentials(settings: configuration).identity.subject == "user-one")
    }

    private func automatic(_ host: String = "terminal.example.com") -> CloudflareConnectionSettings {
        CloudflareConnectionSettings(hostname: host, teamDomain: "", audience: "")
    }

    @Test("An unbound automatic connection never discovers or opens a browser during ordinary reads and logout")
    func automaticReadDoesNotDiscover() async throws {
        let discovery = Counter(), browser = Counter()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in
            await browser.increment(); throw CloudflareAuthError.loginRequired
        }, validate: { value, _ in value }, discover: { _ in
            await discovery.increment(); throw AccessError.networkFailure
        })
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: automatic()) }
        #expect(await auth.accountLabel(settings: automatic()) == nil)
        try await auth.signOut(settings: automatic())
        await auth.invalidate(settings: automatic())
        #expect(await discovery.count == 0)
        #expect(await browser.count == 0)
    }

    @Test("Explicit automatic login persists a verified binding and restores it without rediscovery")
    func automaticLoginAndRestart() async throws {
        let manual = settings(), token = try credentials(manual)
        let application = token.application, keychain = KeychainService.inMemory()
        let discoveries = Counter(), validations = Counter()
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in token },
            validate: { value, _ in await validations.increment(); return value },
            discover: { _ in await discoveries.increment(); return application })
        #expect(try await auth.authorize(settings: automatic()) == "user-one@example.invalid")
        #expect(try await auth.credentials(settings: automatic()).application == application)
        let restored = CloudflareAccessAuth(keychain: keychain,
            login: { _ in throw CloudflareAuthError.loginRequired },
            validate: { value, _ in await validations.increment(); return value },
            discover: { _ in await discoveries.increment(); throw AccessError.networkFailure })
        #expect(try await restored.credentials(settings: automatic()).identity.subject == "user-one")
        #expect(await restored.accountLabel(settings: automatic()) == "user-one@example.invalid")
        #expect(await discoveries.count == 1)
        #expect(await validations.count == 2)
        await #expect(throws: CloudflareAuthError.loginRequired) {
            try await restored.credentials(settings: automatic("other.example.com"))
        }
    }

    @Test("Automatic logout removes the binding and credential without rediscovery, including after restart")
    func automaticSignOutAndRestart() async throws {
        let token = try credentials(settings()), keychain = KeychainService.inMemory(), discoveries = Counter()
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in token }, validate: { value, _ in value },
            discover: { _ in await discoveries.increment(); return token.application })
        _ = try await auth.authorize(settings: automatic())
        try await auth.signOut(settings: automatic())
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: automatic()) }
        let restored = CloudflareAccessAuth(keychain: keychain, login: { _ in token }, validate: { value, _ in value },
            discover: { _ in await discoveries.increment(); return token.application })
        #expect(await restored.accountLabel(settings: automatic()) == nil)
        #expect(await discoveries.count == 1)
        await #expect(throws: CloudflareAuthError.loginRequired) { try await restored.credentials(settings: settings()) }
    }

    @Test("Same-host automatic logins coalesce discovery, browser and binding persistence")
    func automaticConcurrentLogin() async throws {
        let token = try credentials(settings()), gate = Gate(), discoveries = Counter(), browser = Counter()
        let keychain = KeychainService.inMemory()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in await browser.increment(); return token }, validate: { value, _ in value },
            discover: { _ in await discoveries.increment(); await gate.wait(); return token.application })
        let first = Task { try await auth.authorize(settings: automatic()) }
        while !(await gate.entered) { await Task.yield() }
        let second = Task { try await auth.authorize(settings: automatic()) }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        #expect(try await first.value == "user-one@example.invalid")
        #expect(try await second.value == "user-one@example.invalid")
        #expect(await discoveries.count == 1)
        #expect(await browser.count == 1)
        #expect(try await auth.credentials(settings: automatic()).application == token.application)
    }

    @Test("Failed discovery or signature validation preserves an earlier verified automatic binding")
    func automaticFailedRefreshKeepsBinding() async throws {
        let old = try credentials(settings()), newer = try credentials(settings(audience: "aud-two"), subject: "user-two")
        let keychain = KeychainService.inMemory()
        let seed = CloudflareAccessAuth(keychain: keychain, login: { _ in old }, validate: { value, _ in value },
            discover: { _ in old.application })
        _ = try await seed.authorize(settings: automatic())
        let discoveryFailure = CloudflareAccessAuth(keychain: keychain, login: { _ in newer },
            validate: { value, _ in value }, discover: { _ in throw AccessError.invalidMetadata })
        await #expect(throws: AccessError.invalidMetadata) { try await discoveryFailure.authorize(settings: automatic()) }
        #expect(try await discoveryFailure.credentials(settings: automatic()).application == old.application)
        let validationFailure = CloudflareAccessAuth(keychain: keychain, login: { _ in newer },
            validate: { value, _ in
                if value.application == newer.application { throw AccessError.invalidSignature }
                return value
            }, discover: { _ in newer.application })
        await #expect(throws: AccessError.invalidSignature) { try await validationFailure.authorize(settings: automatic()) }
        #expect(try await validationFailure.credentials(settings: automatic()).application == old.application)
        await #expect(throws: CloudflareAuthError.loginRequired) {
            try await validationFailure.credentials(settings: settings(audience: "aud-two"))
        }
    }

    @Test("A freshly verified audience replaces only the automatic binding and remains fully scope isolated")
    func automaticNewAudienceUsesNewScope() async throws {
        let old = try credentials(settings()), newer = try credentials(settings(audience: "aud-two"), subject: "user-two")
        let discoveries = Counter(), keychain = KeychainService.inMemory()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { application in application == old.application ? old : newer }, validate: { value, _ in value },
            discover: { _ in
                await discoveries.increment()
                return await discoveries.count == 1 ? old.application : newer.application
            })
        _ = try await auth.authorize(settings: automatic())
        _ = try await auth.authorize(settings: automatic())
        #expect(try await auth.credentials(settings: automatic()).identity.subject == "user-two")
        #expect(try await auth.credentials(settings: settings()).identity.subject == "user-one")
        #expect(try await auth.credentials(settings: settings(audience: "aud-two")).identity.subject == "user-two")
        let restored = CloudflareAccessAuth(keychain: keychain, login: { _ in throw CloudflareAuthError.loginRequired },
            validate: { value, _ in value }, discover: { _ in throw AccessError.networkFailure })
        #expect(try await restored.credentials(settings: automatic()).application == newer.application)
    }

    @Test("Sign-out during an uncooperative automatic discovery cannot publish a late binding")
    func automaticSignOutDuringDiscovery() async throws {
        let token = try credentials(settings()), gate = Gate(), keychain = KeychainService.inMemory(), browser = Counter()
        let auth = CloudflareAccessAuth(keychain: keychain,
            login: { _ in await browser.increment(); return token }, validate: { value, _ in value },
            discover: { _ in await gate.wait(); return token.application })
        let attempt = Task { try await auth.authorize(settings: automatic()) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: automatic())
        await gate.release()
        do { _ = try await attempt.value; Issue.record("retired discovery must not succeed") } catch {}
        #expect(await browser.count == 0)
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: automatic()) }
    }

    @Test("Cancelling automatic refresh restores the previous binding even during an account-index write")
    func automaticCancelledPersistenceRestoresOldBinding() async throws {
        let old = try credentials(settings()), newer = try credentials(settings(), subject: "user-two")
        let backend = RecordingBackend(), keychain = KeychainService(backend: backend)
        let seed = CloudflareAccessAuth(keychain: keychain, login: { _ in old }, validate: { value, _ in value },
            discover: { _ in old.application })
        _ = try await seed.authorize(settings: automatic())
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in newer }, validate: { value, _ in value },
            discover: { _ in newer.application })
        backend.pauseNextIndexWrite()
        let attempt = Task { try await auth.authorize(settings: automatic()) }
        while !backend.indexWriteEntered { await Task.yield() }
        attempt.cancel()
        for _ in 0..<10 { await Task.yield() }
        backend.release()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(try await auth.credentials(settings: automatic()).identity.subject == "user-one")
        let restored = CloudflareAccessAuth(keychain: keychain, login: { _ in throw CloudflareAuthError.loginRequired },
            validate: { value, _ in value }, discover: { _ in throw AccessError.networkFailure })
        #expect(try await restored.credentials(settings: automatic()).identity.subject == "user-one")
    }

    @Test("A failed binding replace restores both the old binding and its old account index")
    func automaticBindingWriteFailureRollsBack() async throws {
        let old = try credentials(settings()), newer = try credentials(settings(), subject: "user-two")
        let backend = RecordingBackend(), keychain = KeychainService(backend: backend)
        let seed = CloudflareAccessAuth(keychain: keychain, login: { _ in old }, validate: { value, _ in value },
            discover: { _ in old.application })
        _ = try await seed.authorize(settings: automatic())
        backend.failNextBindingWrite()
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in newer }, validate: { value, _ in value },
            discover: { _ in newer.application })
        await #expect(throws: CloudflareAuthError.credentialStorage) { try await auth.authorize(settings: automatic()) }
        #expect(try await auth.credentials(settings: automatic()).identity.subject == "user-one")
        let restored = CloudflareAccessAuth(keychain: keychain, login: { _ in old }, validate: { value, _ in value },
            discover: { _ in throw AccessError.networkFailure })
        #expect(try await restored.credentials(settings: automatic()).identity.subject == "user-one")
    }

    @Test("Discovery cannot bind a different hostname even when the injected verifier accepts its token")
    func automaticDiscoveryHostMustMatch() async throws {
        let other = try credentials(settings(host: "other.example.com")), browser = Counter()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in await browser.increment(); return other },
            validate: { value, _ in value }, discover: { _ in other.application })
        await #expect(throws: AccessError.invalidMetadata) { try await auth.authorize(settings: automatic()) }
        #expect(await browser.count == 0)
        #expect(await auth.accountLabel(settings: automatic()) == nil)
    }


    @Test("Manual full-scope sign-out cancels an automatic browser and prevents its late credentials")
    func manualSignOutCancelsAutomaticLogin() async throws {
        let token = try credentials(settings()), gate = Gate(), keychain = KeychainService.inMemory()
        let cancelled = SessionLifecycleTests.Counter()
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in
            await withTaskCancellationHandler { await gate.wait(); return token }
            onCancel: { cancelled.bump() }
        }, validate: { value, _ in value }, discover: { _ in token.application })
        let attempt = Task { try await auth.authorize(settings: automatic()) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: settings())
        await gate.release()
        do { _ = try await attempt.value; Issue.record("manual logout must retire the automatic login") } catch {}
        #expect(cancelled.count == 1)
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: automatic()) }
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: settings()) }
    }

    @Test("Manual sign-out while discovery is pending is checked against the eventual exact scope")
    func manualSignOutDuringAutomaticDiscovery() async throws {
        let token = try credentials(settings()), gate = Gate(), browser = Counter()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in await browser.increment(); return token },
            validate: { value, _ in value }, discover: { _ in await gate.wait(); return token.application })
        let attempt = Task { try await auth.authorize(settings: automatic()) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: settings())
        await gate.release()
        do { _ = try await attempt.value; Issue.record("late discovery cannot override logout") } catch {}
        #expect(await browser.count == 0)
        #expect(await auth.accountLabel(settings: automatic()) == nil)
    }

    @Test("A different host's manual logout does not cancel automatic login")
    func unrelatedManualSignOutDoesNotCancelAutomaticLogin() async throws {
        let token = try credentials(settings()), gate = Gate()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in await gate.wait(); return token },
            validate: { value, _ in value }, discover: { _ in token.application })
        let attempt = Task { try await auth.authorize(settings: automatic()) }
        while !(await gate.entered) { await Task.yield() }
        try await auth.signOut(settings: settings(host: "other.example.com"))
        await gate.release()
        #expect(try await attempt.value == "user-one@example.invalid")
        #expect(try await auth.credentials(settings: automatic()).application == token.application)
    }


    @Test("Manual logout during automatic rollback cannot restore previous in-memory credentials")
    func signOutDuringAutomaticRollbackDoesNotRestoreMemory() async throws {
        let old = try credentials(settings()), newer = try credentials(settings(), subject: "user-two")
        let backend = RecordingBackend(), calls = Counter(), keychain = KeychainService(backend: backend)
        let auth = CloudflareAccessAuth(keychain: keychain, login: { _ in
            await calls.increment()
            return await calls.count == 1 ? old : newer
        }, validate: { value, _ in value }, discover: { _ in old.application })
        _ = try await auth.authorize(settings: automatic())
        #expect(try await auth.credentials(settings: automatic()).identity.subject == "user-one")
        backend.failNextBindingWrite(pauseRollbackRead: true)
        let refresh = Task { try await auth.authorize(settings: automatic()) }
        while !backend.rollbackReadEntered { await Task.yield() }
        let started = Counter()
        let logout = Task { await started.increment(); try await auth.signOut(settings: settings()) }
        while await started.count == 0 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        backend.release()
        do { _ = try await refresh.value; Issue.record("failed binding must not succeed") } catch {}
        try await logout.value
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: settings()) }
        await #expect(throws: CloudflareAuthError.loginRequired) { try await auth.credentials(settings: automatic()) }
    }

}
