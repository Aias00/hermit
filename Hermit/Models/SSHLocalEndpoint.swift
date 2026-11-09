import Foundation
import Darwin
import TailscaleSSH

/// Public endpoint metadata only. Restrict automatic LAN attempts to private
/// literals: DNS and Internet destinations should use an explicit transport.
struct SSHLocalEndpoint: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var host = ""
    var port = 22

    var isValid: Bool {
        guard (1...65535).contains(port) else { return false }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let address = UInt32(bigEndian: v4.s_addr)
            return address >> 24 == 10 || address >> 20 == 0xAC1
                || address >> 16 == 0xC0A8
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            // Unique-local IPv6; link-local addresses require an interface
            // scope and must not silently choose the wrong interface.
            return withUnsafeBytes(of: &v6) { $0[0] & 0xFE == 0xFC }
        }
        return false
    }
}

extension ServerConnection {
    var usesAutomaticLocalRouting: Bool { preferLocalNetwork == true && transport == .tailscale }

    func validatedLocalEndpoints() throws -> [SSHLocalEndpoint] {
        guard preferLocalNetwork == true else { return [] }
        guard transport == .tailscale, connectionProtocol == .ssh,
              let localEndpoints, (1...4).contains(localEndpoints.count),
              localEndpoints.allSatisfy(\.isValid),
              Set(localEndpoints.map { "\($0.host.lowercased()):\($0.port)" }).count == localEndpoints.count else {
            throw ConnectionTransportError.invalidLocalEndpoint
        }
        return localEndpoints
    }

    /// Reuse the existing Tailscale trust entry across all of this server's
    /// LAN addresses, including different ports. Never trust a LAN IP alone.
    func automaticRouteTrustIdentity() throws -> String? {
        guard usesAutomaticLocalRouting else { return nil }
        let settings = try TailscaleConnectionSettings.validated(accountID: tailscaleAccountID, peerID: tailscalePeerID)
        let normalized = try TailscaleSSHDialer.normalizedHost(host)
        let identity = settings.peerID.map { "peer:" + $0 } ?? "host:" + normalized
        return "tailscale:" + settings.accountID + ":" + identity
    }

    func routeCandidates() throws -> [ServerConnection] {
        guard preferLocalNetwork == true else { return [self] }
        _ = try validatedTransport()
        let local = try validatedLocalEndpoints()
        return local.map { endpoint in
            var candidate = self
            candidate.host = endpoint.host
            candidate.port = endpoint.port
            candidate.sshPort = endpoint.port
            candidate.selectTransport(.direct)
            candidate.preferLocalNetwork = false
            return candidate
        } + [self]
    }
}

/// Only a failed TCP connection to a configured LAN candidate permits moving
/// to the next address. Trust rejection, credentials and SSH auth stop here.
struct LocalSSHRouteUnavailable: Error {}

enum SSHRouteSelection {
    static func connect<Value>(_ connection: ServerConnection,
                               attempt: (ServerConnection, Bool) async throws -> Value) async throws -> Value {
        let candidates = try connection.routeCandidates()
        for candidate in candidates {
            try Task.checkCancellation()
            let local = connection.usesAutomaticLocalRouting && candidate.transport == .direct
            do { return try await attempt(candidate, local) }
            catch is LocalSSHRouteUnavailable where local {
                try Task.checkCancellation()
                // No SSH credential has crossed this failed TCP connection.
            }
        }
        // The final Tailscale attempt always returns or throws its own cause.
        throw SSHError.connectionFailed
    }
}
