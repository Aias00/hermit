import Darwin
import Foundation
import Testing
@testable import Moshpit

/// Opt-in product-service verification using the same explicit live fixture as
/// CloudflareSSHIntegrationTests. Access credentials come only from the App's
/// real Keychain; the disposable sshd key uses an isolated in-memory test store.
@Suite("Cloudflare live SSHService", .tags(.integration), .serialized)
struct CloudflareSSHServiceLiveTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_FIXTURE"]
    private static let isConfigured = fixturePath?.isEmpty == false
    private static let logicalHost = "moshpit-live-fixture.invalid"

    private enum Failure: Error {
        case invalidFixture, unsafePrivateKey, connectionFailed, execFailed, ptyFailed
    }

    private struct Fixture: Decodable, Sendable {
        let kind: String
        let status: String
        let endpoint: URL
        let host: String
        let port: Int
        let username: String
        let fixtureDirectory: String
        let privateKeyPath: String
        let hostKeyFingerprint: String
        let teamDomain: String
        let audience: String
        let useAppKeychain: Bool

        enum CodingKeys: String, CodingKey {
            case kind, status, endpoint, host, port, username, audience
            case fixtureDirectory = "fixture_dir"
            case privateKeyPath = "private_key_path"
            case hostKeyFingerprint = "host_key_fingerprint"
            case teamDomain = "team_domain"
            case useAppKeychain = "use_app_keychain"
        }

        static func load() throws -> Self {
            do {
                guard let path = CloudflareSSHServiceLiveTests.fixturePath else { throw Failure.invalidFixture }
                let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                guard value.kind == "moshpit-cloudflare-access-live-v1", value.status == "ready",
                      value.useAppKeychain, value.host == "127.0.0.1", (1...65535).contains(value.port),
                      let endpoint = URLComponents(url: value.endpoint, resolvingAgainstBaseURL: false),
                      endpoint.scheme == "wss", endpoint.path == "/", endpoint.port == nil || endpoint.port == 443,
                      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
                      let hostname = endpoint.host else { throw Failure.invalidFixture }
                _ = try CloudflareConnectionSettings.validated(hostname: hostname,
                    teamDomain: value.teamDomain, audience: value.audience)
                let root = URL(fileURLWithPath: value.fixtureDirectory).resolvingSymlinksInPath()
                guard root.lastPathComponent.hasPrefix("moshpit-cf-fixture-"),
                      URL(fileURLWithPath: value.privateKeyPath).resolvingSymlinksInPath().deletingLastPathComponent() == root
                else { throw Failure.invalidFixture }
                return value
            } catch { throw Failure.invalidFixture }
        }

        func privateKey() throws -> Data {
            let descriptor = Darwin.open(privateKeyPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unsafePrivateKey }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_uid == getuid(), info.st_size > 0,
                  info.st_size < 64 * 1024 else { throw Failure.unsafePrivateKey }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unsafePrivateKey }
                if count == 0 { return data }
                guard data.count + count <= 64 * 1024 else { throw Failure.unsafePrivateKey }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    private actor Output {
        private var text = ""
        private(set) var pinned = false
        func acceptPin(_ value: Bool) { pinned = value }
        func append(_ value: Data) { text += String(decoding: value, as: UTF8.self) }
        func contains(_ marker: String) -> Bool { text.contains(marker) }
    }

    private func waitFor(_ marker: String, output: Output) async throws -> Bool {
        for _ in 0..<200 {
            if await output.contains(marker) { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @Test("Product SSHService uses App Access Keychain, verifies the target key, execs and resizes a shell",
          .enabled(if: isConfigured), .timeLimit(.minutes(2)))
    func productServiceExecAndPTY() async throws {
        let fixture = try Fixture.load()
        let reference = "fixture-only-" + UUID().uuidString
        let keychain = KeychainService.inMemory(seed: [reference: try fixture.privateKey()])
        let service = SSHService(keychain: keychain, hostKeyValidator: .inMemory())
        let output = Output()
        // This deliberately unresolvable logical host makes a direct transport
        // fallback fail. Only the explicit Cloudflare hostname reaches sshd.
        var connection = ServerConnection(name: "Cloudflare product service fixture", host: Self.logicalHost,
            port: fixture.port, username: fixture.username, authMethod: .key)
        connection.multiplexer = .none
        connection.keychainRef = reference
        connection.selectTransport(.cloudflareSSH)
        connection.cloudflareHostname = fixture.endpoint.host!
        connection.cloudflareTeamDomain = fixture.teamDomain
        connection.cloudflareAudience = fixture.audience
        let session: SSHSession
        do {
            session = try await service.connect(connection, onUnknownHost: { host, port, fingerprint in
                let matches = host == Self.logicalHost && port == fixture.port && fingerprint == fixture.hostKeyFingerprint
                await output.acceptPin(matches)
                return matches
            }, onChangedHost: { _, _, _, _ in false })
        } catch { throw Failure.connectionFailed }
        do {
            let echoed: Data
            do { echoed = try await session.executeCommand("printf moshpit-cloudflare-product-service-ok") }
            catch { throw Failure.execFailed }
            #expect(echoed == Data("moshpit-cloudflare-product-service-ok".utf8))
            #expect(await output.pinned)
            let pump = Task {
                for await chunk in session.dataStream { await output.append(chunk) }
            }
            do {
                try await session.requestPTY(rows: 24, cols: 80)
                try await session.writeText("stty -echo; printf '\\036INITIAL:%s\\037\\n' \"$(stty size)\"\n")
                #expect(try await waitFor("\u{1e}INITIAL:24 80\u{1f}", output: output))
                try await session.resize(rows: 37, cols: 103)
                try await session.writeText("printf '\\036RESIZED:%s\\037\\n' \"$(stty size)\"\n")
                #expect(try await waitFor("\u{1e}RESIZED:37 103\u{1f}", output: output))
            } catch {
                await session.close()
                pump.cancel()
                await pump.value
                throw Failure.ptyFailed
            }
            await session.close()
            pump.cancel()
            await pump.value
        } catch {
            await session.close()
            throw error
        }
        await service.clearAllCachedSecrets()
        try await keychain.delete(forRef: reference)
        #expect(await session.isConnected == false)
    }
}
