import Foundation
import Testing
@testable import Moshpit

@Suite("Tailscale device account storage")
struct TailscaleAccountVaultTests {
    @Test("Updating a failed account binding retains the original state key")
    func failedReplacementRetainsKey() throws {
        let backend = FaultKeychain()
        let vault = TailscaleAccountVault(backend: backend)
        let original = try vault.create()
        var update = original
        update.id = UUID().uuidString.lowercased()
        update.identity = "different-account"
        backend.failWrites = true
        #expect(throws: TailscaleAccountError.storageUnavailable) { try vault.save(update) }
        let after = try #require(try vault.load())
        #expect(after.id == original.id)
        #expect(after.encryptionKey == original.encryptionKey)
        #expect(after.identity == nil)
    }

    @Test("Locked storage never creates an unencrypted replacement account")
    func lockedStorageFailsClosed() throws {
        let backend = FaultKeychain()
        let vault = TailscaleAccountVault(backend: backend)
        _ = try vault.create()
        backend.failReads = true
        #expect(throws: TailscaleAccountError.storageUnavailable) { try vault.load() }
        #expect(throws: TailscaleAccountError.storageUnavailable) { try vault.create() }
    }

    @Test("Failed sign-out preserves the stored account so deletion can be retried")
    func deletionFailureRetainsAccount() throws {
        let backend = FaultKeychain()
        let vault = TailscaleAccountVault(backend: backend)
        let original = try vault.create()
        backend.failDeletes = true
        #expect(throws: TailscaleAccountError.storageUnavailable) { try vault.delete() }
        #expect(try vault.load()?.id == original.id)
    }

    @Test("Corrupt Keychain state can still be cleared through sign-out")
    func corruptedRecordCanBeRemoved() throws {
        let backend = FaultKeychain()
        let vault = TailscaleAccountVault(backend: backend)
        _ = try vault.create()
        backend.corrupt = true
        #expect(throws: TailscaleAccountError.invalidStoredState) { try vault.load() }
        try vault.delete()
        backend.corrupt = false
        #expect(try vault.load() == nil)
    }

    @Test("Actual signed simulator account metadata uses the device Keychain")
    func realKeychainRoundTrip() throws {
        let service = (Bundle.main.bundleIdentifier ?? "test") + ".tailscale-test." + UUID().uuidString
        let backend = TailscaleKeychainBackend(service: service)
        let vault = TailscaleAccountVault(backend: backend)
        defer { try? vault.delete() }
        let original = try vault.create()
        var update = original
        update.identity = "test-binding"
        try vault.save(update)
        let loaded = try #require(try vault.load())
        #expect(loaded.id == original.id)
        #expect(loaded.encryptionKey == original.encryptionKey)
        #expect(loaded.identity == "test-binding")
    }
}

private final class FaultKeychain: KeychainBackend {
    private let storage = InMemoryKeychainBackend()
    var failWrites = false
    var failReads = false
    var failDeletes = false
    var corrupt = false
    func save(secret: Data, account: String, requireBiometry: Bool) throws {
        if failWrites { throw KeychainError.unhandled(-50) }
        try storage.save(secret: secret, account: account, requireBiometry: requireBiometry)
    }
    func load(account: String, prompt: String) throws -> Data {
        if failReads { throw KeychainError.unhandled(-50) }
        if corrupt { return Data("corrupt-record".utf8) }
        return try storage.load(account: account, prompt: prompt)
    }
    func delete(account: String) throws {
        if failDeletes { throw KeychainError.unhandled(-50) }
        try storage.delete(account: account)
    }
    func exists(account: String) -> Bool { storage.exists(account: account) }
}
