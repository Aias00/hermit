import CoreImage
import Foundation
import RemoteForgeRelay
import Testing
@testable import Moshpit

@MainActor
@Suite("Relay app configuration and credentials")
struct RelayAccessTests {
    static func credential() throws -> RelayCredential {
        let id = String(repeating: "a", count: 24)
        let data = try JSONSerialization.data(withJSONObject: [
            "server": "https://relay.example.com", "device": "mac-mini", "service": "ssh",
            "client_id": id, "token": id + "." + String(repeating: "b", count: 64),
            "expires_at": Date().addingTimeInterval(600).timeIntervalSinceReferenceDate,
        ])
        return try RelayCredential(serialized: data)
    }
    @Test("Relay route persists public metadata while SSH-only and invalid routes fail closed")
    func configuration() throws {
        let credential = try Self.credential()
        var form = ConnectionTransportForm()
        form.selection = .relay
        #expect(throws: ConnectionTransportError.invalidRelayConfiguration) {
            try form.validatedConnection(from: ServerConnection(), host: "", port: "22", usesMosh: false)
        }
        try form.bindRelay(credential)
        let connection = try form.validatedConnection(from: ServerConnection(), host: "", port: "unused-relay-port", usesMosh: false)
        #expect(connection.host == "mac-mini")
        #expect(connection.port == 22)
        guard case .relay(let binding) = try connection.validatedTransport() else { Issue.record("Not Relay"); return }
        #expect(binding.matches(credential))
        let data = try JSONEncoder().encode(connection)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(String(repeating: "b", count: 64)))
        let restored = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(try restored.validatedTransport() == .relay(binding))
        var mosh = restored;mosh.connectionProtocol = .mosh
        #expect(throws: ConnectionTransportError.relayRequiresSSH) { try mosh.validatedTransport() }
        var missing = restored;missing.relayCredentialRef = nil
        #expect(throws: ConnectionTransportError.invalidRelayConfiguration) { try missing.validatedTransport() }
        #expect(CloudSyncLocalStore.portableHost(connection).relayCredentialRef == nil)
        form.selection = .direct
        let direct = try form.applying(to: restored)
        #expect(direct.relayCredentialRef == nil)
        #expect(try direct.validatedTransport() == .direct)
    }
    @Test("SSH trust scope follows Relay origin/device/service, never display name or grant ref")
    func trustScope() throws {
        let ref = RelayCredentials.newReference()
        let first = try RelayConnectionSettings.validated(server: "https://RELAY.example.com:443/", deviceID: "mini", service: "ssh", credentialRef: ref)
        let equivalent = try RelayConnectionSettings.validated(server: "https://relay.example.com", deviceID: "mini", service: "ssh", credentialRef: RelayCredentials.newReference())
        #expect(first.hostKeyIdentity == equivalent.hostKeyIdentity)
        for (server, device, service) in [("https://other.example.com", "mini", "ssh"),
                                           ("https://relay.example.com", "other", "ssh"),
                                           ("https://relay.example.com", "mini", "other")] {
            let other = try RelayConnectionSettings.validated(server: server, deviceID: device, service: service, credentialRef: ref)
            #expect(other.hostKeyIdentity != first.hostKeyIdentity)
        }
    }
    @Test("Immutable Keychain items, scope checks, deletion and SSH export isolation")
    func vault() async throws {
        let keychain = KeychainService.inMemory()
        let vault = RelayCredentials(keychain: keychain)
        let credential = try Self.credential()
        let first = try await vault.save(credential)
        let second = try await vault.save(credential)
        #expect(first != second)
        let binding = try RelayConnectionSettings.paired(credential, ref: first)
        #expect(try await vault.load(settings: binding).clientID == credential.clientID)
        let other = RelayConnectionSettings(server: binding.server, deviceID: "other", service: "ssh", credentialRef: first)
        await #expect(throws: RelayCredentialError.scopeMismatch) { try await vault.load(settings: other) }
        await #expect(throws: KeychainError.invalidData) { try await keychain.exportSSHSecret(ref: first, allowAuthentication: true) }
        try await vault.delete(ref: first)
        await #expect(throws: RelayCredentialError.missing) { try await vault.load(settings: binding) }
        #expect(try await vault.load(settings: .paired(credential, ref: second)).clientID == credential.clientID)
    }
    @Test("Signed simulator uses real device Keychain for Relay grants")
    func systemKeychain() async throws {
        let backend = SystemKeychainBackend(service: "test.hermit.relay." + UUID().uuidString)
        let vault = RelayCredentials(keychain: KeychainService(backend: backend))
        let credential = try Self.credential()
        let ref = try await vault.save(credential)
        let binding = try RelayConnectionSettings.paired(credential, ref: ref)
        #expect(try await vault.load(settings: binding).clientID == credential.clientID)
        try await vault.delete(ref: ref)
        #expect(!backend.exists(account: ref))
    }
    @Test("Invite JSON, URI and locally generated QR image share one parser")
    func imports() throws {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(240))
        let uri = "remoteforge-relay://pair?server=https%3A%2F%2Frelay.example.com&device=mini&service=ssh&expires=\(expires)#code=" + String(repeating: "a", count: 64)
        let json = try JSONSerialization.data(withJSONObject: ["uri": uri, "expires_at": expires])
        let first = try RelayInvitationImport.parse(json)
        #expect(first.device == "mini")
        #expect(try RelayInvitationImport.parse(Data(uri.utf8)).endpoint == first.endpoint)
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(uri.utf8), forKey: "inputMessage")
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let data = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        #expect(try RelayInvitationImport.parse(data).device == "mini")
        #expect(throws: RelayError.invalidInvitation) { try RelayInvitationImport.parse(Data("invalid-secret-marker".utf8)) }
    }
    @Test("Authorization failures stop recovery; transient network failures may retry")
    func recovery() {
        #expect(ConnectionFailure(RelayError.httpStatus(401)).recovery == .userAction)
        #expect(ConnectionFailure(RelayError.httpStatus(403)).recovery == .userAction)
        #expect(ConnectionFailure(RelayError.networkFailure).recovery == .retry)
        #expect(ConnectionFailure(RelayCredentialError.missing).recovery == .userAction)
        #expect(SSHConnectionDiagnostic.classify(RelayError.httpStatus(401)) == "relay.http-401")
        #expect(SSHError.map(RelayError.httpStatus(401)).description.contains("Relay"))
    }
}

@MainActor
@Suite("Relay credential ownership")
struct RelayCredentialOwnershipTests {
    @Test("Failed replacement/deletion preserves the current host and credential")
    func failuresPreserveOwnership() async throws {
        let backend = RelayFaultBackend()
        let vault = RelayCredentials(keychain: KeychainService(backend: backend))
        let credential = try RelayAccessTests.credential()
        let ref = try await vault.save(credential)
        let binding = try RelayConnectionSettings.paired(credential, ref: ref)
        backend.failWrites = true
        await #expect(throws: RelayCredentialError.storageUnavailable) { try await vault.save(credential) }
        #expect(try await vault.load(settings: binding).clientID == credential.clientID)
        let suite = "test.relay.owner." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults)
        var host = ServerConnection(host: "mini", relayServer: binding.server, relayDeviceID: binding.deviceID,
                                    relayService: binding.service, relayCredentialRef: ref)
        host.selectTransport(.relay)
        store.add(host)
        backend.failDeletes = true
        await #expect(throws: RelayCredentialError.storageUnavailable) {
            try await store.deleteSecurely(id: host.id, relayCredentials: vault)
        }
        #expect(store.connections.contains(where: { $0.id == host.id }))
        #expect(try await vault.load(settings: binding).clientID == credential.clientID)
        backend.failDeletes = false
        var sibling = host;sibling.id = UUID();store.add(sibling)
        try await store.deleteSecurely(id: host.id, relayCredentials: vault)
        #expect(try await vault.load(settings: binding).clientID == credential.clientID)
        try await store.deleteSecurely(id: sibling.id, relayCredentials: vault)
        #expect(store.connections.isEmpty)
        await #expect(throws: RelayCredentialError.missing) { try await vault.load(settings: binding) }
    }
}

private final class RelayFaultBackend: KeychainBackend, @unchecked Sendable {
    private let storage = InMemoryKeychainBackend()
    var failWrites = false
    var failDeletes = false
    func save(secret: Data, account: String, requireBiometry: Bool) throws {
        if failWrites { throw KeychainError.interactionNotAllowed }
        try storage.save(secret: secret, account: account, requireBiometry: requireBiometry)
    }
    func load(account: String, prompt: String) throws -> Data { try storage.load(account: account, prompt: prompt) }
    func delete(account: String) throws {
        if failDeletes { throw KeychainError.interactionNotAllowed }
        try storage.delete(account: account)
    }
    func exists(account: String) -> Bool { storage.exists(account: account) }
}
