import Foundation
import Security

/// The one private account record never enters connection export or UserDefaults.
/// Native state on disk is encrypted with this device-only Keychain key.
struct TailscaleAccountRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var id: String
    let stateID: String
    let encryptionKey: Data
    var identity: String?
    var description: String { "TailscaleAccountRecord(<redacted>)" }
    var debugDescription: String { description }

    func validated() throws -> Self {
        guard UUID(uuidString: id) != nil, UUID(uuidString: stateID) != nil,
              encryptionKey.count == 32, identity.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else {
            throw TailscaleAccountError.invalidStoredState
        }
        return self
    }
}

/// Atomic replacement matters: SystemKeychainBackend's generic delete/add
/// semantics could lose a still-valid encryption key if a replacement fails.
final class TailscaleKeychainBackend: KeychainBackend {
    private let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "com.cluas.moshpit") + ".tailscale.account") {
        self.service = service
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
    func save(secret: Data, account: String, requireBiometry: Bool) throws {
        let q = query(account)
        let update = [kSecValueData as String: secret,
                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        var result = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(q.merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw KeychainError(osStatus: result) }
    }
    func load(account: String, prompt: String) throws -> Data {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(osStatus: status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }
    func delete(account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw KeychainError(osStatus: result) }
    }
    func exists(account: String) -> Bool {
        let status = SecItemCopyMatching(query(account) as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

/// Access is serialized by TailscaleRuntime. No cache can silently bypass a
/// locked Keychain or restore a key that was explicitly removed.
final class TailscaleAccountVault: @unchecked Sendable {
    private let backend: any KeychainBackend
    let root: URL
    private let reference = "moshpit.tailscale.account.v1"

    init(backend: any KeychainBackend = TailscaleKeychainBackend(), root: URL? = nil) {
        self.backend = backend
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tailscale", isDirectory: true)
    }

    func load() throws -> TailscaleAccountRecord? {
        let data: Data
        do { data = try backend.load(account: reference, prompt: "Read Tailscale account") }
        catch KeychainError.notFound { return nil }
        catch { throw TailscaleAccountError.storageUnavailable }
        do { return try PropertyListDecoder().decode(TailscaleAccountRecord.self, from: data).validated() }
        catch { throw TailscaleAccountError.invalidStoredState }
    }

    func create() throws -> TailscaleAccountRecord {
        if let existing = try load() { return existing }
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw TailscaleAccountError.storageUnavailable }
        let record = TailscaleAccountRecord(id: UUID().uuidString.lowercased(),
                                           stateID: UUID().uuidString.lowercased(), encryptionKey: key)
        try save(record)
        return record
    }

    func save(_ record: TailscaleAccountRecord) throws {
        _ = try record.validated()
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try backend.save(secret: encoder.encode(record), account: reference, requireBiometry: false)
        } catch { throw TailscaleAccountError.storageUnavailable }
    }

    func directory(for record: TailscaleAccountRecord) throws -> URL {
        _ = try record.validated()
        var directory = root.appendingPathComponent(record.stateID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700,
                                                                 .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            return directory
        } catch { throw TailscaleAccountError.storageUnavailable }
    }

    func delete() throws {
        // Corrupt metadata must still be removable. Keychain deletion itself
        // remains authoritative and propagates lock/access failures.
        let previous = try? load()
        do { try backend.delete(account: reference) }
        catch { throw TailscaleAccountError.storageUnavailable }
        // Deleting the only decryption key is authoritative. A failed removal
        // leaves only ciphertext and must not resurrect a signed-out account.
        if let previous {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(previous.stateID, isDirectory: true))
        }
    }
}
