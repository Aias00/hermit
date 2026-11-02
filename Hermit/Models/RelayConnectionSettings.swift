import CryptoKit
import Foundation
import RemoteForgeRelay

/// Public routing metadata plus an opaque local Keychain reference. The
/// capability token and invitation never belong in ServerConnection JSON.
struct RelayConnectionSettings: Equatable, Hashable, Sendable {
    let server: String
    let deviceID: String
    let service: String
    let credentialRef: String

    var hostKeyIdentity: String {
        let scope = server + "\n" + deviceID + "\n" + service
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return "relay-" + digest + ".invalid"
    }
    static func validated(server: String?, deviceID: String?, service: String?, credentialRef: String?) throws -> Self {
        guard let server, let deviceID, let service, let credentialRef,
              validID(deviceID), validID(service), RelayCredentials.isReference(credentialRef) else {
            throw ConnectionTransportError.invalidRelayConfiguration
        }
        return Self(server: try canonicalServer(server), deviceID: deviceID, service: service, credentialRef: credentialRef)
    }
    static func paired(_ credential: RelayCredential, ref: String) throws -> Self {
        try validated(server: credential.endpoint.url.absoluteString, deviceID: credential.device,
                      service: credential.service, credentialRef: ref)
    }
    func matches(_ credential: RelayCredential) -> Bool {
        (try? Self.canonicalServer(credential.endpoint.url.absoluteString)) == server
            && credential.device == deviceID && credential.service == service
    }
    static func canonicalServer(_ value: String) throws -> String {
        guard value.utf8.count <= 2048, let url = URL(string: value),
              let endpoint = try? RelayEndpoint(url, allowInsecureLoopback: RelayRuntimePolicy.allowsInsecureLoopback),
              var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            throw ConnectionTransportError.invalidRelayConfiguration
        }
        components.host = components.host?.lowercased()
        if components.scheme == "https", components.port == 443 { components.port = nil }
        guard let canonical = components.url?.absoluteString else {
            throw ConnectionTransportError.invalidRelayConfiguration
        }
        return canonical
    }
    private static func validID(_ value: String) -> Bool {
        let chars = value.utf8
        func alphaNumeric(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...122).contains(c) }
        return (1...64).contains(chars.count) && chars.first.map(alphaNumeric) == true
            && chars.allSatisfy { alphaNumeric($0) || $0 == 45 }
    }
}
