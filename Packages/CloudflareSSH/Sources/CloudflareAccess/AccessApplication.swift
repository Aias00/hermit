import Foundation

/// Explicit, trusted configuration for one Access application. These are not
/// inferred from an unverified redirect or from the contents of a user token.
public struct AccessApplication: Equatable, Sendable, Codable {
    public let hostname: String
    public let audience: String
    public let teamDomain: String

    public init(hostname: String, audience: String, teamDomain: String) throws {
        guard Self.isHostname(hostname), Self.isHostname(teamDomain),
              teamDomain.lowercased().hasSuffix(".cloudflareaccess.com"),
              !teamDomain.lowercased().hasSuffix(".fed.cloudflareaccess.com"),
              !audience.isEmpty, audience.utf8.count <= 256,
              audience.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw AccessError.invalidApplication
        }
        self.hostname = hostname.lowercased()
        self.audience = audience
        self.teamDomain = teamDomain.lowercased()
    }

    private enum CodingKeys: CodingKey { case hostname, audience, teamDomain }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hostname: values.decode(String.self, forKey: .hostname),
                      audience: values.decode(String.self, forKey: .audience),
                      teamDomain: values.decode(String.self, forKey: .teamDomain))
    }

    public var applicationURL: URL { URL(string: "https://" + hostname)! }
    public var issuer: String { "https://" + teamDomain }
    public var certificatesURL: URL { URL(string: issuer + "/cdn-cgi/access/certs")! }

    private static func isHostname(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains("."), value.utf8.allSatisfy({ $0 < 128 }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

/// Errors intentionally contain no request URL, HTTP body, cookie, or token.
public enum AccessError: Error, Equatable, LocalizedError, Sendable {
    case invalidApplication, invalidToken, invalidSignature, invalidClaims
    case expiredToken, wrongAudience, wrongIssuer, userIdentityRequired
    case invalidMetadata, invalidPublicKey, invalidTransfer, decryptionFailed
    case keyGenerationFailed, transferAlreadyUsed, deadlineExceeded
    case networkFailure, responseTooLarge, unexpectedResponse, httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: return "Invalid or unsupported Access application configuration."
        case .invalidToken: return "Access returned an invalid token."
        case .invalidSignature: return "Access token signature verification failed."
        case .invalidClaims: return "Access token claims are invalid."
        case .expiredToken: return "The Access session has expired."
        case .wrongAudience: return "The Access token belongs to another application."
        case .wrongIssuer: return "The Access token belongs to another team."
        case .userIdentityRequired: return "An interactive Access user identity is required."
        case .invalidMetadata: return "Access application metadata verification failed."
        case .invalidPublicKey: return "Access returned an invalid transfer public key."
        case .invalidTransfer: return "Access returned an invalid transfer response."
        case .decryptionFailed: return "Access credential transfer authentication failed."
        case .keyGenerationFailed: return "Could not create an ephemeral login key."
        case .transferAlreadyUsed: return "This login attempt has already completed or been cancelled."
        case .deadlineExceeded: return "Access login timed out."
        case .networkFailure: return "Could not reach the Access login service."
        case .responseTooLarge: return "Access returned an oversized response."
        case .unexpectedResponse: return "Access returned an unexpected response."
        case .httpStatus(let status): return "Access login failed with HTTP status \(status)."
        }
    }
}

public struct AccessIdentity: Equatable, Sendable, Codable {
    public let subject: String
    public let email: String?
    public let issuer: String
    public let audiences: [String]
    public let expiresAt: Date
}

/// Secret-bearing values have deliberately redacted descriptions. Store only in
/// Keychain; the application and validated subject form part of the cache key.
public struct AccessCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let application: AccessApplication
    public let applicationToken: String
    public let identity: AccessIdentity
    public let organizationToken: String?
    public let organizationExpiresAt: Date?
    public var description: String { "<AccessCredentials redacted>" }
    public var debugDescription: String { description }
}

enum AccessBase64 {
    static func encodeURL(_ data: Data, padded: Bool = false) -> String {
        let result = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return padded ? result : result.replacingOccurrences(of: "=", with: "")
    }

    static func decodeURL(_ string: String) -> Data? {
        guard !string.isEmpty, string.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 61
        }) else { return nil }
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if normalized.count % 4 != 0 { normalized += String(repeating: "=", count: 4 - normalized.count % 4) }
        return Data(base64Encoded: normalized)
    }
}
