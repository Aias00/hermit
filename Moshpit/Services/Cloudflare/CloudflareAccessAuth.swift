import AuthenticationServices
import CloudflareAccess
import CryptoKit
import Foundation
import UIKit
#if DEBUG && targetEnvironment(simulator)
import Darwin
#endif

enum CloudflareAuthError: Error, LocalizedError, Equatable {
    case loginRequired, cancelled, presentationUnavailable, credentialStorage

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "Cloudflare 需要登录。请登录此连接的 Access 应用后重试。"
        case .cancelled: return "已取消 Cloudflare 登录。"
        case .presentationUnavailable: return "请回到 Moshpit 前台后登录 Cloudflare。"
        case .credentialStorage: return "无法安全保存 Cloudflare 登录状态，请解锁设备后重试。"
        }
    }
}

/// The SSH dialer only reads credentials. Browser presentation is an explicit
/// UI operation, so a reconnect or a Herdr sidecar cannot open a login loop.
actor CloudflareAccessAuth {
    static let shared = CloudflareAccessAuth()
    typealias Login = @Sendable (AccessApplication) async throws -> AccessCredentials
    typealias Validator = @Sendable (AccessCredentials, AccessApplication) async throws -> AccessCredentials
    typealias Discovery = @Sendable (String) async throws -> AccessApplication
    private struct Binding: Codable {
        let application: AccessApplication
        let attempt: UUID
    }
    private struct AutomaticCommit {
        let bindingKey: String
        let scope: String
        let id: UUID
        let ref: String
        let previousBinding: Data?
        let previousAccount: Data?
        let previousGeneration: UUID?
        let previousMemory: AccessCredentials?
        let previouslyBlocked: Bool
        let bindingPreviouslyBlocked: Bool
    }
    private struct LoginAttempt {
        let id: UUID
        let task: Task<AccessCredentials, Error>
    }
    private struct StorageMutation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let keychain: KeychainService
    private let login: Login
    private let validate: Validator
    private let discover: Discovery
    private var bindings: [String: AccessApplication] = [:]
    private var automaticCommits: [UUID: AutomaticCommit] = [:]
    private var automaticApplications: [String: (id: UUID, application: AccessApplication)] = [:]
    private var memory: [String: AccessCredentials] = [:]
    private var logins: [String: LoginAttempt] = [:]
    private var generations: [String: UUID] = [:]
    private var storageMutations: [String: StorageMutation] = [:]
    private var blockedScopes: Set<String> = []

    init(keychain: KeychainService = KeychainService(backend: SystemKeychainBackend(
             service: "com.cluas.moshpit.cloudflare-access")),
         login: @escaping Login = { application in
             try await CloudflareLoginBrowser.shared.authenticate(application)
         },
         validate: @escaping Validator = { credentials, application in
             try await AccessJWTValidator.validateCredentials(credentials, for: application)
         },
         discover: @escaping Discovery = { hostname in
             try await AccessApplicationDiscovery.discover(hostname: hostname)
         }) {
        self.keychain = keychain
        self.login = login
        self.validate = validate
        self.discover = discover
    }

    static func application(_ settings: CloudflareConnectionSettings) throws -> AccessApplication {
        try AccessApplication(hostname: settings.hostname, audience: settings.audience,
                              teamDomain: settings.teamDomain)
    }

    private static func scope(_ application: AccessApplication) -> String {
        let value = [application.teamDomain, application.hostname, application.audience].joined(separator: "\n")
        return "moshpit.cloudflare.v1." + digest(value)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func credentials(settings: CloudflareConnectionSettings) async throws -> AccessCredentials {
        guard settings.usesAutomaticDiscovery else {
            return try await credentials(application: Self.application(settings))
        }
        let key = Self.bindingKey(settings.hostname)
        try Task.checkCancellation()
        if let current = logins[key] {
            let credentials = try await current.task.value
            try Task.checkCancellation()
            guard generations[key] == current.id else { throw CloudflareAuthError.loginRequired }
            return credentials
        }
        guard !blockedScopes.contains(key) else { throw CloudflareAuthError.loginRequired }
        let generation = generations[key]
        let application = try await boundApplication(hostname: settings.hostname)
        let credentials = try await credentials(application: application)
        try Task.checkCancellation()
        guard generations[key] == generation, !blockedScopes.contains(key) else { throw CloudflareAuthError.loginRequired }
        return credentials
    }

    private func credentials(application: AccessApplication) async throws -> AccessCredentials {
        let scope = Self.scope(application)
        try Task.checkCancellation()
        if let current = logins[scope] {
            let credentials = try await current.task.value
            try Task.checkCancellation()
            guard generations[scope] == current.id else { throw CloudflareAuthError.loginRequired }
            return credentials
        }
        guard !blockedScopes.contains(scope) else { throw CloudflareAuthError.loginRequired }
        let generation = generations[scope]
        if let mutation = storageMutations[scope] { try await mutation.task.value }
        guard generation == generations[scope], !blockedScopes.contains(scope) else { throw CloudflareAuthError.loginRequired }
        if let cached = memory[scope], cached.identity.expiresAt > Date().addingTimeInterval(30) {
            return cached
        }
        memory[scope] = nil
        let stored: AccessCredentials
        do {
            let ref = try await keychain.loadPassword(forRef: scope + ".account", reason: "读取 Cloudflare 登录状态")
            guard ref.hasPrefix(scope + ".user.") else { throw CloudflareAuthError.loginRequired }
            let data = try await keychain.loadSecret(forRef: ref, reason: "读取 Cloudflare 登录凭据")
            stored = try JSONDecoder().decode(AccessCredentials.self, from: data)
            let account = scope + ".user." + Self.digest(stored.identity.subject)
            guard ref == account || (ref.hasPrefix(account + ".attempt.") && UUID(uuidString: String(ref.dropFirst((account + ".attempt.").count))) != nil),
                  stored.application == application,
                  stored.identity.expiresAt > Date().addingTimeInterval(30) else {
                throw CloudflareAuthError.loginRequired
            }
        } catch is KeychainError {
            throw CloudflareAuthError.loginRequired
        } catch is DecodingError {
            throw CloudflareAuthError.loginRequired
        }
        // Keychain metadata is not a JWT signature check. Revalidate after an
        // app restart; concurrent channels reuse only the resulting live cache.
        let checked = try await validate(stored, application)
        try Task.checkCancellation()
        guard generation == generations[scope], !blockedScopes.contains(scope),
              checked.application == application, checked.identity.subject == stored.identity.subject,
              checked.identity.expiresAt > Date().addingTimeInterval(30) else { throw CloudflareAuthError.loginRequired }
        memory[scope] = checked
        return checked
    }

    @discardableResult
    func authorize(settings: CloudflareConnectionSettings) async throws -> String {
        if settings.usesAutomaticDiscovery { return try await authorizeAutomatically(hostname: settings.hostname) }
        let application = try Self.application(settings)
        let scope = Self.scope(application)
        if let current = logins[scope] {
            let credentials = try await current.task.value
            try Task.checkCancellation()
            guard generations[scope] == current.id else { throw CloudflareAuthError.cancelled }
            return credentials.identity.email ?? credentials.identity.subject
        }
        try Task.checkCancellation()
        let id = UUID()
        generations[scope] = id
        memory[scope] = nil
        let login = self.login
        let validate = self.validate
        let task = Task {
            let credentials = try await login(application)
            try Task.checkCancellation()
            let checked = try await validate(credentials, application)
            try Task.checkCancellation()
            // Every caller, including joiners, waits for the same durable
            // result. No caller can return before the account index exists.
            try await self.mutateStorage(scope: scope) {
                try await self.persist(checked, application: application, scope: scope, generation: id)
            }
            return checked
        }
        logins[scope] = LoginAttempt(id: id, task: task)
        defer { if logins[scope]?.id == id { logins[scope] = nil } }
        return try await withTaskCancellationHandler {
            do {
                let credentials = try await task.value
                try Task.checkCancellation()
                guard generations[scope] == id else { throw CloudflareAuthError.cancelled }
                return credentials.identity.email ?? credentials.identity.subject
            } catch {
                if Task.isCancelled {
                    await cancelOwnedLogin(scope: scope, id: id)
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            // Task.value does not propagate cancellation to an unstructured
            // child. Only this attempt's owner may cancel the shared browser;
            // a joining caller above owns only its own wait.
            task.cancel()
            Task { await self.cancelOwnedLogin(scope: scope, id: id) }
        }
    }

    private func cancelOwnedLogin(scope: String, id: UUID) async {
        guard generations[scope] == id else { return }
        generations[scope] = UUID()
        if logins[scope]?.id == id { logins[scope]?.task.cancel(); logins[scope] = nil }
        memory[scope] = nil
        blockedScopes.insert(scope)
        // A late Keychain write must be retired too. The storage queue orders
        // this cleanup before a subsequent explicit login for this scope.
        try? await mutateStorage(scope: scope) { try await self.deleteStoredScope(scope) }
    }

    /// The queue only covers storage mutations, never browser/network waits.
    /// Sign-out can cancel a login immediately and then retire any in-flight
    /// write before a later login publishes a different account.
    private func mutateStorage(scope: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = storageMutations[scope]?.task
        let id = UUID()
        let task = Task {
            _ = await previous?.result
            try await operation()
        }
        storageMutations[scope] = StorageMutation(id: id, task: task)
        defer { if storageMutations[scope]?.id == id { storageMutations[scope] = nil } }
        try await task.value
    }

    private func persist(_ credentials: AccessCredentials, application: AccessApplication,
                         scope: String, generation: UUID) async throws {
        guard generations[scope] == generation else { throw CloudflareAuthError.cancelled }
        guard credentials.application == application, !credentials.identity.subject.isEmpty,
              credentials.identity.expiresAt > Date().addingTimeInterval(30) else { throw CloudflareAuthError.loginRequired }
        // A cancelled attempt owns only its unique record. Its cleanup can
        // never delete a later login for the same account.
        let ref = scope + ".user." + Self.digest(credentials.identity.subject) + ".attempt." + generation.uuidString
        let previous = try? await keychain.loadPassword(forRef: scope + ".account")
        do {
            guard generations[scope] == generation else { throw CloudflareAuthError.cancelled }
            try await keychain.saveSecret(JSONEncoder().encode(credentials), forRef: ref, requireBiometry: false)
            guard generations[scope] == generation else { throw CloudflareAuthError.cancelled }
            try await keychain.savePassword(ref, forRef: scope + ".account", requireBiometry: false)
            guard generations[scope] == generation else { throw CloudflareAuthError.cancelled }
        } catch {
            // The serialized mutation owns the index until this operation
            // exits, so remove it only if this attempt published it.
            if (try? await keychain.loadPassword(forRef: scope + ".account")) == ref {
                try? await keychain.delete(forRef: scope + ".account")
            }
            try? await keychain.delete(forRef: ref)
            if let error = error as? CloudflareAuthError { throw error }
            throw CloudflareAuthError.credentialStorage
        }
        if let previous, previous != ref, previous.hasPrefix(scope + ".user.") {
            try? await keychain.delete(forRef: previous)
        }
        guard generations[scope] == generation else {
            try? await keychain.delete(forRef: scope + ".account")
            try? await keychain.delete(forRef: ref)
            throw CloudflareAuthError.cancelled
        }
        blockedScopes.remove(scope)
        memory[scope] = credentials
    }

    func accountLabel(settings: CloudflareConnectionSettings) async -> String? {
        guard let credentials = try? await credentials(settings: settings) else { return nil }
        return credentials.identity.email ?? credentials.identity.subject
    }

    func signOut(settings: CloudflareConnectionSettings) async throws {
        if settings.usesAutomaticDiscovery {
            try await signOutAutomatically(hostname: settings.hostname)
            return
        }
        try await signOut(application: Self.application(settings))
    }

    private func signOut(application: AccessApplication) async throws {
        let scope = Self.scope(application)
        // A discovered application is the same full scope in either mode.
        // Cancel its automatic browser too; unrelated hosts/teams stay live.
        for (key, attempt) in automaticApplications where attempt.application == application {
            guard generations[key] == attempt.id else { continue }
            generations[key] = UUID()
            logins[key]?.task.cancel()
            logins[key] = nil
        }
        generations[scope] = UUID()
        logins[scope]?.task.cancel()
        logins[scope] = nil
        memory[scope] = nil
        blockedScopes.insert(scope)
        do {
            try await mutateStorage(scope: scope) {
                try await self.deleteStoredScope(scope)
            }
        } catch { throw CloudflareAuthError.credentialStorage }
    }

    private static func bindingKey(_ hostname: String) -> String {
        "moshpit.cloudflare.binding.v1." + digest(hostname.lowercased())
    }

    /// This lookup never performs discovery or starts a browser. The binding
    /// exists only after a matching user JWT was verified and durably saved.
    private func boundApplication(hostname: String) async throws -> AccessApplication {
        let key = Self.bindingKey(hostname)
        guard !blockedScopes.contains(key) else { throw CloudflareAuthError.loginRequired }
        let generation = generations[key]
        if let mutation = storageMutations[key] { try await mutation.task.value }
        guard generation == generations[key], !blockedScopes.contains(key) else { throw CloudflareAuthError.loginRequired }
        if let application = bindings[key] { return application }
        do {
            let data = try await keychain.loadSecret(forRef: key, reason: "读取 Cloudflare 应用绑定")
            let binding = try JSONDecoder().decode(Binding.self, from: data)
            guard binding.application.hostname == hostname.lowercased(), generation == generations[key],
                  !blockedScopes.contains(key) else { throw CloudflareAuthError.loginRequired }
            bindings[key] = binding.application
            return binding.application
        } catch is KeychainError { throw CloudflareAuthError.loginRequired }
        catch is DecodingError { throw CloudflareAuthError.loginRequired }
    }

    private func authorizeAutomatically(hostname: String) async throws -> String {
        let hostname = hostname.lowercased()
        let key = Self.bindingKey(hostname)
        if let current = logins[key] {
            let credentials = try await current.task.value
            try Task.checkCancellation()
            guard generations[key] == current.id else { throw CloudflareAuthError.cancelled }
            return credentials.identity.email ?? credentials.identity.subject
        }
        try Task.checkCancellation()
        let id = UUID()
        // Discovery has not told us the full scope yet. Remember all existing
        // generations so a sign-out while discovery waits cannot be overwritten.
        let scopeGenerations = generations
        generations[key] = id
        let task = Task {
            let application = try await discover(hostname)
            try Task.checkCancellation()
            guard application.hostname == hostname else { throw AccessError.invalidMetadata }
            let scope = Self.scope(application)
            guard generations[scope] == scopeGenerations[scope], generations[key] == id else {
                throw CloudflareAuthError.cancelled
            }
            automaticApplications[key] = (id, application)
            defer { if automaticApplications[key]?.id == id { automaticApplications[key] = nil } }
            let credentials = try await login(application)
            try Task.checkCancellation()
            let checked = try await validate(credentials, application)
            try Task.checkCancellation()
            guard checked.application == application, !checked.identity.subject.isEmpty,
                  checked.identity.expiresAt > Date().addingTimeInterval(30) else { throw CloudflareAuthError.loginRequired }
            try await mutateStorage(scope: key) {
                try await self.mutateStorage(scope: scope) {
                    try await self.persistAutomatic(checked, key: key, scope: scope, id: id,
                                                    expectedScopeGeneration: scopeGenerations[scope])
                }
            }
            return checked
        }
        logins[key] = LoginAttempt(id: id, task: task)
        defer {
            if logins[key]?.id == id { logins[key] = nil }
            automaticCommits[id] = nil
        }
        return try await withTaskCancellationHandler {
            do {
                let credentials = try await task.value
                try Task.checkCancellation()
                guard generations[key] == id else { throw CloudflareAuthError.cancelled }
                // No suspension between committing the caller's result and
                // retiring its rollback record. Cancellation before this point
                // restores the previous binding/account instead.
                if let commit = automaticCommits.removeValue(forKey: id),
                   let data = commit.previousAccount, let previous = String(data: data, encoding: .utf8),
                   previous != commit.ref, previous.hasPrefix(commit.scope + ".user.") {
                    Task { try? await keychain.delete(forRef: previous) }
                }
                return credentials.identity.email ?? credentials.identity.subject
            } catch {
                if Task.isCancelled {
                    await cancelAutomaticLogin(key: key, id: id)
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            task.cancel()
            Task { await self.cancelAutomaticLogin(key: key, id: id) }
        }
    }

    private func loadOptionalSecret(_ ref: String) async throws -> Data? {
        do { return try await keychain.loadSecret(forRef: ref) }
        catch KeychainError.notFound { return nil }
    }

    /// Both queues are held in hostname -> full-scope order. Neither discovery
    /// nor browser waits hold them, so sign-out can invalidate an attempt now.
    private func persistAutomatic(_ credentials: AccessCredentials, key: String, scope: String, id: UUID,
                                  expectedScopeGeneration: UUID?) async throws {
        guard generations[key] == id, generations[scope] == expectedScopeGeneration,
              !Task.isCancelled else { throw CloudflareAuthError.cancelled }
        let ref = scope + ".user." + Self.digest(credentials.identity.subject) + ".attempt." + id.uuidString
        let previousBinding = try await loadOptionalSecret(key)
        let previousAccount = try await loadOptionalSecret(scope + ".account")
        guard generations[key] == id, generations[scope] == expectedScopeGeneration,
              !Task.isCancelled else { throw CloudflareAuthError.cancelled }
        let commit = AutomaticCommit(bindingKey: key, scope: scope, id: id, ref: ref,
            previousBinding: previousBinding, previousAccount: previousAccount,
            previousGeneration: generations[scope], previousMemory: memory[scope],
            previouslyBlocked: blockedScopes.contains(scope),
            bindingPreviouslyBlocked: blockedScopes.contains(key))
        generations[scope] = id
        do {
            try await keychain.saveSecret(JSONEncoder().encode(credentials), forRef: ref, requireBiometry: false)
            try checkAutomaticAttempt(key: key, scope: scope, id: id)
            try await keychain.savePassword(ref, forRef: scope + ".account", requireBiometry: false)
            try checkAutomaticAttempt(key: key, scope: scope, id: id)
            let binding = Binding(application: credentials.application, attempt: id)
            try await keychain.saveSecret(JSONEncoder().encode(binding), forRef: key, requireBiometry: false)
            try checkAutomaticAttempt(key: key, scope: scope, id: id)
            bindings[key] = credentials.application
            memory[scope] = credentials
            blockedScopes.remove(key)
            blockedScopes.remove(scope)
            automaticCommits[id] = commit
        } catch {
            do { try await rollbackAutomatic(commit) }
            catch { blockedScopes.insert(key) }
            if let error = error as? CloudflareAuthError { throw error }
            if error is CancellationError { throw CancellationError() }
            throw CloudflareAuthError.credentialStorage
        }
    }

    private func checkAutomaticAttempt(key: String, scope: String, id: UUID) throws {
        try Task.checkCancellation()
        guard generations[key] == id, generations[scope] == id else { throw CloudflareAuthError.cancelled }
    }

    private func restoreSecret(_ data: Data?, ref: String) async throws {
        if let data { try await keychain.saveSecret(data, forRef: ref, requireBiometry: false) }
        else { try await keychain.delete(forRef: ref) }
    }

    private func rollbackAutomatic(_ commit: AutomaticCommit) async throws {
        // Preserve a later explicit operation. These queues still own all
        // writes belonging to this attempt, including failed replace writes.
        let currentBinding = try await loadOptionalSecret(commit.bindingKey)
        let bindingAttempt = currentBinding.flatMap { try? JSONDecoder().decode(Binding.self, from: $0).attempt }
        if currentBinding == nil || bindingAttempt == commit.id {
            try await restoreSecret(commit.previousBinding, ref: commit.bindingKey)
            if commit.bindingPreviouslyBlocked { blockedScopes.insert(commit.bindingKey) }
            bindings[commit.bindingKey] = commit.previousBinding.flatMap {
                try? JSONDecoder().decode(Binding.self, from: $0).application
            }
        }
        if generations[commit.scope] == commit.id {
            let current = try await loadOptionalSecret(commit.scope + ".account")
            if generations[commit.scope] == commit.id,
               current == nil || current.flatMap({ String(data: $0, encoding: .utf8) }) == commit.ref {
                try await restoreSecret(commit.previousAccount, ref: commit.scope + ".account")
            }
            // Sign-out changes the epoch before waiting for this storage
            // queue. Never restore its old memory/block state after an await.
            if generations[commit.scope] == commit.id {
                generations[commit.scope] = commit.previousGeneration
                memory[commit.scope] = commit.previousMemory
                if commit.previouslyBlocked { blockedScopes.insert(commit.scope) }
                else { blockedScopes.remove(commit.scope) }
            }
        }
        if generations[commit.scope] != commit.previousGeneration,
           (try? await keychain.loadPassword(forRef: commit.scope + ".account")) == commit.ref {
            try await keychain.delete(forRef: commit.scope + ".account")
        }
        try await keychain.delete(forRef: commit.ref)
    }

    private func cancelAutomaticLogin(key: String, id: UUID) async {
        guard generations[key] == id else { return }
        generations[key] = UUID()
        if logins[key]?.id == id { logins[key]?.task.cancel(); logins[key] = nil }
        // Take ownership before suspending: the cancelled owner may return
        // and remove its bookkeeping while this cleanup waits in the queue.
        let commit = automaticCommits.removeValue(forKey: id)
        // Failed/cancelled discovery does not erase an earlier verified binding.
        // A prior sign-out's block is also kept until a successful explicit login.
        try? await mutateStorage(scope: key) {
            guard let commit else { return }
            try await self.mutateStorage(scope: commit.scope) { try await self.rollbackAutomatic(commit) }
        }
    }

    private func signOutAutomatically(hostname: String) async throws {
        let key = Self.bindingKey(hostname)
        generations[key] = UUID()
        logins[key]?.task.cancel()
        logins[key] = nil
        blockedScopes.insert(key)
        bindings[key] = nil
        do {
            try await mutateStorage(scope: key) {
                if let data = try await self.loadOptionalSecret(key),
                   let binding = try? JSONDecoder().decode(Binding.self, from: data),
                   binding.application.hostname == hostname.lowercased() {
                    try await self.signOut(application: binding.application)
                }
                try await self.keychain.delete(forRef: key)
            }
        } catch { throw CloudflareAuthError.credentialStorage }
    }

    private func deleteStoredScope(_ scope: String) async throws {
        var failure: Error?
        if let ref = try? await keychain.loadPassword(forRef: scope + ".account"), ref.hasPrefix(scope + ".user.") {
            do { try await keychain.delete(forRef: ref) } catch { failure = error }
        }
        try await keychain.delete(forRef: scope + ".account")
        if let failure { throw failure }
    }

    /// A revoked token can still have a valid signature and expiry. The edge's
    /// 401/403 is authoritative; never reuse that token on the next reconnect.
    func invalidate(settings: CloudflareConnectionSettings) async {
        try? await signOut(settings: settings)
    }
}

/// Cloudflare's CLI login has no app callback. Its encrypted transfer is the
/// completion signal; cancelling our browser after transfer success must not
/// be mistaken for the user cancelling the login.
@MainActor
private final class CloudflareLoginBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = CloudflareLoginBrowser()
    private var session: ASWebAuthenticationSession?
    private var operation: Task<Void, Never>?
    private var continuation: CheckedContinuation<AccessCredentials, Error>?
    private var attempt: UUID?
    private var anchor: UIWindow?
#if DEBUG && targetEnvironment(simulator)
    private var simulatorLoginLink: CloudflareSimulatorLoginLink?
#endif

    func authenticate(_ application: AccessApplication) async throws -> AccessCredentials {
        try Task.checkCancellation()
        guard session == nil, UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw CloudflareAuthError.presentationUnavailable
        }
        let transfer = try AccessLoginTransfer(application: application)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.attempt = id
                self.anchor = window
                let browser = ASWebAuthenticationSession(url: transfer.browserURL, callbackURLScheme: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.finish(.failure(CloudflareAuthError.cancelled), id: id) }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                self.session = browser
                guard browser.start() else {
                    finish(.failure(CloudflareAuthError.presentationUnavailable), id: id)
                    return
                }
#if DEBUG && targetEnvironment(simulator)
                // Explicit, attended simulator verification only. The App still
                // owns the ephemeral private key, real browser and transfer poll.
                // No credentials can enter through this one-way public-link file.
                if let directory = ProcessInfo.processInfo.environment["MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR"] {
                    do {
                        self.simulatorLoginLink = try CloudflareSimulatorLoginLink.publish(
                            browserURL: transfer.browserURL, directoryPath: directory, attempt: id)
                    } catch {
                        finish(.failure(error), id: id)
                        return
                    }
                }
#endif
                self.operation = Task { @MainActor [weak self] in
                    do { self?.finish(.success(try await transfer.poll()), id: id) }
                    catch { self?.finish(.failure(error), id: id) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CloudflareAuthError.cancelled), id: id) }
        }
    }

    private func finish(_ result: Result<AccessCredentials, Error>, id: UUID) {
        guard attempt == id else { return }
        attempt = nil
        let pending = continuation
        continuation = nil
        operation?.cancel()
        operation = nil
        session?.cancel()
        session = nil
        anchor = nil
#if DEBUG && targetEnvironment(simulator)
        simulatorLoginLink?.remove()
        simulatorLoginLink = nil
#endif
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

#if DEBUG && targetEnvironment(simulator)
/// An explicit local test outlet for the short-lived public-key login link.
/// Never compiled into device or Release builds. It does not read browser data,
/// export a token, or bypass the App's transfer validation and Keychain writes.
final class CloudflareSimulatorLoginLink {
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "Unable to prepare the simulator login handoff." }
    }

    private var directoryDescriptor: Int32
    private let filename: String

    private init(directoryDescriptor: Int32, filename: String) {
        self.directoryDescriptor = directoryDescriptor
        self.filename = filename
    }

    static func publish(browserURL: URL, directoryPath: String, attempt: UUID) throws -> CloudflareSimulatorLoginLink {
        guard directoryPath.hasPrefix("/"), !directoryPath.contains("\0"),
              let components = URLComponents(url: browserURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/cdn-cgi/access/cli" else { throw Failure.unavailable }

        // Open a directory descriptor to pin cleanup to the same directory even
        // if the pathname changes. Never follow a symlink for the final directory.
        let path = URL(fileURLWithPath: directoryPath).standardizedFileURL.path
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        var retained = false
        defer { if !retained { close(directory) } }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0, attributes.st_uid == getuid(),
              (attributes.st_mode & 0o7777) == 0o700 else { throw Failure.unavailable }

        let filename = "login-\(attempt.uuidString).html"
        let pendingName = ".\(attempt.uuidString).pending"
        let descriptor = openat(directory, pendingName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor); unlinkat(directory, pendingName, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.unavailable }
        let escapedURL = browserURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'">
        <title>Temporary Moshpit simulator login</title>
        <p>This one-time link completes the simulator's pending Access login.</p>
        <a href="\(escapedURL)" rel="noreferrer">Continue Access login</a></html>
        """
        let data = Data(html.utf8)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                written += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, pendingName, directory, filename) == 0 else {
            throw Failure.unavailable
        }
        retained = true
        return CloudflareSimulatorLoginLink(directoryDescriptor: directory, filename: filename)
    }

    func remove() {
        guard directoryDescriptor >= 0 else { return }
        unlinkat(directoryDescriptor, filename, 0)
        close(directoryDescriptor)
        directoryDescriptor = -1
    }

    deinit { remove() }
}
#endif
