import Foundation
import Testing
@testable import Moshpit

/// Optional protocol-level coverage for the stdin exec transport. The fixture
/// describes a loopback-only test sshd with an isolated authorized key; neither
/// the system sshd nor the user's Keychain/known_hosts needs modification.
/// Pass MOSHPIT_FIX_SSH_FIXTURE to the simulator test process (for xcodebuild,
/// TEST_RUNNER_MOSHPIT_FIX_SSH_FIXTURE). The JSON contains host, port, username,
/// private_key_path and host_key_fingerprint. The private key is read only here
/// and is never placed in a command or printed to test output.
@Suite("SSH exec stdin integration", .tags(.integration), .serialized)
struct SSHExecInputIntegrationTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["MOSHPIT_FIX_SSH_FIXTURE"]
    private static let isConfigured = fixturePath?.isEmpty == false
    private static var proxyConfigured: Bool {
        guard let fixturePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { return false }
        return fixture.proxyPort != nil
    }

    private struct Fixture: Decodable, Sendable {
        let host: String
        let port: Int
        let username: String
        let privateKeyPath: String
        let hostKeyFingerprint: String
        let proxyPort: Int?

        enum CodingKeys: String, CodingKey {
            case host, port, username
            case privateKeyPath = "private_key_path"
            case hostKeyFingerprint = "host_key_fingerprint"
            case proxyPort = "proxy_port"
        }
    }

    @Test("Fixed exec command echoes framed stdin exactly, including large input",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)), arguments: [0, 131_072])
    func stdinRoundTrip(paddingBytes: Int) async throws {
        try await performRoundTrip(paddingBytes: paddingBytes, throughProxy: false)
    }

    @Test("A real SOCKS tunnel preserves SSH authentication and framed stdin",
          .enabled(if: proxyConfigured), .timeLimit(.minutes(1)), arguments: [0, 131_072])
    func stdinRoundTripThroughSOCKS(paddingBytes: Int) async throws {
        try await performRoundTrip(paddingBytes: paddingBytes, throughProxy: true)
    }

    private func performRoundTrip(paddingBytes: Int, throughProxy: Bool) async throws {
        let path = try #require(Self.fixturePath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Keep accidental fixture reuse from sending this test's synthetic input
        // and authentication key to an arbitrary host.
        #expect(fixture.host == "127.0.0.1")
        guard fixture.host == "127.0.0.1" else { return }
        let privateKey = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory())
        var connection = ServerConnection(name: "stdin-loopback-fixture",
                                          host: fixture.host, port: fixture.port,
                                          username: fixture.username, authMethod: .key,
                                          connectionProtocol: .ssh)
        if throughProxy {
            connection.useSOCKSProxy = true
            connection.socksProxyHost = "127.0.0.1"
            connection.socksProxyPort = try #require(fixture.proxyPort)
        }
        let session = try await service.connect(
            connection, overrideSecret: privateKey,
            onUnknownHost: { host, port, fingerprint in
                host == fixture.host && port == fixture.port && fingerprint == fixture.hostKeyFingerprint
            },
            onChangedHost: { _, _, _, _ in false })
        do {
            let value = "synthetic-only: 'quoted' \\\"double\\\" 中文🙂 $() `echo` ; & | \\ tab\t newline\n"
                + String(repeating: "x", count: paddingBytes)
            var payload = try JSONEncoder().encode(["text": value])
            payload.append(0x0a)
            // Constant argv for both sizes. JSON's escaped newlines keep one
            // request frame; Python reads stdin without parsing a shell string.
            let command = #"python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.readline()); sys.stdout.buffer.flush()'"#
            let echoed = try await session.executeCommand(command, standardInput: payload)
            #expect(echoed.count == payload.count)
            #expect(echoed.elementsEqual(payload), "The complete stdin frame must survive SSH byte-for-byte")
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        #expect(await session.isConnected == false)
    }
}
