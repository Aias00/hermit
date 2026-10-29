import Foundation
import Security
import Sodium
import Testing
@testable import CloudflareAccess

private struct SignedTokens: @unchecked Sendable {
    let privateKey: SecKey
    let jwks: Data

    init() throws {
        privateKey = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 1
        func readLength() -> Int {
            let first = Int(der[offset]); offset += 1
            if first < 128 { return first }
            var value = 0
            for _ in 0..<(first & 0x7f) { value = value * 256 + Int(der[offset]); offset += 1 }
            return value
        }
        _ = readLength()
        func readInteger() -> Data {
            offset += 1
            let count = readLength()
            let bytes = Data(der[offset..<(offset + count)]).drop(while: { $0 == 0 })
            offset += count
            return Data(bytes)
        }
        let n = readInteger(), e = readInteger()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "kid": "synthetic-test-key", "use": "sig", "alg": "RS256",
            "n": AccessBase64.encodeURL(n), "e": AccessBase64.encodeURL(e),
        ]]])
    }

    func sign(_ payload: [String: Any], header: [String: Any]? = nil) throws -> String {
        let encodedHeader = AccessBase64.encodeURL(try JSONSerialization.data(withJSONObject:
            header ?? ["alg": "RS256", "kid": "synthetic-test-key", "typ": "JWT"]))
        let encodedPayload = AccessBase64.encodeURL(try JSONSerialization.data(withJSONObject: payload))
        let message = encodedHeader + "." + encodedPayload
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                          Data(message.utf8) as CFData, nil)) as Data
        return message + "." + AccessBase64.encodeURL(signature)
    }

    func payload(audience: Any = ["app-audience"], issuer: String = "https://test.cloudflareaccess.com",
                 expires: Int64 = Int64(Date().timeIntervalSince1970) + 3600,
                 subject: String = "synthetic-user", type: String = "app") -> [String: Any] {
        ["aud": audience, "iss": issuer, "exp": expires, "iat": Int64(Date().timeIntervalSince1970) - 5,
         "nbf": Int64(Date().timeIntervalSince1970) - 5, "sub": subject, "type": type, "email": "tester@example.invalid"]
    }
}

private struct StubHTTP: AccessHTTPClient {
    let response: @Sendable (URLRequest) async throws -> AccessHTTPResponse
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccessHTTPResponse { try await response(request) }
}

private actor SleepingHTTP: AccessHTTPClient {
    var entered = false
    var cancelled = false
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccessHTTPResponse {
        entered = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true; throw error }
        return AccessHTTPResponse(url: request.url!, statusCode: 404)
    }
}

@Suite("Cloudflare Access transfer")
struct AccessTransferTests {
    private func application() throws -> AccessApplication {
        try AccessApplication(hostname: "ssh.example.com", audience: "app-audience", teamDomain: "test.cloudflareaccess.com")
    }

    @Test("Application scope rejects URLs, foreign issuers, and empty audiences")
    func scopeValidation() throws {
        for host in ["https://ssh.example.com", "ssh.example.com@evil.test", "ssh.example.com/path", "ssh.example.com:443", ".example.com", "a..example.com"] {
            #expect(throws: AccessError.invalidApplication) {
                try AccessApplication(hostname: host, audience: "aud", teamDomain: "test.cloudflareaccess.com")
            }
        }
        #expect(throws: AccessError.invalidApplication) {
            try AccessApplication(hostname: "ssh.example.com", audience: "aud", teamDomain: "test.cloudflareaccess.com.evil.test")
        }
        #expect(throws: AccessError.invalidApplication) {
            try AccessApplication(hostname: "ssh.example.com", audience: "", teamDomain: "test.cloudflareaccess.com")
        }
        let json = Data(#"{"hostname":"https://invalid.example","audience":"aud","teamDomain":"test.cloudflareaccess.com"}"#.utf8)
        #expect(throws: AccessError.invalidApplication) { try JSONDecoder().decode(AccessApplication.self, from: json) }
    }

    @Test("Login URL follows the pinned CLI transfer format and keys are fresh")
    func browserURLFormat() throws {
        let first = try AccessLoginTransfer(application: application())
        let second = try AccessLoginTransfer(application: application())
        let components = try #require(URLComponents(url: first.browserURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        #expect(components.scheme == "https")
        #expect(components.host == "ssh.example.com")
        #expect(components.path == "/cdn-cgi/access/cli")
        #expect(query["aud"] == "app-audience")
        #expect(query["send_org_token"] == "true")
        #expect(query["edge_token_transfer"] == "true")
        #expect(AccessBase64.decodeURL(query["token"]!)?.count == 32)
        #expect(query["token"]!.hasSuffix("="))
        let redirected = URLComponents(string: query["redirect_url"]!)!
        #expect(redirected.host == components.host)
        #expect(redirected.queryItems?.first(where: { $0.name == "token" })?.value == query["token"])
        #expect(first.browserURL != second.browserURL)
    }

    @Test("A real NaCl envelope is decrypted and both user tokens are signed and scoped")
    func encryptedTransfer() async throws {
        let app = try application(), signer = try SignedTokens()
        let appToken = try signer.sign(signer.payload())
        let orgToken = try signer.sign(signer.payload(audience: "org-audience", type: "org"))
        let transfer = try AccessLoginTransfer(application: app)
        let client = StubHTTP { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Moshpit-Access-P0/1 cloudflared-compatible/2026.10.3")
            if request.url == app.certificatesURL {
                return AccessHTTPResponse(url: request.url!, statusCode: 200, body: signer.jwks)
            }
            #expect(request.url?.host == "login.cloudflareaccess.org")
            let recipient = try #require(AccessBase64.decodeURL(request.url!.lastPathComponent))
            let peer = try #require(Sodium().box.keyPair())
            let plaintext = try JSONSerialization.data(withJSONObject: ["app_token": appToken, "org_token": orgToken])
            let encrypted: [UInt8] = try #require(Sodium().box.seal(message: Array(plaintext), recipientPublicKey: Array(recipient), senderSecretKey: peer.secretKey))
            return AccessHTTPResponse(url: request.url!, statusCode: 200,
                headers: ["Service-Public-Key": AccessBase64.encodeURL(Data(peer.publicKey), padded: true)],
                body: Data(Data(encrypted).base64EncodedString().utf8))
        }
        let credentials = try await transfer.poll(using: client)
        #expect(credentials.application == app)
        #expect(credentials.applicationToken == appToken)
        #expect(credentials.organizationToken == orgToken)
        #expect(credentials.identity.subject == "synthetic-user")
        #expect(!String(describing: credentials).contains(appToken))
        let restored = try JSONDecoder().decode(AccessCredentials.self, from: JSONEncoder().encode(credentials))
        let validated = try await AccessJWTValidator.validateCredentials(restored, for: app, using: client)
        #expect(validated.identity == credentials.identity)
        #expect(validated.organizationToken == nil)
        await #expect(throws: AccessError.transferAlreadyUsed) { try await transfer.poll(using: client) }
    }

    @Test("Cancellation cancels the pending HTTP poll and prevents reuse")
    func cancellation() async throws {
        let transfer = try AccessLoginTransfer(application: application()), client = SleepingHTTP()
        let task = Task { try await transfer.poll(using: client) }
        while !(await client.entered) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.cancelled)
        await #expect(throws: AccessError.transferAlreadyUsed) { try await transfer.poll(using: client) }
    }

    @Test("Total deadline cancels a hung poll")
    func totalDeadline() async throws {
        let transfer = try AccessLoginTransfer(application: application()), client = SleepingHTTP()
        await #expect(throws: AccessError.deadlineExceeded) {
            try await transfer.poll(using: client, timeout: .milliseconds(30))
        }
        #expect(await client.cancelled)
    }

    @Test("Polling is bounded when the transfer service returns immediately")
    func boundedPolling() async throws {
        actor Counter { var count = 0; func increment() { count += 1 } }
        let counter = Counter(), transfer = try AccessLoginTransfer(application: application())
        let client = StubHTTP { request in
            await counter.increment()
            return AccessHTTPResponse(url: request.url!, statusCode: 404)
        }
        await #expect(throws: AccessError.deadlineExceeded) { try await transfer.poll(using: client, pollInterval: .zero) }
        #expect(await counter.count == 10)
    }

    @Test("Malformed, tampered, redirected, and oversized transfers fail closed")
    func rejectsInvalidTransfer() async throws {
        for scenario in 0..<4 {
            let transfer = try AccessLoginTransfer(application: application())
            let client = StubHTTP { request in
                switch scenario {
                case 0:
                    return AccessHTTPResponse(url: request.url!, statusCode: 200,
                        headers: ["service-public-key": "AA=="], body: Data("AAAA".utf8))
                case 1:
                    return AccessHTTPResponse(url: request.url!, statusCode: 200,
                        headers: ["service-public-key": AccessBase64.encodeURL(Data(repeating: 7, count: 32), padded: true)],
                        body: Data(Data(repeating: 0, count: 80).base64EncodedString().utf8))
                case 2:
                    return AccessHTTPResponse(url: URL(string: "https://evil.example/transfer")!, statusCode: 200)
                default:
                    return AccessHTTPResponse(url: request.url!, statusCode: 200, body: Data(repeating: 0, count: 256 * 1024 + 1))
                }
            }
            let error: AccessError = [.invalidPublicKey, .decryptionFailed, .unexpectedResponse, .responseTooLarge][scenario]
            await #expect(throws: error) { try await transfer.poll(using: client) }
        }
    }

    @Test("Audience, issuer, expiration and user identity are mandatory")
    func rejectsWrongClaims() throws {
        let app = try application(), signer = try SignedTokens()
        let tests: [([String: Any], AccessError)] = [
            (signer.payload(audience: "another-application"), .wrongAudience),
            (signer.payload(issuer: "https://attacker.cloudflareaccess.com"), .wrongIssuer),
            (signer.payload(expires: 1), .expiredToken),
            (signer.payload(subject: ""), .userIdentityRequired),
            (signer.payload(type: "org"), .invalidClaims),
        ]
        for (payload, expected) in tests {
            let token = try signer.sign(payload)
            #expect(throws: expected) { try AccessJWTValidator.validateApplicationToken(token, jwks: signer.jwks, application: app) }
        }
        let stringAudience = try signer.sign(signer.payload(audience: "app-audience"))
        #expect(try AccessJWTValidator.validateApplicationToken(stringAudience, jwks: signer.jwks, application: app).subject == "synthetic-user")
    }

    @Test("Changing signed payload bytes and unsupported JWT algorithms are rejected")
    func rejectsInvalidSignatures() throws {
        let app = try application(), signer = try SignedTokens()
        let valid = try signer.sign(signer.payload())
        var parts = valid.split(separator: ".").map(String.init)
        parts[1] = AccessBase64.encodeURL(try JSONSerialization.data(withJSONObject: signer.payload(subject: "another-user")))
        #expect(throws: AccessError.invalidSignature) {
            try AccessJWTValidator.validateApplicationToken(parts.joined(separator: "."), jwks: signer.jwks, application: app)
        }
        let wrongAlgorithm = try signer.sign(signer.payload(), header: ["alg": "HS256", "kid": "synthetic-test-key"])
        #expect(throws: AccessError.invalidToken) {
            try AccessJWTValidator.validateApplicationToken(wrongAlgorithm, jwks: signer.jwks, application: app)
        }
    }

    @Test("Application discovery verifies signatures and binds metadata to the requested host and team")
    func signedDiscovery() async throws {
        let app = try application(), signer = try SignedTokens()
        for mismatch in [false, true] {
            let metadata = try signer.sign(["type": "match", "hostname": mismatch ? "other.example.com" : app.hostname,
                "auth_domain": app.teamDomain, "aud": app.audience, "iat": Int64(Date().timeIntervalSince1970)])
            let client = StubHTTP { request in
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "Moshpit-Access-P0/1 cloudflared-compatible/2026.10.3")
                if request.url == app.certificatesURL { return AccessHTTPResponse(url: request.url!, statusCode: 200, body: signer.jwks) }
                #expect(request.httpMethod == "HEAD")
                #expect(request.value(forHTTPHeaderField: "Cf-Access-Metadata-Request") == "true")
                return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": metadata])
            }
            if mismatch {
                await #expect(throws: AccessError.invalidMetadata) {
                    try await AccessApplicationDiscovery.discover(hostname: app.hostname, teamDomain: app.teamDomain, using: client)
                }
            } else {
                #expect(try await AccessApplicationDiscovery.discover(hostname: app.hostname, teamDomain: app.teamDomain, using: client) == app)
            }
        }
    }
}

@Suite("Cloudflare Access application discovery")
struct AccessDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let hostname = "ssh.example.com"
    private let team = "test.cloudflareaccess.com"

    private actor Requests {
        var urls: [URL] = []
        func record(_ request: URLRequest) { urls.append(request.url!) }
    }

    private func metadata(_ changes: [String: Any] = [:]) -> [String: Any] {
        var claims: [String: Any] = ["type": "match", "hostname": hostname, "auth_domain": team,
                                    "aud": "synthetic-app-audience", "iat": Int64(now.timeIntervalSince1970)]
        claims.merge(changes) { _, replacement in replacement }
        return claims
    }

    @Test("Hostname alone discovers a signed scope without cookies, tokens, or redirect following")
    func automaticDiscovery() async throws {
        let signer = try SignedTokens(), requests = Requests()
        let token = try signer.sign(metadata(["hostname": hostname.uppercased(), "auth_domain": team.uppercased(),
                                               "app_hostname": "*.example.com"]))
        let client = StubHTTP { request in
            await requests.record(request)
            #expect(request.url?.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Cf-Access-Token") == nil)
            #expect(request.httpBody == nil)
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AccessRequestHeaders.userAgent)
            if request.httpMethod == "HEAD" {
                #expect(request.url == URL(string: "https://ssh.example.com/"))
                #expect(request.value(forHTTPHeaderField: "Cf-Access-Metadata-Request") == "true")
                #expect(!request.httpShouldHandleCookies)
                return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: [
                    "Cf-Access-Metadata": token, "Location": "https://untrusted.example/login",
                    "Set-Cookie": "CF_Authorization=synthetic-never-forwarded; Secure",
                ])
            }
            #expect(request.httpMethod == "GET")
            #expect(request.url == URL(string: "https://test.cloudflareaccess.com/cdn-cgi/access/certs"))
            return AccessHTTPResponse(url: request.url!, statusCode: 200, body: signer.jwks)
        }
        let result = try await AccessApplicationDiscovery.discover(hostname: hostname.uppercased(), using: client, now: now)
        #expect(result == (try AccessApplication(hostname: hostname, audience: "synthetic-app-audience", teamDomain: team)))
        #expect(await requests.urls.count == 2)
    }

    @Test("Unverified authority cannot select a foreign, decorated, nested, or FedRAMP key endpoint")
    func rejectsUnsafeKeyDomainsBeforeFetchingKeys() async throws {
        let domains = ["", "evil.example", "evilcloudflareaccess.com", "cloudflareaccess.com",
                       "test.cloudflareaccess.com.evil.example", "test.fed.cloudflareaccess.com",
                       "nested.test.cloudflareaccess.com", "https://test.cloudflareaccess.com",
                       "someone@test.cloudflareaccess.com", "test.cloudflareaccess.com@evil.example",
                       "test.cloudflareaccess.com:443", "test.cloudflareaccess.com/path",
                       "test.cloudflareaccess.com?query", "test.cloudflareaccess.com#fragment",
                       "test.cloudflareaccess.com.", " test.cloudflareaccess.com", "test.cloudflareaccess.com\n",
                       "-test.cloudflareaccess.com", "test-.cloudflareaccess.com", "test_team.cloudflareaccess.com",
                       String(repeating: "a", count: 64) + ".cloudflareaccess.com", "tést.cloudflareaccess.com"]
        for domain in domains {
            let requests = Requests()
            // No valid signature is needed to prove an unsafe JWKS URL is never requested.
            let payload = AccessBase64.encodeURL(try JSONSerialization.data(withJSONObject: ["auth_domain": domain]))
            let client = StubHTTP { request in
                await requests.record(request)
                return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": "e30." + payload + ".AA"])
            }
            await #expect(throws: AccessError.invalidMetadata) {
                try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now)
            }
            #expect(await requests.urls == [URL(string: "https://ssh.example.com/")!])
        }
    }

    @Test("A permitted team address is insufficient without a valid metadata signature")
    func rejectsWrongSignature() async throws {
        let signer = try SignedTokens(), unrelatedSigner = try SignedTokens()
        let token = try signer.sign(metadata())
        let client = StubHTTP { request in
            if request.httpMethod == "HEAD" {
                return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": token])
            }
            return AccessHTTPResponse(url: request.url!, statusCode: 200, body: unrelatedSigner.jwks)
        }
        await #expect(throws: AccessError.invalidSignature) {
            try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now)
        }
    }

    @Test("Verified metadata must match the exact host, match type, valid audience, and issuance window")
    func rejectsInvalidSignedMetadata() async throws {
        let signer = try SignedTokens()
        let changes: [[String: Any]] = [
            ["hostname": "other.example.com"], ["hostname": "*.example.com"], ["hostname": hostname + "."],
            ["type": "nomatch"], ["aud": ""], ["aud": "bad/audience"], ["aud": "áudience"],
            ["aud": String(repeating: "a", count: 257)], ["aud": ["array-audience"]],
            ["iat": 0], ["iat": Int64(now.timeIntervalSince1970) - 86401],
            ["iat": Int64(now.timeIntervalSince1970) + 301], ["iat": NSNull()],
        ]
        for change in changes {
            let token = try signer.sign(metadata(change))
            let client = StubHTTP { request in
                if request.httpMethod == "HEAD" {
                    return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": token])
                }
                return AccessHTTPResponse(url: request.url!, statusCode: 200, body: signer.jwks)
            }
            await #expect(throws: AccessError.invalidMetadata) {
                try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now)
            }
        }
        for issuedAt in [Int64(now.timeIntervalSince1970) - 86400, Int64(now.timeIntervalSince1970) + 300] {
            let token = try signer.sign(metadata(["iat": issuedAt]))
            let client = StubHTTP { request in
                request.httpMethod == "HEAD"
                    ? AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": token])
                    : AccessHTTPResponse(url: request.url!, statusCode: 200, body: signer.jwks)
            }
            #expect(try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now).teamDomain == team)
        }
    }

    @Test("Pinned discovery refuses a different signed team before requesting its keys")
    func pinnedTeamMismatch() async throws {
        let signer = try SignedTokens(), requests = Requests()
        let token = try signer.sign(metadata(["auth_domain": "another.cloudflareaccess.com"]))
        let client = StubHTTP { request in
            await requests.record(request)
            return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: ["cf-access-metadata": token])
        }
        await #expect(throws: AccessError.invalidMetadata) {
            try await AccessApplicationDiscovery.discover(hostname: hostname, teamDomain: team, using: client, now: now)
        }
        #expect(await requests.urls.count == 1)
    }

    @Test("Redirected metadata or signing keys cannot authorize a discovered application")
    func rejectsRedirectedResponses() async throws {
        let signer = try SignedTokens(), token = try signer.sign(metadata())
        for scenario in 0..<3 {
            let client = StubHTTP { request in
                if request.httpMethod == "HEAD" {
                    return AccessHTTPResponse(url: scenario == 0 ? URL(string: "https://other.example.com")! : request.url!,
                                              statusCode: 302, headers: ["cf-access-metadata": token])
                }
                return AccessHTTPResponse(url: scenario == 1 ? URL(string: "https://other.cloudflareaccess.com/cdn-cgi/access/certs")! : request.url!,
                                          statusCode: scenario == 2 ? 302 : 200,
                                          headers: ["Location": "https://other.example.com/keys"], body: signer.jwks)
            }
            let expected: AccessError = [.invalidMetadata, .unexpectedResponse, .httpStatus(302)][scenario]
            await #expect(throws: expected) {
                try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now)
            }
        }
    }

    @Test("Metadata accepts one bounded JWT and bounds all response headers before key lookup")
    func boundsMetadataResponse() async throws {
        let signer = try SignedTokens(), token = try signer.sign(metadata())
        var manyHeaders = Dictionary(uniqueKeysWithValues: (0..<100).map { ("x-test-\($0)", "a") })
        manyHeaders["cf-access-metadata"] = token
        let scenarios: [([String: String], AccessError)] = [
            ([:], .invalidMetadata),
            (["cf-access-metadata": token + "," + token], .invalidMetadata),
            (["cf-access-metadata": token + ".extra"], .invalidMetadata),
            (["cf-access-metadata": token + "\n"], .invalidMetadata),
            (["cf-access-metadata": String(repeating: "a", count: 64 * 1024 + 1)], .responseTooLarge),
            (["cf-access-metadata": token, "x-extra": String(repeating: "a", count: 64 * 1024)], .responseTooLarge),
            (manyHeaders, .responseTooLarge),
        ]
        for (headers, error) in scenarios {
            let requests = Requests()
            let client = StubHTTP { request in
                await requests.record(request)
                return AccessHTTPResponse(url: request.url!, statusCode: 302, headers: headers)
            }
            await #expect(throws: error) {
                try await AccessApplicationDiscovery.discover(hostname: hostname, using: client, now: now)
            }
            #expect(await requests.urls.count == 1)
        }
    }
}
