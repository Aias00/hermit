import Foundation
import Testing
@testable import Moshpit

@Suite("Connection transport migration and validation")
struct ConnectionTransportTests {
    private func cloudflareConnection() -> ServerConnection {
        var connection = ServerConnection(host: "workstation.internal", port: 2222, username: "developer")
        connection.selectTransport(.cloudflareSSH)
        connection.cloudflareHostname = "ssh.example.com"
        connection.cloudflareTeamDomain = "example-team.cloudflareaccess.com"
        connection.cloudflareAudience = "application-aud_123"
        return connection
    }

    @Test("Cloudflare records without Access metadata retain automatic discovery after storage")
    func automaticDiscoveryRecord() throws {
        var connection = ServerConnection(host: "ssh.example.com", username: "developer")
        connection.selectTransport(.cloudflareSSH)
        let restored = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(connection))
        guard case .cloudflare(let settings) = try restored.validatedTransport() else {
            Issue.record("An automatic Cloudflare connection must not become a direct SSH connection")
            return
        }
        #expect(settings.hostname == "ssh.example.com")
        #expect(settings.usesAutomaticDiscovery)
    }

    @Test("Older records without transport fields retain their SOCKS choice", arguments: [nil, false, true] as [Bool?])
    func legacyRecords(proxyEnabled: Bool?) throws {
        var original = ServerConnection(host: "server.internal")
        original.useSOCKSProxy = proxyEnabled
        original.socksProxyHost = "127.0.0.1"
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["transportRaw", "cloudflareHostname", "cloudflareTeamDomain", "cloudflareAudience"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.transportRaw == nil)
        #expect(try decoded.validatedTransport() == (proxyEnabled == true ? .socks5(host: "127.0.0.1", port: 1080) : .direct))
    }

    @Test("An unknown raw transport survives storage without losing other hosts or dialing direct")
    func unknownTransportSurvivesStore() throws {
        let suite = "test.transport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unknown = ServerConnection(name: "future", host: "future.internal")
        unknown.transportRaw = "future-private-tunnel"
        unknown.useSOCKSProxy = true
        let known = ServerConnection(name: "kept", host: "kept.internal")
        let store = ConnectionStore(defaults: defaults)
        store.add(unknown)
        store.add(known)
        let decoded = ConnectionStore(defaults: defaults).connections
        #expect(decoded.count == 2)
        let restored = try #require(decoded.first)
        #expect(restored.transportRaw == unknown.transportRaw)
        #expect(restored.transport == nil)
        #expect(throws: ConnectionTransportError.unsupportedTransport("future-private-tunnel")) {
            try restored.validatedTransport()
        }
    }

    @Test("Only an explicit selected route is active; inactive fields do not choose one")
    func explicitRouteIsAuthoritative() throws {
        var connection = cloudflareConnection()
        connection.selectTransport(.direct)
        connection.socksProxyHost = "unused-proxy"
        connection.socksProxyPort = -1
        #expect(try connection.validatedTransport() == .direct)
        connection.transportRaw = ConnectionTransport.socks5.rawValue
        connection.useSOCKSProxy = false
        connection.socksProxyPort = 1081
        #expect(try connection.validatedTransport() == .socks5(host: "unused-proxy", port: 1081))
        connection.selectTransport(.cloudflareSSH)
        connection.socksProxyPort = -1
        #expect(try connection.validatedTransport() == .cloudflare(
            CloudflareConnectionSettings(hostname: "ssh.example.com", teamDomain: "example-team.cloudflareaccess.com",
                                         audience: "application-aud_123")))
    }

    @Test("Conflicting active SOCKS flag is rejected until selection normalizes it", arguments: [ConnectionTransport.direct, .cloudflareSSH, .tailcat, .tailscale])
    func conflictingProxyFlag(transport: ConnectionTransport) throws {
        var connection = cloudflareConnection()
        connection.tailcatCredentialRef = TailcatCredentials.newReference()
        connection.tailcatServerPublicKey = "nodekey:" + String(repeating: "1", count: 64)
        connection.tailscaleAccountID = UUID().uuidString
        connection.transportRaw = transport.rawValue
        connection.useSOCKSProxy = true
        #expect(throws: ConnectionTransportError.conflictingSOCKSProxy) { try connection.validatedTransport() }
        connection.selectTransport(transport)
        #expect(connection.useSOCKSProxy == false)
        _ = try connection.validatedTransport()
    }

    @Test("Legacy SOCKS without a usable endpoint never falls back to direct")
    func invalidLegacyProxyFailsClosed() {
        var connection = ServerConnection(host: "server.internal")
        connection.useSOCKSProxy = true
        #expect(throws: ConnectionTransportError.invalidSOCKSHost) { try connection.validatedTransport() }
        connection.socksProxyHost = "127.0.0.1"
        connection.socksProxyPort = 65536
        #expect(throws: ConnectionTransportError.invalidSOCKSPort) { try connection.validatedTransport() }
    }

    @Test("Changing transport preserves the SSH trust identity and session mode", arguments: Multiplexer.allCases)
    func identityAndMultiplexerStaySeparate(multiplexer: Multiplexer) throws {
        var connection = cloudflareConnection()
        connection.tailcatCredentialRef = TailcatCredentials.newReference()
        connection.tailcatServerPublicKey = "nodekey:" + String(repeating: "1", count: 64)
        connection.tailscaleAccountID = UUID().uuidString
        connection.multiplexer = multiplexer
        let original = connection
        for transport in ConnectionTransport.allCases {
            connection.selectTransport(transport)
            #expect(connection.host == original.host)
            #expect(connection.port == original.port)
            #expect(connection.id == original.id)
            #expect(connection.multiplexer == multiplexer)
        }
        _ = try connection.validatedTransport()
    }

    @Test("Persisted Cloudflare plus Mosh is rejected before bootstrap")
    func cloudflareMoshRejected() {
        var connection = cloudflareConnection()
        connection.connectionProtocol = .mosh
        #expect(throws: ConnectionTransportError.cloudflareRequiresSSH) { try connection.validatedTransport() }
        #expect(connection.connectionProtocol == .mosh, "Validation must not silently mutate the saved protocol")
    }

    @Test("Each connection keeps its own Access application and normalizes only domain casing")
    func independentAccessSettings() throws {
        var first = cloudflareConnection()
        first.cloudflareHostname = " SSH.EXAMPLE.COM \n"
        first.cloudflareTeamDomain = " EXAMPLE-TEAM.CLOUDFLAREACCESS.COM "
        first.cloudflareAudience = " Aud_ABC-123 "
        var second = cloudflareConnection()
        second.cloudflareHostname = "ssh.other.example"
        second.cloudflareTeamDomain = "other-team.cloudflareaccess.com"
        second.cloudflareAudience = "Other_Application"
        #expect(try first.validatedTransport() == .cloudflare(.init(
            hostname: "ssh.example.com", teamDomain: "example-team.cloudflareaccess.com", audience: "Aud_ABC-123")))
        #expect(try first.validatedTransport() != second.validatedTransport())
        let restored = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(second))
        #expect(restored == second)
    }

    @Test("Cloudflare entry accepts a bare DNS hostname only", arguments: ["", "https://ssh.example.com", "ssh.example.com:443", "ssh.example.com/path", "user@ssh.example.com", "ssh..example.com", "-ssh.example.com", "ssh.example.com\r\nX-Test: injected"])
    func invalidCloudflareHostname(value: String) {
        var connection = cloudflareConnection()
        connection.cloudflareHostname = value
        #expect(throws: ConnectionTransportError.invalidCloudflareHostname) { try connection.validatedTransport() }
    }

    @Test("Access team must be an explicitly supported team domain", arguments: ["", "team", "cloudflareaccess.com", "team.cloudflareaccess.com.evil.example", "https://team.cloudflareaccess.com", "team.fed.cloudflareaccess.com"])
    func invalidAccessTeam(value: String) {
        var connection = cloudflareConnection()
        connection.cloudflareTeamDomain = value
        #expect(throws: ConnectionTransportError.invalidCloudflareTeamDomain) { try connection.validatedTransport() }
    }

    @Test("Audience is a single configured identifier", arguments: ["", " ", "aud one", "aud/one", "aud\r\nCookie: value", String(repeating: "a", count: 257)])
    func invalidAudience(value: String) {
        var connection = cloudflareConnection()
        connection.cloudflareAudience = value
        #expect(throws: ConnectionTransportError.invalidCloudflareAudience) { try connection.validatedTransport() }
    }

    @Test("Tailcat records persist public identity and opaque reference only")
    func tailcatPublicMetadata() throws {
        let publicKey = "nodekey:" + String(repeating: "a", count: 64)
        let ref = TailcatCredentials.newReference()
        var connection = ServerConnection(name: "Mac mini", host: "mac-mini", username: "alice")
        connection.selectTransport(.tailcat)
        connection.tailcatCredentialRef = ref
        connection.tailcatServerPublicKey = publicKey
        connection.multiplexer = .herdr
        connection.keychainRef = "separate-ssh-password"
        let data = try JSONEncoder().encode(connection)
        let restored = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(restored == connection)
        #expect(try restored.validatedTransport() == .tailcat(.init(credentialRef: ref, serverPublicKey: publicKey)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys.filter { $0.hasPrefix("tailcat") }) == ["tailcatCredentialRef", "tailcatServerPublicKey"])
        #expect(restored.keychainRef == "separate-ssh-password")
        #expect(restored.multiplexer == .herdr)
    }

    @Test("Tailcat cannot bootstrap Mosh or silently connect without device credentials")
    func tailcatFailsClosed() throws {
        var connection = ServerConnection(host: "mac-mini")
        connection.selectTransport(.tailcat)
        #expect(throws: ConnectionTransportError.invalidTailcatConfiguration) { try connection.validatedTransport() }
        connection.tailcatCredentialRef = TailcatCredentials.newReference()
        connection.tailcatServerPublicKey = "nodekey:" + String(repeating: "1", count: 64)
        connection.connectionProtocol = .mosh
        #expect(throws: ConnectionTransportError.tailcatRequiresSSH) { try connection.validatedTransport() }
        #expect(connection.connectionProtocol == .mosh)
    }

    @Test("Tailcat host trust identity follows server public key across aliases and separates different servers")
    func tailcatTrustIdentity() throws {
        let key = "nodekey:" + String(repeating: "a", count: 64)
        let first = try TailcatConnectionSettings.validated(credentialRef: TailcatCredentials.newReference(), serverPublicKey: key)
        let edited = try TailcatConnectionSettings.validated(credentialRef: TailcatCredentials.newReference(), serverPublicKey: key)
        let other = try TailcatConnectionSettings.validated(credentialRef: TailcatCredentials.newReference(),
                                                          serverPublicKey: "nodekey:" + String(repeating: "b", count: 64))
        #expect(first.hostKeyIdentity == edited.hostKeyIdentity)
        #expect(first.hostKeyIdentity != other.hostKeyIdentity)
        #expect(first.hostKeyIdentity == "tailcat-" + String(repeating: "a", count: 64) + ".invalid")
    }

    @Test("Tailcat public metadata rejects malformed or private identity fields", arguments: ["", "nodekey:123", "privkey:" + String(repeating: "a", count: 64), "nodekey:" + String(repeating: "0", count: 64), "nodekey:" + String(repeating: "G", count: 64)])
    func invalidTailcatPublicKey(value: String) {
        #expect(throws: ConnectionTransportError.invalidTailcatConfiguration) {
            try TailcatConnectionSettings.validated(credentialRef: TailcatCredentials.newReference(), serverPublicKey: value)
        }
    }

    @Test("Tailscale records persist account and peer binding without changing SSH authentication")
    func tailscaleMetadataRoundTrip() throws {
        var connection = ServerConnection(host: "mac.tail-test.ts.net", username: "alice", keychainRef: "ssh-key",
                                          tailscaleAccountID: UUID().uuidString, tailscalePeerID: "n123example")
        connection.selectTransport(.tailscale)
        connection.multiplexer = .herdr
        let data = try JSONEncoder().encode(connection)
        let restored = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(restored == connection)
        #expect(try restored.validatedTransport() == .tailscale(.init(accountID: connection.tailscaleAccountID!, peerID: "n123example")))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys.filter { $0.hasPrefix("tailscale") }) == ["tailscaleAccountID", "tailscalePeerID"])
        #expect(restored.keychainRef == "ssh-key")
        #expect(restored.multiplexer == .herdr)
    }

    @Test("Tailscale fails closed without account binding and never bootstraps Mosh")
    func tailscaleRequiresBoundAccountAndSSH() throws {
        var connection = ServerConnection(host: "100.64.0.10")
        connection.selectTransport(.tailscale)
        #expect(throws: ConnectionTransportError.invalidTailscaleConfiguration) { try connection.validatedTransport() }
        connection.tailscaleAccountID = UUID().uuidString
        #expect(try connection.validatedTransport() == .tailscale(.init(accountID: connection.tailscaleAccountID!, peerID: nil)))
        connection.connectionProtocol = .mosh
        #expect(throws: ConnectionTransportError.tailscaleRequiresSSH) { try connection.validatedTransport() }
        #expect(connection.connectionProtocol == .mosh)
        #expect(ConnectionTransport.tailscale.requiresSSH)
    }

    @Test("Tailscale account metadata rejects credentials and malformed identifiers", arguments: ["", " tskey-auth-example", "privkey:abc", "example@domain.com", "\u{0}"])
    func tailscaleInvalidAccount(_ value: String) {
        #expect(throws: ConnectionTransportError.invalidTailscaleConfiguration) {
            try TailscaleConnectionSettings.validated(accountID: value, peerID: nil)
        }
    }

    @Test("Tailscale peer metadata rejects URL or credential payloads", arguments: ["", "peer name", "https://host", "node\nvalue", "\u{0}", String(repeating: "a", count: 129)])
    func tailscaleInvalidPeer(_ value: String) {
        #expect(throws: ConnectionTransportError.invalidTailscaleConfiguration) {
            try TailscaleConnectionSettings.validated(accountID: UUID().uuidString, peerID: value)
        }
    }

    @Test("Tailscale metadata never selects a route for legacy direct connections")
    func tailscaleDoesNotChangeDirectRouting() throws {
        var connection = ServerConnection(host: "100.64.0.2", tailscaleAccountID: UUID().uuidString, tailscalePeerID: "n123")
        #expect(try connection.validatedTransport() == .direct)
        connection.useTailscale = true
        #expect(try connection.validatedTransport() == .direct)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any])
        json.removeValue(forKey: "tailscaleAccountID")
        json.removeValue(forKey: "tailscalePeerID")
        let legacy = try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.tailscaleAccountID == nil)
        #expect(legacy.tailscalePeerID == nil)
        #expect(try legacy.validatedTransport() == .direct)
    }
}
