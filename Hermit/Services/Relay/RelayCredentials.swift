import Foundation
import RemoteForgeRelay

/// Plaintext loopback is restricted to opt-in DEBUG simulator verification.
/// There is no production setting that disables TLS verification.
enum RelayRuntimePolicy {
    static var allowsInsecureLoopback: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["MOSHPIT_RELAY_LOOPBACK_TESTS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-MOSHPIT_RELAY_LOOPBACK_TESTS")
        #else
        return false
        #endif
    }
}

enum RelayCredentialError: Error, Equatable, LocalizedError, Sendable {
    case invalidReference, missing, invalidOrExpired, scopeMismatch, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .missing: return "这台设备尚未保存 Relay 凭据，请编辑主机并重新配对。"
        case .invalidReference, .invalidOrExpired: return "Relay 凭据已过期或不可用，请重新配对。"
        case .scopeMismatch: return "Relay 凭据与当前设备或服务不一致，请重新配对。"
        case .storageUnavailable: return "无法访问 Relay 凭据，请解锁设备后重试。"
        }
    }
}

/// Each device pairs independently. Access grants never use the simulator
/// file vault or the portable SSH/iCloud credential namespace.
actor RelayCredentials {
    static let shared = RelayCredentials()
    private static let prefix = "hermit.relay."
    private let keychain: KeychainService

    init(keychain: KeychainService = KeychainService(backend: SystemKeychainBackend(
        service: (Bundle.main.bundleIdentifier ?? "com.cluas.moshpit") + ".relay.credentials"))) {
        self.keychain = keychain
    }
    nonisolated static func newReference() -> String { prefix + UUID().uuidString.lowercased() }
    nonisolated static func isReference(_ value: String) -> Bool {
        value.hasPrefix(prefix) && UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }
    func save(_ credential: RelayCredential) async throws -> String {
        guard credential.expiresAt > Date() else { throw RelayCredentialError.invalidOrExpired }
        let ref = Self.newReference()
        do {
            try await keychain.saveSecret(credential.serialized(), forRef: ref, requireBiometry: false)
            return ref
        } catch {
            try? await keychain.delete(forRef: ref)
            throw RelayCredentialError.storageUnavailable
        }
    }
    func load(settings: RelayConnectionSettings) async throws -> RelayCredential {
        guard Self.isReference(settings.credentialRef) else { throw RelayCredentialError.invalidReference }
        let data: Data
        do { data = try await keychain.loadSecret(forRef: settings.credentialRef, reason: "读取 Relay 凭据") }
        catch KeychainError.notFound { throw RelayCredentialError.missing }
        catch { throw RelayCredentialError.storageUnavailable }
        guard let credential = try? RelayCredential(serialized: data,
                    allowInsecureLoopback: RelayRuntimePolicy.allowsInsecureLoopback) else {
            throw RelayCredentialError.invalidOrExpired
        }
        guard settings.matches(credential) else { throw RelayCredentialError.scopeMismatch }
        return credential
    }
    func delete(ref: String) async throws {
        guard Self.isReference(ref) else { throw RelayCredentialError.invalidReference }
        do { try await keychain.delete(forRef: ref) }
        catch { throw RelayCredentialError.storageUnavailable }
    }
}
