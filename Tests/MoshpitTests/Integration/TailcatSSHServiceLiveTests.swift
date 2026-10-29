import Foundation
import Testing
@testable import Moshpit

/// Opt-in real WireGuard/DERP -> isolated OpenSSH verification. The private
/// fixture is produced by scripts/verify/tailcat-fixture; no production keys,
/// terminals, host trust entries, or account login are used.
@Suite("Tailcat live SSHService", .tags(.integration), .serialized)
struct TailcatSSHServiceLiveTests {
    private static let path = ProcessInfo.processInfo.environment["MOSHPIT_TAILCAT_FIXTURE"]
    private static let configured = path?.isEmpty == false
    private enum Failure: Error { case invalidFixture, unexpectedTrust, connectionFailed }

    private struct Fixture: Decodable {
        let kind: String
        let status: String
        let fixture_dir: String
        let username: String
        let port: Int
        let fingerprint: String
        let address: String
        let client_private_key: String
        let client_public_key: String
        let server_public_key: String

        static func load() throws -> Self {
            guard let path = TailcatSSHServiceLiveTests.path else { throw Failure.invalidFixture }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.size] as? NSNumber)?.intValue ?? .max < 64 * 1024 else { throw Failure.invalidFixture }
            let f = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard f.kind == "moshpit-tailcat-fixture-v1", f.status == "ready", (1...65535).contains(f.port),
                  URL(fileURLWithPath: f.fixture_dir).lastPathComponent.hasPrefix("moshpit-input-fixture-") else {
                throw Failure.invalidFixture
            }
            return f
        }
    }

    @Test("Parallel SSH connections share one Tailcat identity; closing one preserves its sibling",
          .enabled(if: configured), .timeLimit(.minutes(2)))
    func parallelSSHAndPTY() async throws {
        let fixture = try Fixture.load()
        let credentialStore = TailcatCredentials(keychain: .inMemory())
        let reference = try await credentialStore.save(TailcatCredential(
            address: fixture.address, clientPrivateKey: fixture.client_private_key,
            clientPublicKey: fixture.client_public_key, serverPublicKey: fixture.server_public_key))
        let validator = HostKeyValidator.inMemory()
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: validator,
                                 tailcatCredentials: credentialStore)
        let privateKey = try String(contentsOfFile: fixture.fixture_dir + "/client_key", encoding: .utf8)
        // An unresolvable logical name proves this cannot silently dial direct.
        var configuration = ServerConnection(name: "Tailcat fixture", host: "tailcat-fixture.invalid",
                                              port: fixture.port, username: fixture.username, authMethod: .key)
        configuration.multiplexer = .none
        configuration.selectTransport(.tailcat)
        configuration.tailcatCredentialRef = reference
        configuration.tailcatServerPublicKey = fixture.server_public_key
        let connection = configuration
        let trust: SSHService.TrustNewHostHandler = { host, port, fingerprint in
            host == connection.host && port == fixture.port && fingerprint == fixture.fingerprint
        }
        async let firstDial = service.connect(connection, overrideSecret: privateKey, onUnknownHost: trust)
        async let secondDial = service.connect(connection, overrideSecret: privateKey, onUnknownHost: trust)
        let (first, second) = try await (firstDial, secondDial)
        do {
            #expect(try await first.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            #expect(try await second.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            await first.close()
            #expect(try await second.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            guard case .tailcat(let settings) = try connection.validatedTransport() else { throw Failure.invalidFixture }
            let entries = await validator.snapshot()
            #expect(entries[settings.hostKeyIdentity + ":" + String(fixture.port)] == fixture.fingerprint)
            #expect(entries[connection.host + ":" + String(fixture.port)] == nil)
            let output = CapturedOutput()
            let pump = Task {
                for await chunk in second.dataStream { await output.append(chunk) }
            }
            do {
                try await second.requestPTY(rows: 24, cols: 80)
                let marker = "tailcat-ssh-pty-中文🙂"
                try await second.writeText(marker + "\r")
                var seen = false
                for _ in 0..<200 {
                    if await output.contains(marker) { seen = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(seen, "PTY input and output must cross the native Tailcat bridge")
                try await second.resize(rows: 37, cols: 103)
            } catch {
                await second.close()
                pump.cancel()
                await pump.value
                throw error
            }
            await second.close()
            pump.cancel()
            await pump.value
            #expect(await second.isConnected == false)
        } catch {
            await first.close()
            await second.close()
            try? await credentialStore.delete(ref: reference)
            throw error
        }
        try await credentialStore.delete(ref: reference)
    }

    private actor CapturedOutput {
        private var data = Data()
        func append(_ bytes: Data) { data.append(bytes) }
        func contains(_ marker: String) -> Bool { String(decoding: data, as: UTF8.self).contains(marker) }
    }
}
