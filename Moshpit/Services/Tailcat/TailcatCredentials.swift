import Foundation
import TailcatSSH

enum TailcatCredentialError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress
    case missingPresharedKey
    case invalidClientIdentity
    case invalidReference
    case missingCredential
    case invalidStoredCredential
    case storageUnavailable
    case connectionRemoved

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return String(localized: "Paste a valid tc address from your Tailcat server.")
        case .missingPresharedKey:
            return String(localized: "This Tailcat address has no pre-shared key. Generate a new address with Tailcat's default PSK setting.")
        case .invalidClientIdentity:
            return String(localized: "The saved Tailcat client identity is invalid. Restore its credentials before connecting.")
        case .invalidReference, .invalidStoredCredential:
            return String(localized: "The saved Tailcat credentials are invalid. Edit the connection to restore them.")
        case .missingCredential:
            return String(localized: "Tailcat credentials are missing from this device. Edit the connection and paste its address again.")
        case .storageUnavailable:
            return String(localized: "Secure connection storage is unavailable. Unlock this device and try again.")
        case .connectionRemoved:
            return String(localized: "This connection was removed while saving. Close the editor and add it again.")
        }
    }
}

/// Deliberately not Codable: neither connection exports nor diagnostic dumps
/// should accidentally serialize the capability address or client private key.
struct TailcatCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let address: String
    let clientPrivateKey: String
    let clientPublicKey: String
    let serverPublicKey: String

    var description: String { "TailcatCredential(<redacted>)" }
    var debugDescription: String { description }

    static func create(address: String, clientPrivateKey: String? = nil) throws -> Self {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata: TailcatAddressMetadata
        do { metadata = try TailcatIdentity.parseAddress(address) }
        catch { throw TailcatCredentialError.invalidAddress }
        guard metadata.hasPresharedKey else { throw TailcatCredentialError.missingPresharedKey }
        let privateKey: String
        let publicKey: String
        do {
            if let clientPrivateKey {
                privateKey = clientPrivateKey
                publicKey = try TailcatIdentity.publicKey(forPrivateKey: clientPrivateKey, address: address)
            } else {
                let generated = try TailcatIdentity.generateClientKey()
                privateKey = generated.privateKey
                publicKey = generated.publicKey
            }
        } catch { throw TailcatCredentialError.invalidClientIdentity }
        return Self(address: address, clientPrivateKey: privateKey, clientPublicKey: publicKey,
                    serverPublicKey: metadata.serverPublicKey)
    }

    func validated() throws -> Self {
        let checked = try Self.create(address: address, clientPrivateKey: clientPrivateKey)
        guard checked.serverPublicKey == serverPublicKey, checked.clientPublicKey == clientPublicKey else {
            throw TailcatCredentialError.invalidStoredCredential
        }
        return checked
    }
}

/// Uses the system Keychain on both real devices and signed simulators. The
/// ordinary SSH simulator file vault must never receive a Tailcat address.
actor TailcatCredentials {
    static let shared = TailcatCredentials()
    private let keychain: KeychainService
    private static let referencePrefix = "moshpit.tailcat."

    init(keychain: KeychainService = KeychainService(backend: SystemKeychainBackend(
        service: (Bundle.main.bundleIdentifier ?? "com.cluas.moshpit") + ".tailcat.credentials"))) {
        self.keychain = keychain
    }

    nonisolated static func newReference() -> String { referencePrefix + UUID().uuidString.lowercased() }

    nonisolated static func isReference(_ value: String) -> Bool {
        value.hasPrefix(referencePrefix)
            && UUID(uuidString: String(value.dropFirst(referencePrefix.count))) != nil
    }

    func load(ref: String) async throws -> TailcatCredential {
        guard Self.isReference(ref) else { throw TailcatCredentialError.invalidReference }
        let data: Data
        do { data = try await keychain.loadSecret(forRef: ref, reason: String(localized: "Read Tailcat credentials")) }
        catch KeychainError.notFound { throw TailcatCredentialError.missingCredential }
        catch { throw TailcatCredentialError.storageUnavailable }
        let stored: StoredCredential
        do { stored = try PropertyListDecoder().decode(StoredCredential.self, from: data) }
        catch { throw TailcatCredentialError.invalidStoredCredential }
        return try stored.credential.validated()
    }

    /// Write a fresh immutable item, then let the caller commit its new ref to
    /// the connection. A failed write cannot delete or alter the previous item,
    /// even though the general Keychain backend has overwrite semantics.
    func save(_ credential: TailcatCredential) async throws -> String {
        let credential = try credential.validated()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(StoredCredential(credential))
        let ref = Self.newReference()
        do { try await keychain.saveSecret(data, forRef: ref, requireBiometry: false) }
        catch {
            try? await keychain.delete(forRef: ref)
            throw TailcatCredentialError.storageUnavailable
        }
        return ref
    }

    func delete(ref: String) async throws {
        guard Self.isReference(ref) else { throw TailcatCredentialError.invalidReference }
        do { try await keychain.delete(forRef: ref) }
        catch { throw TailcatCredentialError.storageUnavailable }
    }

    /// Serialization is private to this Keychain store and is never used in
    /// UserDefaults, iCloud, connection export, or a simulator file vault.
    private struct StoredCredential: Codable {
        let address: String
        let clientPrivateKey: String
        let clientPublicKey: String
        let serverPublicKey: String

        init(_ value: TailcatCredential) {
            address = value.address
            clientPrivateKey = value.clientPrivateKey
            clientPublicKey = value.clientPublicKey
            serverPublicKey = value.serverPublicKey
        }

        var credential: TailcatCredential {
            TailcatCredential(address: address, clientPrivateKey: clientPrivateKey,
                              clientPublicKey: clientPublicKey, serverPublicKey: serverPublicKey)
        }
    }
}
