import Foundation
import Security

/// RS256 verification is mandatory before identity, expiry, or application
/// claims are used. JWKS must come from the configured team's HTTPS endpoint.
public enum AccessJWTValidator {
    private struct Header: Decodable {
        let alg: String
        let kid: String
        let crit: [String]?
    }
    private struct KeySet: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kty: String
        let kid: String
        let n: String
        let e: String
        let alg: String?
        let use: String?
    }
    private struct Claims: Decodable {
        let aud: [String]
        let iss: String
        let exp: Int64
        let nbf: Int64?
        let iat: Int64?
        let type: String
        let sub: String
        let email: String?

        enum CodingKeys: CodingKey { case aud, iss, exp, nbf, iat, type, sub, email }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let single = try? values.decode(String.self, forKey: .aud) { aud = [single] }
            else { aud = try values.decode([String].self, forKey: .aud) }
            iss = try values.decode(String.self, forKey: .iss)
            exp = try values.decode(Int64.self, forKey: .exp)
            nbf = try values.decodeIfPresent(Int64.self, forKey: .nbf)
            iat = try values.decodeIfPresent(Int64.self, forKey: .iat)
            type = try values.decode(String.self, forKey: .type)
            sub = try values.decode(String.self, forKey: .sub)
            email = try values.decodeIfPresent(String.self, forKey: .email)
        }
    }

    public static func validateApplicationToken(_ token: String, jwks: Data,
                                                application: AccessApplication,
                                                now: Date = Date()) throws -> AccessIdentity {
        let claims = try validatedClaims(token, jwks: jwks, issuer: application.issuer, type: "app", now: now)
        guard claims.aud.contains(application.audience) else { throw AccessError.wrongAudience }
        return identity(claims)
    }

    /// Revalidate persisted credentials against the configured scope and fresh
    /// signing keys. Decoded identity fields are never trusted as authorization.
    /// Edge rejection remains authoritative for revocation of an unexpired JWT.
    public static func validateCredentials(_ credentials: AccessCredentials,
                                            for application: AccessApplication,
                                            using client: any AccessHTTPClient = URLSessionAccessHTTPClient(),
                                            now: Date = Date()) async throws -> AccessCredentials {
        guard credentials.application == application else { throw AccessError.invalidApplication }
        let jwks = try await AccessApplicationDiscovery.fetchKeys(for: application, using: client)
        let identity = try validateApplicationToken(credentials.applicationToken, jwks: jwks, application: application, now: now)
        guard credentials.identity.subject == identity.subject else { throw AccessError.invalidClaims }
        // Org-token refresh is deliberately outside this P0. An independently
        // expired SSO token does not invalidate an otherwise live app token.
        return AccessCredentials(application: application, applicationToken: credentials.applicationToken,
                                 identity: identity, organizationToken: nil, organizationExpiresAt: nil)
    }

    static func validateOrganizationToken(_ token: String, jwks: Data,
                                          application: AccessApplication, subject: String,
                                          now: Date) throws -> AccessIdentity {
        let claims = try validatedClaims(token, jwks: jwks, issuer: application.issuer, type: "org", now: now)
        guard claims.sub == subject else { throw AccessError.invalidClaims }
        // An org token is an SSO credential, not an application credential.
        // Its audience is never substituted for the selected application's AUD.
        return identity(claims)
    }

    private static func identity(_ claims: Claims) -> AccessIdentity {
        AccessIdentity(subject: claims.sub, email: claims.email, issuer: claims.iss,
                       audiences: claims.aud, expiresAt: Date(timeIntervalSince1970: TimeInterval(claims.exp)))
    }

    private static func validatedClaims(_ token: String, jwks: Data, issuer: String,
                                        type: String, now: Date) throws -> Claims {
        let payload = try verifiedPayload(token, jwks: jwks)
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { throw AccessError.invalidClaims }
        guard claims.iss == issuer else { throw AccessError.wrongIssuer }
        guard claims.type == type else { throw AccessError.invalidClaims }
        guard !claims.sub.isEmpty else { throw AccessError.userIdentityRequired }
        let timestamp = now.timeIntervalSince1970
        guard TimeInterval(claims.exp) > timestamp else { throw AccessError.expiredToken }
        if let nbf = claims.nbf, TimeInterval(nbf) > timestamp + 30 { throw AccessError.invalidClaims }
        if let iat = claims.iat, TimeInterval(iat) > timestamp + 30 { throw AccessError.invalidClaims }
        guard !claims.aud.isEmpty, claims.aud.allSatisfy({ !$0.isEmpty }) else { throw AccessError.invalidClaims }
        return claims
    }

    static func verifiedPayload(_ token: String, jwks: Data) throws -> Data {
        guard token.utf8.count <= 64 * 1024, jwks.count <= 1024 * 1024 else { throw AccessError.responseTooLarge }
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let headerData = AccessBase64.decodeURL(String(components[0])),
              let payload = AccessBase64.decodeURL(String(components[1])),
              let signature = AccessBase64.decodeURL(String(components[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "RS256", !header.kid.isEmpty,
              header.crit?.isEmpty != false,
              let keySet = try? JSONDecoder().decode(KeySet.self, from: jwks) else { throw AccessError.invalidToken }
        let keys = keySet.keys.filter { $0.kid == header.kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }
        guard keys.count == 1, let key = keys.first,
              let modulus = AccessBase64.decodeURL(key.n),
              let exponent = AccessBase64.decodeURL(key.e),
              modulus.count >= 256, modulus.count <= 1024,
              !exponent.isEmpty, exponent.count <= 8 else { throw AccessError.invalidSignature }
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { throw AccessError.invalidSignature }
        let input = Data((components[0] + "." + components[1]).utf8)
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    input as CFData, signature as CFData, nil) else { throw AccessError.invalidSignature }
        return payload
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes.append(0) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + bytes
    }
    private static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
}

/// Signed application discovery following cloudflared 2026.10.3 GetAppInfo.
/// An unverified team domain is used only to locate Cloudflare's signing keys;
/// no application configuration is returned until its metadata is verified.
public enum AccessApplicationDiscovery {
    private static let maximumMetadataBytes = 64 * 1024
    private struct KeyDomain: Decodable { let auth_domain: String }
    private struct Metadata: Decodable {
        let type: String
        let hostname: String
        let auth_domain: String
        let aud: String
        let iat: Int64
    }

    public static func discover(hostname: String,
                                 using client: any AccessHTTPClient = URLSessionAccessHTTPClient(),
                                 now: Date = Date()) async throws -> AccessApplication {
        try await discover(hostname: hostname, pinnedTeamDomain: nil, using: client, now: now)
    }

    /// Retains explicit team pinning for existing configurations. A signed
    /// response from another team cannot replace the caller's configured team.
    public static func discover(hostname: String, teamDomain: String,
                                 using client: any AccessHTTPClient,
                                 now: Date = Date()) async throws -> AccessApplication {
        let provisional = try AccessApplication(hostname: hostname, audience: "discovery", teamDomain: teamDomain)
        return try await discover(hostname: provisional.hostname, pinnedTeamDomain: provisional.teamDomain,
                                  using: client, now: now)
    }

    private static func discover(hostname: String, pinnedTeamDomain: String?,
                                  using client: any AccessHTTPClient,
                                  now: Date) async throws -> AccessApplication {
        // This placeholder only reuses hostname validation/URL construction;
        // it is never queried, cached, or returned as a discovered authority.
        let provisional = try AccessApplication(hostname: hostname, audience: "discovery",
                                                teamDomain: pinnedTeamDomain ?? "discovery.cloudflareaccess.com")
        // URLSession canonicalizes an empty HTTP path to "/" in its response.
        // Start canonical so the client's exact no-redirect URL check still holds.
        var request = URLRequest(url: provisional.applicationURL.appendingPathComponent(""))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 7
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AccessRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "Cf-Access-Metadata-Request")
        let response = try await client.send(request, maximumResponseBytes: maximumMetadataBytes)
        guard response.headers.count <= 100, response.body.count <= maximumMetadataBytes,
              response.headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= maximumMetadataBytes else {
            throw AccessError.responseTooLarge
        }
        guard response.url == request.url,
              let rawJWT = response.headers["cf-access-metadata"] else { throw AccessError.invalidMetadata }

        // Exactly one compact JWT is accepted. In particular, combined duplicate
        // HTTP header values must not select one of several possible authorities.
        let components = rawJWT.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }), let unverifiedPayload = AccessBase64.decodeURL(String(components[1])),
              let keyDomain = try? JSONDecoder().decode(KeyDomain.self, from: unverifiedPayload),
              let candidateTeam = standardTeamDomain(keyDomain.auth_domain),
              pinnedTeamDomain == nil || pinnedTeamDomain == candidateTeam else { throw AccessError.invalidMetadata }

        // The candidate can only choose an HTTPS /cdn-cgi/access/certs endpoint
        // on the supported Cloudflare team namespace. Other claims remain unused.
        let keyLocation = try AccessApplication(hostname: provisional.hostname, audience: "discovery", teamDomain: candidateTeam)
        let jwks = try await fetchKeys(for: keyLocation, using: client)
        let payload = try AccessJWTValidator.verifiedPayload(rawJWT, jwks: jwks)
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: payload),
              metadata.type == "match", metadata.hostname.lowercased() == provisional.hostname,
              standardTeamDomain(metadata.auth_domain) == candidateTeam,
              !metadata.aud.isEmpty, metadata.aud.utf8.count <= 256,
              metadata.aud.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }),
              metadata.iat > 0, TimeInterval(metadata.iat) >= now.timeIntervalSince1970 - 86400,
              TimeInterval(metadata.iat) <= now.timeIntervalSince1970 + 300 else { throw AccessError.invalidMetadata }
        return try AccessApplication(hostname: provisional.hostname, audience: metadata.aud, teamDomain: candidateTeam)
    }

    private static func standardTeamDomain(_ value: String) -> String? {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 3, labels[1].lowercased() == "cloudflareaccess", labels[2].lowercased() == "com",
              let team = labels.first, !team.isEmpty, team.utf8.count <= 63,
              team.first != "-", team.last != "-",
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            return nil
        }
        return value.lowercased()
    }

    static func fetchKeys(for application: AccessApplication, using client: any AccessHTTPClient) async throws -> Data {
        var request = URLRequest(url: application.certificatesURL)
        request.timeoutInterval = 10
        request.setValue(AccessRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        let response = try await client.send(request, maximumResponseBytes: 1024 * 1024)
        guard response.url == request.url else { throw AccessError.unexpectedResponse }
        guard response.statusCode == 200 else { throw AccessError.httpStatus(response.statusCode) }
        guard response.body.count <= 1024 * 1024 else { throw AccessError.responseTooLarge }
        return response.body
    }
}
