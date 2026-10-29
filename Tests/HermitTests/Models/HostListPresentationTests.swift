import Foundation
import Testing
@testable import Moshpit

@Suite("Host list search and presentation")
struct HostListPresentationTests {
    private let production = ServerConnection(name: "Déploy Mini", host: "prod.example.net", port: 2222, username: "alice")
    private let staging = ServerConnection(name: "Staging", host: "100.64.0.8", username: "builder")

    @Test("empty and whitespace queries preserve saved order and identity")
    func emptyQuery() {
        let hosts = [staging, production]
        #expect(HostListPresentation.filtered(hosts, query: "") == hosts)
        #expect(HostListPresentation.filtered(hosts, query: " \n\t ") == hosts)
    }

    @Test("aliases, usernames, addresses and ports can be combined without case or accent sensitivity")
    func publicIdentitySearch() {
        let hosts = [staging, production]
        for query in ["DEPLOY", "ALICE", "prod.example", "alice@prod.example.net:2222", "deploy alice SSH", "  mini\n2222  "] {
            #expect(HostListPresentation.filtered(hosts, query: query) == [production], "Query: \(query)")
        }
        #expect(HostListPresentation.filtered(hosts, query: "deploy builder").isEmpty)
        #expect(HostListPresentation.filtered(hosts, query: "missing").isEmpty)
    }

    @Test("all selected transports and remote session modes are searchable")
    func routeSearch() {
        for route in ConnectionTransport.allCases {
            var host = production
            host.selectTransport(route)
            #expect(HostListPresentation.filtered([host], query: route.rawValue) == [host])
            #expect(HostListPresentation.filtered([host], query: HostListPresentation.routeLabel(for: host)) == [host])
        }
        var host = staging
        host.connectionProtocol = .mosh
        host.multiplexer = .herdr
        #expect(HostListPresentation.filtered([production, host], query: "mosh herdr") == [host])
        #expect(HostListPresentation.sessionLabel(for: host) == "Mosh · herdr")
    }

    @Test("only active Cloudflare endpoints match and credentials never become search fields")
    func routeMetadataPrivacy() {
        var host = production
        host.cloudflareHostname = "access.example.org"
        host.cloudflareTeamDomain = "private-team.cloudflareaccess.com"
        host.cloudflareAudience = "audience-marker"
        host.keychainRef = "secret-reference-marker"
        host.tailcatCredentialRef = "tailcat-credential-marker"
        host.tailcatServerPublicKey = "nodekey:private-marker"
        host.tailscaleAccountID = "account-marker"
        #expect(HostListPresentation.filtered([host], query: "access.example.org").isEmpty)
        host.selectTransport(.cloudflareSSH)
        #expect(HostListPresentation.filtered([host], query: "access.example.org") == [host])
        for query in ["private-team", "audience-marker", "secret-reference", "tailcat-credential", "private-marker", "account-marker"] {
            #expect(HostListPresentation.filtered([host], query: query).isEmpty, "Query: \(query)")
        }
    }

    @Test("endpoint identifies username, nondefault port and IPv6 without ambiguity")
    func endpointPresentation() {
        #expect(HostListPresentation.endpoint(for: production) == "alice@prod.example.net:2222")
        #expect(HostListPresentation.endpoint(for: staging) == "builder@100.64.0.8")
        var ipv6 = staging
        ipv6.host = "2001:db8::1"
        ipv6.port = 2200
        #expect(HostListPresentation.endpoint(for: ipv6) == "builder@[2001:db8::1]:2200")
        ipv6.host = "[2001:db8::1]"
        #expect(HostListPresentation.endpoint(for: ipv6) == "builder@[2001:db8::1]:2200")
        ipv6.username = ""
        #expect(HostListPresentation.endpoint(for: ipv6) == "[2001:db8::1]:2200")
    }

    @Test("legacy SOCKS and unknown routes are not mislabeled as direct")
    func legacyAndUnknownRoutes() {
        var host = staging
        host.useSOCKSProxy = true
        #expect(HostListPresentation.filtered([host], query: "socks5") == [host])
        #expect(HostListPresentation.filtered([host], query: "direct").isEmpty)
        host.transportRaw = "future-route"
        #expect(HostListPresentation.routeLabel(for: host) == String(localized: "Unknown transport"))
        #expect(HostListPresentation.filtered([host], query: "direct").isEmpty)
    }
}
