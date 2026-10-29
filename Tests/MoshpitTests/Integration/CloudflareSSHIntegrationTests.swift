import Foundation
import Testing
@preconcurrency import Citadel
import CloudflareSSH
import CloudflareAccess
import Crypto
import NIOCore
import NIOPosix
import NIOSSL
@testable import Moshpit

/// A real OpenSSH session carried by a disposable loopback TLS/WS bridge.
/// Start scripts/spikes/cloudflare-ssh/local_fixture.py and pass its JSON path
/// as MOSHPIT_CF_FIXTURE (TEST_RUNNER_MOSHPIT_CF_FIXTURE for xcodebuild).
/// The local CA is injected only here; production TLS verification is unchanged.
/// MOSHPIT_CF_LIVE_FIXTURE selects a real Access-protected Cloudflare ingress,
/// with system TLS roots and validated credentials obtained by browser login.
/// The default local fixture proves interoperability only, NOT G1 or G2.
@Suite("Cloudflare SSH integration", .tags(.integration), .serialized)
struct CloudflareSSHIntegrationTests {
    private static let liveFixturePath = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_FIXTURE"]
    private static let isLive = liveFixturePath?.isEmpty == false
    private static let fixturePath = isLive ? liveFixturePath : ProcessInfo.processInfo.environment["MOSHPIT_CF_FIXTURE"]
    private static let isConfigured = fixturePath?.isEmpty == false
    private static let sustainedEnabled = ProcessInfo.processInfo.environment["MOSHPIT_CF_SUSTAINED"] == "1"

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
        let certificatePath: String?
        let accessTokenPath: String?
        let accessCredentialsPath: String?
        let teamDomain: String?
        let audience: String?
        let useAppKeychain: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, status, endpoint, host, port, username
            case fixtureDirectory = "fixture_dir"
            case privateKeyPath = "private_key_path"
            case hostKeyFingerprint = "host_key_fingerprint"
            case certificatePath = "ca_certificate_path"
            case accessTokenPath = "access_token_path"
            case accessCredentialsPath = "access_credentials_path"
            case teamDomain = "team_domain"
            case audience
            case useAppKeychain = "use_app_keychain"
        }

        static func load() throws -> Self {
            let path = try #require(CloudflareSSHIntegrationTests.fixturePath)
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let expectedKind = isLive ? "moshpit-cloudflare-access-live-v1" : "moshpit-local-cloudflare-ssh-fixture-v1"
            try #require(value.kind == expectedKind && value.status == "ready")
            try #require(value.host == "127.0.0.1" && (1...65535).contains(value.port))
            let endpoint = try #require(URLComponents(url: value.endpoint, resolvingAgainstBaseURL: false))
            try #require(endpoint.scheme == "wss")
            if isLive {
                try #require(endpoint.path == "/" && (endpoint.port == nil || endpoint.port == 443))
                _ = try value.application()
                try #require(value.certificatePath == nil && value.accessTokenPath == nil)
            } else {
                try #require(endpoint.host == "localhost" && endpoint.path == "/ssh")
            }
            try #require(endpoint.user == nil && endpoint.password == nil && endpoint.query == nil && endpoint.fragment == nil)
            let root = URL(fileURLWithPath: value.fixtureDirectory).resolvingSymlinksInPath()
            try #require(root.lastPathComponent.hasPrefix("moshpit-cf-fixture-"))
            for path in [value.privateKeyPath, value.certificatePath, value.accessTokenPath].compactMap({ $0 }) {
                let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                try #require(file.deletingLastPathComponent() == root)
            }
            return value
        }

        func dialer() throws -> CloudflareSSHDialer {
            if isLive { return try CloudflareSSHDialer() }
            return try CloudflareSSHDialer(trustRoots: .certificates(NIOSSLCertificate.fromPEMFile(try #require(certificatePath))))
        }

        func application() throws -> AccessApplication {
            try AccessApplication(hostname: #require(endpoint.host), audience: #require(audience),
                                  teamDomain: #require(teamDomain))
        }

        func token() async throws -> String {
            if !isLive { return try String(contentsOfFile: #require(accessTokenPath), encoding: .utf8) }
            if useAppKeychain == true {
                let app = try application()
                let settings = try CloudflareConnectionSettings.validated(hostname: app.hostname,
                    teamDomain: app.teamDomain, audience: app.audience)
                return try await CloudflareAccessAuth.shared.credentials(settings: settings).applicationToken
            }
            let path = try #require(accessCredentialsPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
            try #require(permissions & 0o077 == 0)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try #require(data.count < 256 * 1024)
            let stored = try JSONDecoder().decode(AccessCredentials.self, from: data)
            return try await AccessJWTValidator.validateCredentials(stored, for: application()).applicationToken
        }
    }

    private actor ObservedHostKey {
        private(set) var fingerprint: String?
        func record(_ value: String) { fingerprint = value }
    }

    private struct Connected {
        let client: SSHClient
        let session: SSHSession
        let tunnel: CloudflareSSHConnection
        let observed: ObservedHostKey

        func close() async {
            let snapshot = tunnel.diagnostics
            print("[CloudflareSSH] before cleanup: first=\(String(describing: snapshot.firstTermination?.kind)) ping=\(snapshot.pingsSent) matchingPong=\(snapshot.matchingPongsReceived) elapsedMs=\(snapshot.elapsedMilliseconds)")
            await session.close()
            await tunnel.close()
        }
    }

    private func connect(_ fixture: Fixture, acceptHostKey: Bool = true,
                         observed: ObservedHostKey = ObservedHostKey()) async throws -> Connected {
        let diagnosticID = UUID().uuidString
        let tunnel = try await fixture.dialer().connect(
            endpoint: fixture.endpoint, accessToken: fixture.token(),
            on: MultiThreadedEventLoopGroup.singleton, onDiagnostic: { event in
                print("[CloudflareSSH \(diagnosticID)] +\(event.elapsedMilliseconds)ms \(event.kind)")
            })
        do {
            // Key material is only read from a mode-0600 fixture file. It is
            // never put into argv, an assertion value, or diagnostic output.
            let pem = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
            let delegate = TOFUHostKeyDelegate(
                validator: .inMemory(), host: fixture.host, port: fixture.port,
                onNewHost: { host, port, fingerprint in
                    await observed.record(fingerprint)
                    return acceptHostKey && host == fixture.host && port == fixture.port
                        && fingerprint == fixture.hostKeyFingerprint
                }, onChangedHost: { _, _, _, _ in false })
            let client = try await CitadelSSHClientProvider().connect(
                on: tunnel.channel,
                authenticationMethod: .ed25519(username: fixture.username, privateKey: key),
                hostKeyValidator: .custom(delegate))
            try await SSHChannelAuthentication.complete(on: tunnel.channel) {
                try await tunnel.activate()
            }
            let connection = ServerConnection(name: "local-tls-websocket-ssh-fixture", host: fixture.host,
                                              port: fixture.port, username: fixture.username, authMethod: .key)
            return Connected(client: client, session: SSHSession(connection: connection, client: client),
                             tunnel: tunnel, observed: observed)
        } catch {
            print("[CloudflareSSH \(diagnosticID)] setup failed; first=\(String(describing: tunnel.diagnostics.firstTermination?.kind))")
            await tunnel.close()
            throw error
        }
    }

    @Test("Real SSH validates its host key and round-trips stdin through TLS/WS",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)), arguments: [0, 131_072])
    func execInput(paddingBytes: Int) async throws {
        let fixture = try Fixture.load()
        let connected = try await connect(fixture)
        do {
            let text = "synthetic: 'quoted' 中文🙂 $() `echo` ; & | \t \n" + String(repeating: "x", count: paddingBytes)
            var input = try JSONEncoder().encode(["text": text])
            input.append(0x0a)
            let command = #"python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.readline()); sys.stdout.buffer.flush()'"#
            let echoed = try await connected.session.executeCommand(command, standardInput: input)
            #expect(echoed.count == input.count)
            #expect(echoed.elementsEqual(input), "SSH stdin must survive binary fragmentation and interleaved ping frames")
            #expect(await connected.observed.fingerprint == fixture.hostKeyFingerprint)
            await connected.close()
        } catch {
            await connected.close()
            throw error
        }
        #expect(await connected.session.isConnected == false)
    }

    private actor TerminalOutput {
        private var text = ""
        func append(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
        func contains(_ marker: String) -> Bool { text.contains(marker) }
    }

    private func waitFor(_ marker: String, output: TerminalOutput) async throws -> Bool {
        for _ in 0..<200 {
            if await output.contains(marker) { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @Test("PTY input and resize reach the remote terminal over the same tunnel",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func ptyAndResize() async throws {
        let fixture = try Fixture.load()
        let connected = try await connect(fixture)
        let output = TerminalOutput()
        let pump = Task {
            for await chunk in connected.session.dataStream { await output.append(chunk) }
        }
        do {
            try await connected.session.requestPTY(rows: 24, cols: 80)
            // Literal control delimiters exist only in printf's output, so an
            // echoed command cannot satisfy the assertion before it executes.
            try await connected.session.writeText("stty -echo; printf '\\036INITIAL:%s\\037\\n' \"$(stty size)\"\n")
            #expect(try await waitFor("\u{1e}INITIAL:24 80\u{1f}", output: output))
            try await connected.session.resize(rows: 33, cols: 101)
            try await connected.session.writeText("printf '\\036RESIZED:%s\\037\\n' \"$(stty size)\"\n")
            #expect(try await waitFor("\u{1e}RESIZED:33 101\u{1f}", output: output))
            await connected.close()
        } catch {
            await connected.close()
            pump.cancel()
            await pump.value
            throw error
        }
        pump.cancel()
        await pump.value
    }

    @Test("SFTP shares the authenticated WS-carried SSH connection",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func sftpRoundTrip() async throws {
        let fixture = try Fixture.load()
        let connected = try await connect(fixture)
        do {
            let path = URL(fileURLWithPath: fixture.fixtureDirectory)
                .appendingPathComponent("sftp-\(UUID().uuidString).bin").path
            let input = Data((0..<32768).map { UInt8($0 % 251) })
            let received = try await connected.client.withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(ByteBuffer(bytes: input))
                }
                let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                    try await file.readAll()
                }
                try await sftp.remove(at: path)
                return Data(buffer.readableBytesView)
            }
            #expect(received.elementsEqual(input))
            #expect(await connected.observed.fingerprint == fixture.hostKeyFingerprint)
            await connected.close()
        } catch {
            await connected.close()
            throw error
        }
    }

    /// Opt in with MOSHPIT_CF_SUSTAINED=1. Short exec tests finish before the
    /// production heartbeat fires; this keeps the same authenticated carrier
    /// through two actual ping/pong exchanges, then reuses it for exec and SFTP.
    @Test("An authenticated carrier survives two heartbeats and subsequent exec and SFTP traffic",
          .enabled(if: isConfigured && sustainedEnabled), .timeLimit(.minutes(2)))
    func sustainedSession() async throws {
        let fixture = try Fixture.load()
        let connected = try await connect(fixture)
        do {
            let initial = try await connected.session.executeCommand("printf moshpit-before-idle")
            try #require(initial == Data("moshpit-before-idle".utf8))
            try await Task.sleep(for: .seconds(45))
            let idle = connected.tunnel.diagnostics
            try #require(idle.firstTermination == nil, "The carrier terminated during the idle heartbeat interval")
            try #require(idle.pingsSent >= 2 && idle.matchingPongsReceived >= 2,
                         "At least two production heartbeat exchanges must complete")

            let input = Data(String(repeating: "0123456789abcdef", count: 16_384).utf8) + Data([0x0a])
            let command = #"python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.readline()); sys.stdout.buffer.flush()'"#
            let echoed = try await connected.session.executeCommand(command, standardInput: input)
            try #require(echoed.elementsEqual(input), "Exec bytes changed after the idle interval")

            let path = URL(fileURLWithPath: fixture.fixtureDirectory)
                .appendingPathComponent("sftp-sustained-\(UUID().uuidString).bin").path
            let received = try await connected.client.withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(ByteBuffer(bytes: input))
                }
                let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                    try await file.readAll()
                }
                try await sftp.remove(at: path)
                return Data(buffer.readableBytesView)
            }
            try #require(received.elementsEqual(input), "SFTP bytes changed after the idle interval")
            #expect(connected.tunnel.diagnostics.firstTermination == nil)
            #expect(await connected.observed.fingerprint == fixture.hostKeyFingerprint)
            await connected.close()
        } catch {
            await connected.close()
            throw error
        }
    }

    @Test("Production trust roots reject the fixture's untrusted local CA",
          .enabled(if: isConfigured && !isLive), .timeLimit(.minutes(1)))
    func defaultTLSRejectsLocalCA() async throws {
        let fixture = try Fixture.load()
        await #expect(throws: CloudflareSSHTransportError.self) {
            let unexpected = try await CloudflareSSHDialer().connect(
                endpoint: fixture.endpoint, accessToken: fixture.token(),
                on: MultiThreadedEventLoopGroup.singleton, timeout: .seconds(5))
            await unexpected.close()
        }
    }

    @Test("A missing access header is refused before SSH",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func accessHeaderRequired() async throws {
        let fixture = try Fixture.load()
        do {
            let unexpected = try await fixture.dialer().connect(
                endpoint: fixture.endpoint, accessToken: nil,
                on: MultiThreadedEventLoopGroup.singleton)
            await unexpected.close()
            Issue.record("An unauthenticated request must never reach SSH")
        } catch let CloudflareSSHTransportError.httpStatus(status) {
            #expect(Self.isLive ? [301, 302, 303, 307, 308, 401, 403].contains(status) : status == 401)
        }
    }

    @Test("Refusing the real SSH host key prevents exec even after WSS connects",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func rejectedHostKeyPreventsExec() async throws {
        let fixture = try Fixture.load()
        let observed = ObservedHostKey()
        await #expect(throws: (any Error).self) {
            let unexpected = try await connect(fixture, acceptHostKey: false, observed: observed)
            await unexpected.close()
        }
        #expect(await observed.fingerprint == fixture.hostKeyFingerprint)
    }
}
