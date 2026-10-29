import Foundation
import Testing
@testable import CloudflareAccess

/// Explicit opt-in: all environment values are public application configuration.
/// This exercises only anonymous metadata/JWKS requests, never login or SSH.
@Suite("Cloudflare Access live application discovery")
struct AccessDiscoveryLiveTests {
    private static let enabled = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_DISCOVERY_HOSTNAME"] != nil

    @Test("A real hostname discovers the expected signed application scope", .enabled(if: enabled))
    func hostnameOnlyDiscovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let hostname = try #require(environment["MOSHPIT_CF_LIVE_DISCOVERY_HOSTNAME"])
        let expectedTeam = try #require(environment["MOSHPIT_CF_LIVE_DISCOVERY_TEAM_DOMAIN"])
        let expectedAudience = try #require(environment["MOSHPIT_CF_LIVE_DISCOVERY_AUDIENCE"])
        let expected = try AccessApplication(hostname: hostname, audience: expectedAudience, teamDomain: expectedTeam)

        let discovered: AccessApplication
        do {
            discovered = try await AccessApplicationDiscovery.discover(
                hostname: hostname, using: URLSessionAccessHTTPClient())
        } catch let error as AccessError {
            // AccessError descriptions contain no JWT, request headers, or body.
            Issue.record("Live anonymous discovery failed: \(error.localizedDescription)")
            return
        } catch is CancellationError {
            Issue.record("Live anonymous discovery was cancelled.")
            return
        } catch {
            Issue.record("Live anonymous discovery failed with an unexpected error category.")
            return
        }

        // Report only equality results, never metadata JWTs or key material.
        let hostnameMatches = discovered.hostname == expected.hostname
        let teamMatches = discovered.teamDomain == expected.teamDomain
        let audienceMatches = discovered.audience == expected.audience
        #expect(hostnameMatches)
        #expect(teamMatches)
        #expect(audienceMatches)
    }
}
