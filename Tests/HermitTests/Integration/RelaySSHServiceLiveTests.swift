import Foundation
import NIOSSH
import RemoteForgeRelay
import Testing
@testable import Moshpit

@Suite("Relay live SSHService", .tags(.integration), .serialized)
struct RelaySSHServiceLiveTests {
    private static let path = ProcessInfo.processInfo.environment["MOSHPIT_RELAY_FIXTURE"]
    private enum Failure: Error { case fixture, unexpectedTrust }
    private struct Record: Decodable {
        let ssh_host_key: String
        let ssh_password: String
        let invitations: [String: Invitation]
        struct Invitation: Codable { let uri: String; let expires_at: String }
    }
    @Test("Existing Citadel SSH connects through Relay with host trust and independent sibling lifecycle",
          .enabled(if: path != nil), .timeLimit(.minutes(2)))
    func relaySSH() async throws {
        let path = try #require(Self.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw Failure.fixture }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let record = try JSONDecoder().decode(Record.self, from: data)
        let invite = try RelayInvitation(json: JSONEncoder().encode(try #require(record.invitations["ssh"])),
                                         allowInsecureLoopback: true)
        let credential = try await RelayPairingClient.redeem(invite, name: "hermit-integration")
        let vault = RelayCredentials(keychain: .inMemory())
        let ref = try await vault.save(credential)
        let binding = try RelayConnectionSettings.paired(credential, ref: ref)
        let validator = HostKeyValidator.inMemory()
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: validator, relayCredentials: vault)
        let expected = HostKeyValidator.fingerprint(of: try NIOSSHPublicKey(openSSHPublicKey:
            record.ssh_host_key.trimmingCharacters(in: .whitespacesAndNewlines)))
        var original = ServerConnection(name: "Relay fixture", host: "relay-fixture.invalid", port: 2222, username: "fixture-user")
        original.selectTransport(.relay)
        original.relayServer = binding.server;original.relayDeviceID = binding.deviceID
        original.relayService = binding.service;original.relayCredentialRef = ref
        let connection = original
        let trust: SSHService.TrustNewHostHandler = { host, port, fingerprint in
            host == "relay-fixture.invalid" && port == 22 && fingerprint == expected
        }
        async let firstDial = service.connect(connection, overrideSecret: record.ssh_password, onUnknownHost: trust)
        async let secondDial = service.connect(connection, overrideSecret: record.ssh_password, onUnknownHost: trust)
        let (first, second) = try await (firstDial, secondDial)
        do {
            #expect(try await first.executeCommand("relay-sdk-smoke") == Data("relay-ssh-ok\n".utf8))
            #expect(try await second.executeCommand("relay-sdk-smoke") == Data("relay-ssh-ok\n".utf8))
            await first.close()
            #expect(try await second.executeCommand("relay-sdk-smoke") == Data("relay-ssh-ok\n".utf8))
            let entries = await validator.snapshot()
            #expect(entries[binding.hostKeyIdentity + ":22"] == expected)
            #expect(entries[connection.host + ":22"] == nil)
        } catch {
            await first.close();await second.close();try? await vault.delete(ref: ref);throw error
        }
        await second.close()
        try await vault.delete(ref: ref)
    }
}
