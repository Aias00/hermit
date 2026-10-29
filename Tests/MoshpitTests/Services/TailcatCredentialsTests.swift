import Foundation
import Testing
@testable import Moshpit

@Suite("Tailcat device credentials")
struct TailcatCredentialsTests {
    @Test("Address and stable client identity round trip only through Keychain")
    func keychainRoundTrip() async throws {
        let backend = FaultInjectingTailcatKeychain()
        let store = TailcatCredentials(keychain: KeychainService(backend: backend))
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await store.save(credential)
        #expect(TailcatCredentials.isReference(ref))
        #expect(try await store.load(ref: ref) == credential)
        let raw = try backend.load(account: ref, prompt: "test")
        #expect(raw.starts(with: Data("bplist00".utf8)))
        #expect((try? JSONSerialization.jsonObject(with: raw)) == nil)

        let edited = try TailcatCredential.create(address: TailcatCredentialFixture.address,
                                                 clientPrivateKey: credential.clientPrivateKey)
        let replacementRef = try await store.save(edited)
        #expect(replacementRef != ref)
        #expect(edited.clientPublicKey == credential.clientPublicKey)
        #expect(try await store.load(ref: ref) == credential, "Staging must preserve the old item until its owner commits")
        try await store.delete(ref: ref)
        #expect(!backend.exists(account: ref))
        #expect(try await store.load(ref: replacementRef) == edited)
    }

    @Test("A failed replacement write cannot delete the saved address or client identity")
    func failedStagingRetainsPreviousCredential() async throws {
        let backend = FaultInjectingTailcatKeychain()
        let store = TailcatCredentials(keychain: KeychainService(backend: backend))
        let original = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await store.save(original)
        backend.setFailWrites(true)
        await #expect(throws: TailcatCredentialError.storageUnavailable) { try await store.save(original) }
        #expect(try await store.load(ref: ref) == original)
        #expect(backend.accounts == [ref])
    }

    @Test("Stored public identities are checked against the secret native key material")
    func mismatchedStoredIdentityRejected() async throws {
        let backend = FaultInjectingTailcatKeychain()
        let store = TailcatCredentials(keychain: KeychainService(backend: backend))
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await store.save(credential)
        let raw = try backend.load(account: ref, prompt: "test")
        for field in ["serverPublicKey", "clientPublicKey"] {
            var plist = try #require(PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])
            plist[field] = "nodekey:" + String(repeating: "a", count: 64)
            let corrupted = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try backend.save(secret: corrupted, account: ref, requireBiometry: false)
            await #expect(throws: TailcatCredentialError.invalidStoredCredential) { try await store.load(ref: ref) }
        }
    }

    @Test("Credential and error descriptions do not expose capability or private keys")
    func diagnosticsRedactSecrets() throws {
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        for description in [String(describing: credential), String(reflecting: credential)] {
            #expect(!description.contains(credential.address))
            #expect(!description.contains(credential.clientPrivateKey))
            #expect(description.contains("redacted"))
        }
        do {
            _ = try TailcatCredential.create(address: "tcSECRET_SENTINEL")
            Issue.record("Malformed capability should fail")
        } catch {
            #expect(error as? TailcatCredentialError == .invalidAddress)
            #expect(!error.localizedDescription.contains("SECRET_SENTINEL"))
        }
        #expect(throws: TailcatCredentialError.missingPresharedKey) {
            try TailcatCredential.create(address: TailcatCredentialFixture.addressWithoutPSK)
        }
    }

    @Test("Production credentials use the system Keychain even on Simulator")
    func productionUsesSystemKeychain() async throws {
        let store = TailcatCredentials()
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await store.save(credential)
        let backend = SystemKeychainBackend(service: (Bundle.main.bundleIdentifier ?? "com.cluas.moshpit") + ".tailcat.credentials")
        defer { try? backend.delete(account: ref) }
        #expect(backend.exists(account: ref), "A Tailcat secret must not fall back to the simulator JSON vault")
        #expect(try await store.load(ref: ref) == credential)
    }

    @MainActor
    @Test("Failed Keychain deletion retains connection metadata for retry")
    func deleteFailureRetainsConnection() async throws {
        let suite = "test.tailcat.delete.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FaultInjectingTailcatKeychain()
        let credentials = TailcatCredentials(keychain: KeychainService(backend: backend))
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await credentials.save(credential)
        var connection = ServerConnection(host: "mac-mini", tailcatCredentialRef: ref, tailcatServerPublicKey: credential.serverPublicKey)
        connection.selectTransport(.tailcat)
        let store = ConnectionStore(defaults: defaults)
        store.add(connection)
        backend.setFailDeletes(true)
        await #expect(throws: TailcatCredentialError.storageUnavailable) {
            try await store.deleteSecurely(id: connection.id, tailcatCredentials: credentials)
        }
        #expect(store.connections == [connection])
        #expect(try await credentials.load(ref: ref) == credential)
        backend.setFailDeletes(false)
        try await store.deleteSecurely(id: connection.id, tailcatCredentials: credentials)
        #expect(store.connections.isEmpty)
        #expect(!backend.exists(account: ref))
        #expect(ConnectionStore(defaults: defaults).connections.isEmpty)
    }

    @MainActor
    @Test("Removing a duplicate connection retains shared credentials until its last reference")
    func deletionRespectsSharedReferences() async throws {
        let suite = "test.tailcat.shared.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TailcatCredentials(keychain: .inMemory())
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await credentials.save(credential)
        var first = ServerConnection(host: "mac-mini", tailcatCredentialRef: ref, tailcatServerPublicKey: credential.serverPublicKey)
        first.selectTransport(.tailcat)
        var second = first
        second.id = UUID()
        let store = ConnectionStore(defaults: defaults)
        store.add(first)
        store.add(second)
        try await store.deleteSecurely(id: first.id, tailcatCredentials: credentials)
        #expect(try await credentials.load(ref: ref) == credential)
        try await store.deleteSecurely(id: second.id, tailcatCredentials: credentials)
        await #expect(throws: TailcatCredentialError.missingCredential) { try await credentials.load(ref: ref) }
    }

    @Test("Locked or unauthorized Keychain reads require user action without leaking backend errors")
    func unavailableKeychainRead() async throws {
        let backend = FaultInjectingTailcatKeychain()
        let store = TailcatCredentials(keychain: KeychainService(backend: backend))
        let credential = try TailcatCredential.create(address: TailcatCredentialFixture.address)
        let ref = try await store.save(credential)
        backend.setFailReads(true)
        await #expect(throws: TailcatCredentialError.storageUnavailable) { try await store.load(ref: ref) }
        backend.setFailReads(false)
        #expect(try await store.load(ref: ref) == credential)
    }
}

private final class FaultInjectingTailcatKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failWrites = false
    private var failDeletes = false
    private var failReads = false

    var accounts: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
    func setFailWrites(_ value: Bool) { lock.lock(); failWrites = value; lock.unlock() }
    func setFailDeletes(_ value: Bool) { lock.lock(); failDeletes = value; lock.unlock() }
    func setFailReads(_ value: Bool) { lock.lock(); failReads = value; lock.unlock() }
    func save(secret: Data, account: String, requireBiometry: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainError.interactionNotAllowed }
        values[account] = secret
    }
    func load(account: String, prompt: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw KeychainError.interactionNotAllowed }
        guard let value = values[account] else { throw KeychainError.notFound }
        return value
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failDeletes { throw KeychainError.interactionNotAllowed }
        values.removeValue(forKey: account)
    }
    func exists(account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[account] != nil }
}
