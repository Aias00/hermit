import Foundation
import Testing
@testable import Moshpit

/// Explicit cleanup of one disposable verification connection and its Access
/// scope. Ordinary runs skip this test. No RESET, credential export, or identity
/// label is involved; other saved connections must survive byte-for-byte at
/// the decoded model level.
@Suite("Cloudflare explicit live verification cleanup", .tags(.integration), .serialized)
struct CloudflareLiveCleanupTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_CLEANUP_FIXTURE"]
    private static let connectionName = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_CLEANUP_CONNECTION_NAME"]
    private static let isConfigured = fixturePath?.isEmpty == false && connectionName?.isEmpty == false

    private enum Failure: Error {
        case invalidConfiguration, storeNotReadable, storedConnectionsInvalid
        case ambiguousConnection, connectionScopeMismatch, signOutFailed
        case connectionsChangedDuringCleanup, cleanupVerificationFailed
    }

    private struct Fixture: Decodable {
        let kind: String
        let status: String
        let endpoint: URL
        let teamDomain: String
        let audience: String

        enum CodingKeys: String, CodingKey {
            case kind, status, endpoint, audience
            case teamDomain = "team_domain"
        }

        static func settings(at path: String) throws -> CloudflareConnectionSettings {
            do {
                guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure.invalidConfiguration }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 256 * 1024 else { throw Failure.invalidConfiguration }
                let fixture = try JSONDecoder().decode(Self.self, from: data)
                guard fixture.kind == "moshpit-cloudflare-access-live-v1", fixture.status == "ready",
                      let endpoint = URLComponents(url: fixture.endpoint, resolvingAgainstBaseURL: false),
                      endpoint.scheme == "wss", let hostname = endpoint.host,
                      endpoint.path == "/", endpoint.port == nil || endpoint.port == 443,
                      endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil else { throw Failure.invalidConfiguration }
                return try CloudflareConnectionSettings.validated(hostname: hostname,
                    teamDomain: fixture.teamDomain, audience: fixture.audience)
            } catch { throw Failure.invalidConfiguration }
        }
    }

    @MainActor
    private func readableStore() throws -> ConnectionStore {
        let store = ConnectionStore(readiness: .system)
        guard store.isAuthoritative else { throw Failure.storeNotReadable }
        // ConnectionStore intentionally tolerates corrupt data in the UI. A
        // destructive maintenance test must refuse that fallback empty list.
        if let data = UserDefaults.standard.data(forKey: "moshpit.connections") {
            let decoded: [ServerConnection]
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                decoded = try decoder.decode([ServerConnection].self, from: data)
            } catch { throw Failure.storedConnectionsInvalid }
            guard decoded == store.connections else { throw Failure.storedConnectionsInvalid }
        } else if UserDefaults.standard.object(forKey: "moshpit.connections") != nil {
            throw Failure.storedConnectionsInvalid
        }
        guard Set(store.connections.map(\.id)).count == store.connections.count else {
            throw Failure.storedConnectionsInvalid
        }
        return store
    }

    @Test("Sign out the explicit live scope and remove at most one exact matching verification connection",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    @MainActor
    func removeExplicitVerificationConnection() async throws {
        guard let path = Self.fixturePath, let name = Self.connectionName,
              name.range(of: "^Cloudflare Live [A-F0-9]{8}$", options: .regularExpression) != nil else {
            throw Failure.invalidConfiguration
        }
        let settings = try Fixture.settings(at: path)
        let before = try readableStore().connections
        let named = before.filter { $0.name == name }
        guard named.count <= 1 else { throw Failure.ambiguousConnection }
        if let candidate = named.first {
            do {
                guard case .cloudflare(let candidateSettings) = try candidate.validatedTransport(),
                      candidateSettings == settings else { throw Failure.connectionScopeMismatch }
            } catch { throw Failure.connectionScopeMismatch }
        }
        // Validate the complete removal plan before touching even this scope's
        // Keychain records. This never opens a browser or refreshes a token.
        do { try await CloudflareAccessAuth.shared.signOut(settings: settings) }
        catch { throw Failure.signOutFailed }

        let store = try readableStore()
        guard store.connections == before else { throw Failure.connectionsChangedDuringCleanup }
        let removalID = named.first?.id
        let expected = before.filter { $0.id != removalID }
        if let removalID { store.delete(id: removalID) }
        let remaining = try readableStore().connections
        guard remaining.count == expected.count,
              remaining.map(\.id) == expected.map(\.id), remaining == expected else {
            throw Failure.cleanupVerificationFailed
        }
        print("[CloudflareLiveCleanup] Explicit Access scope signed out; verification connections removed: \(named.count); other connections preserved.")
    }
}
