import Foundation
import Testing
@testable import Moshpit

/// Opt-in only after the user enrolls this simulator through the actual UI.
/// Targets a disposable, forced-command byte receiver on the Mac's tailnet IP;
/// it never executes user-supplied commands or takes over a terminal session.
@Suite("Tailscale live SSHService", .tags(.integration), .serialized)
struct TailscaleSSHServiceLiveTests {
    private static let path = ProcessInfo.processInfo.environment["MOSHPIT_TAILSCALE_FIXTURE"]
    private static let configured = path?.isEmpty == false
    private enum Failure: Error { case invalidFixture, loginRequired, peerMissing }

    private struct Fixture: Decodable {
        let kind: String
        let status: String
        let fixture_dir: String
        let username: String
        let port: Int
        let fingerprint: String
        let listen_address: String
        static func load() throws -> Self {
            guard let path = TailscaleSSHServiceLiveTests.path else { throw Failure.invalidFixture }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.size] as? NSNumber)?.intValue ?? .max < 64 * 1024 else { throw Failure.invalidFixture }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard value.kind == "moshpit-input-fixture-v1", value.status == "ready", (1...65535).contains(value.port),
                  value.listen_address.hasPrefix("100."),
                  URL(fileURLWithPath: value.fixture_dir).lastPathComponent.hasPrefix("moshpit-input-fixture-") else {
                throw Failure.invalidFixture
            }
            return value
        }
    }

    @Test("Real enrollment, shared parallel SSH, UTF-8 PTY, stable host trust and node restart",
          .enabled(if: configured), .timeLimit(.minutes(3)))
    func liveSSHAndRecovery() async throws {
        let fixture = try Fixture.load()
        let runtime = TailscaleRuntime.shared
        var account = try await runtime.snapshot()
        for _ in 0..<60 {
            if account.state == .connected,
               account.peers.contains(where: { $0.addresses.contains(fixture.listen_address) }) { break }
            try await Task.sleep(for: .milliseconds(500))
            account = try await runtime.snapshot()
        }
        guard account.state == .connected, let accountID = account.accountID else { throw Failure.loginRequired }
        guard let peer = account.peers.first(where: { $0.addresses.contains(fixture.listen_address) }) else {
            Issue.record("Fixture device unavailable: \(account.peers.count) visible peers, addresses \(account.peers.flatMap(\.addresses))")
            throw Failure.peerMissing
        }
        let key = try String(contentsOfFile: fixture.fixture_dir + "/client_key", encoding: .utf8)
        let validator = HostKeyValidator.inMemory()
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: validator, tailscaleRuntime: runtime)
        var configuration = ServerConnection(name: "Tailscale fixture", host: "must-not-dial-direct.invalid",
                                              port: fixture.port, username: fixture.username, authMethod: .key)
        configuration.multiplexer = .none
        configuration.selectTransport(.tailscale)
        configuration.tailscaleAccountID = accountID
        configuration.tailscalePeerID = peer.id
        let connection = configuration
        let trust: SSHService.TrustNewHostHandler = { host, port, fingerprint in
            host == connection.host && port == fixture.port && fingerprint == fixture.fingerprint
        }
        async let firstDial = service.connect(connection, overrideSecret: key, onUnknownHost: trust)
        async let secondDial = service.connect(connection, overrideSecret: key, onUnknownHost: trust)
        let (first, second) = try await (firstDial, secondDial)
        do {
            #expect(try await first.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            await first.close()
            #expect(try await second.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            let entries = await validator.snapshot()
            #expect(entries["tailscale:" + accountID + ":peer:" + peer.id + ":" + String(fixture.port)] == fixture.fingerprint)
            #expect(entries[connection.host + ":" + String(fixture.port)] == nil)
            let output = CapturedOutput()
            let pump = Task { for await chunk in second.dataStream { await output.append(chunk) } }
            do {
                try await second.requestPTY(rows: 24, cols: 80)
                let marker = "tailscale-ssh-中文🙂"
                try await second.writeText(marker + "\r")
                var seen = false
                for _ in 0..<200 {
                    if await output.contains(marker) { seen = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(seen)
                try await second.resize(rows: 37, cols: 103)
            } catch {
                await second.close(); pump.cancel(); await pump.value
                throw error
            }
            await second.close(); pump.cancel(); await pump.value
        } catch {
            await first.close(); await second.close(); await runtime.restart()
            throw error
        }
        // Recreate the native node from encrypted state without a new login.
        await runtime.restart()
        for _ in 0..<60 {
            if try await runtime.snapshot().state == .connected { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let resumed = try await service.connect(connection, overrideSecret: key, onUnknownHost: trust)
        do {
            #expect(try await resumed.executeCommand("printf fixture-ready") == Data("fixture-ready".utf8))
            await resumed.close()
        } catch { await resumed.close(); await runtime.restart(); throw error }
        await runtime.restart()
    }

    private actor CapturedOutput {
        private var bytes = Data()
        func append(_ data: Data) { bytes.append(data) }
        func contains(_ marker: String) -> Bool { String(decoding: bytes, as: UTF8.self).contains(marker) }
    }
}
