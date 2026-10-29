import CloudflareAccess
import CloudflareSSH
import Darwin
import Foundation
import NIOPosix
import Testing
@testable import Moshpit

/// Opt in with TEST_RUNNER_MOSHPIT_CF_LIVE_EXPECT_EXPIRED=1 and the explicit
/// live fixture path. The fixture must reference this App's private credential
/// export. These tests neither change time nor revoke or refresh any session.
@Suite("Cloudflare live natural expiry", .tags(.integration), .serialized)
struct CloudflareLiveExpiryTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let fixturePath = environment["MOSHPIT_CF_LIVE_FIXTURE"]
    private static let isConfigured = environment["MOSHPIT_CF_LIVE_EXPECT_EXPIRED"] == "1"
        && fixturePath?.isEmpty == false

    // Fixed errors only: test failures must never render credentials, identity
    // fields, URLs, response headers, or arbitrary underlying error descriptions.
    private enum Failure: Error {
        case invalidFixture, unsafeCredentialFile, invalidCredentialExport, scopeMismatch, notExpiredYet
        case validatorAcceptedExpiredCredential, validatorFailedForAnotherReason
        case keychainAcceptedExpiredCredential, keychainFailedForAnotherReason
        case edgeAcceptedExpiredCredential, edgeUnexpectedStatus, edgeNetworkFailure
    }

    private struct Fixture: Decodable {
        let kind: String
        let status: String
        let endpoint: URL
        let teamDomain: String
        let audience: String
        let accessCredentialsPath: String

        enum CodingKeys: String, CodingKey {
            case kind, status, endpoint, audience
            case teamDomain = "team_domain"
            case accessCredentialsPath = "access_credentials_path"
        }
    }

    private struct Input {
        let endpoint: URL
        let settings: CloudflareConnectionSettings
        let application: AccessApplication
        let stored: AccessCredentials

        static func load() throws -> Self {
            let fixture: Fixture
            let settings: CloudflareConnectionSettings
            let application: AccessApplication
            do {
                guard let path = CloudflareLiveExpiryTests.fixturePath else { throw Failure.invalidFixture }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 256 * 1024 else { throw Failure.invalidFixture }
                fixture = try JSONDecoder().decode(Fixture.self, from: data)
                guard fixture.kind == "moshpit-cloudflare-access-live-v1", fixture.status == "ready",
                      let endpoint = URLComponents(url: fixture.endpoint, resolvingAgainstBaseURL: false),
                      endpoint.scheme == "wss", let hostname = endpoint.host,
                      endpoint.path == "/", endpoint.port == nil || endpoint.port == 443,
                      endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil else { throw Failure.invalidFixture }
                settings = try CloudflareConnectionSettings.validated(hostname: hostname,
                    teamDomain: fixture.teamDomain, audience: fixture.audience)
                application = try CloudflareAccessAuth.application(settings)
            } catch { throw Failure.invalidFixture }

            let data = try readPrivateExport(at: fixture.accessCredentialsPath)
            let stored: AccessCredentials
            do { stored = try JSONDecoder().decode(AccessCredentials.self, from: data) }
            catch { throw Failure.invalidCredentialExport }
            guard stored.application == application,
                  stored.identity.issuer == application.issuer,
                  stored.identity.audiences.contains(application.audience),
                  !stored.applicationToken.isEmpty else { throw Failure.scopeMismatch }
            // A premature run fails rather than faking an expired clock or
            // counting the app's 30-second early-refresh guard as real expiry.
            guard Date() >= stored.identity.expiresAt else { throw Failure.notExpiredYet }
            return Self(endpoint: fixture.endpoint, settings: settings, application: application, stored: stored)
        }

        private static func readPrivateExport(at path: String) throws -> Data {
            guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0) else {
                throw Failure.unsafeCredentialFile
            }
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unsafeCredentialFile }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o7777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_size > 0, info.st_size <= 256 * 1024 else { throw Failure.unsafeCredentialFile }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unsafeCredentialFile }
                if count == 0 { return data }
                guard data.count + count <= 256 * 1024 else { throw Failure.unsafeCredentialFile }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    @Test("Fresh JWT verification and the App Keychain reject a naturally expired login",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func validatorAndAppRejectExpiredLogin() async throws {
        let input = try Input.load()
        var rejectedAsExpired = false
        do {
            _ = try await AccessJWTValidator.validateCredentials(input.stored, for: input.application)
        } catch let error as AccessError where error == .expiredToken {
            rejectedAsExpired = true
        } catch { throw Failure.validatorFailedForAnotherReason }
        guard rejectedAsExpired else { throw Failure.validatorAcceptedExpiredCredential }

        var requiresLogin = false
        do {
            _ = try await CloudflareAccessAuth.shared.credentials(settings: input.settings)
        } catch let error as CloudflareAuthError where error == .loginRequired {
            requiresLogin = true
        } catch { throw Failure.keychainFailedForAnotherReason }
        guard requiresLogin else { throw Failure.keychainAcceptedExpiredCredential }
    }

    @Test("A new real Cloudflare WSS handshake rejects the exact expired application token",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func edgeRejectsExpiredLogin() async throws {
        let input = try Input.load()
        let connection: CloudflareSSHConnection
        do {
            connection = try await CloudflareSSHDialer().connect(endpoint: input.endpoint,
                accessToken: input.stored.applicationToken, on: MultiThreadedEventLoopGroup.singleton,
                timeout: .seconds(15))
        } catch let error as CloudflareSSHTransportError {
            guard case .httpStatus(let status) = error else { throw Failure.edgeNetworkFailure }
            guard [302, 401, 403].contains(status) else { throw Failure.edgeUnexpectedStatus }
            return
        } catch { throw Failure.edgeNetworkFailure }
        // A successful 101 is a failure of this negative test. Close immediately
        // without installing SSH handlers, sending input, or displaying a login.
        await connection.close()
        throw Failure.edgeAcceptedExpiredCredential
    }
}
