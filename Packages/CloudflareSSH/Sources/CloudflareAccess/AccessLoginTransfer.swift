import Foundation
import Sodium

/// cloudflared 2026.10.3, de6376c5af4a67cbc65258682e5a01781827643d:
/// token/transfer.go and token/encrypt.go. This is a compatibility experiment,
/// not a Cloudflare-supported mobile OAuth SDK.
public actor AccessLoginTransfer {
    public nonisolated let application: AccessApplication
    /// This URL contains an unguessable login capability. Do not log or persist it.
    public nonisolated let browserURL: URL
    private let transferURL: URL
    private var secretKey: [UInt8]
    private var used = false

    public init(application: AccessApplication) throws {
        guard let pair = Sodium().box.keyPair() else { throw AccessError.keyGenerationFailed }
        self.application = application
        self.secretKey = pair.secretKey
        let publicKey = AccessBase64.encodeURL(Data(pair.publicKey), padded: true)
        var redirected = URLComponents(url: application.applicationURL, resolvingAgainstBaseURL: false)!
        redirected.queryItems = [URLQueryItem(name: "token", value: publicKey), URLQueryItem(name: "aud", value: application.audience)]
        var browser = redirected
        browser.path = "/cdn-cgi/access/cli"
        browser.queryItems = redirected.queryItems! + [
            URLQueryItem(name: "redirect_url", value: redirected.url!.absoluteString),
            URLQueryItem(name: "send_org_token", value: "true"),
            URLQueryItem(name: "edge_token_transfer", value: "true"),
        ]
        browserURL = browser.url!
        transferURL = URL(string: "https://login.cloudflareaccess.org/transfer/")!.appendingPathComponent(publicKey)
    }

    deinit { Sodium().utils.zero(&secretKey) }

    /// Single-use, including cancellation/failure. A new attempt must use a new
    /// ephemeral key. Completion of this operation, not a browser redirect,
    /// authorizes closing the authentication UI.
    public func poll(using client: any AccessHTTPClient = URLSessionAccessHTTPClient(),
                     timeout: Duration = .seconds(300),
                     pollInterval: Duration = .seconds(1)) async throws -> AccessCredentials {
        guard !used else { throw AccessError.transferAlreadyUsed }
        used = true
        defer { Sodium().utils.zero(&secretKey); secretKey.removeAll() }
        guard timeout > .zero, pollInterval >= .zero else { throw AccessError.deadlineExceeded }
        return try await withThrowingTaskGroup(of: AccessCredentials.self) { group in
            group.addTask { try await self.receive(using: client, pollInterval: pollInterval) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AccessError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AccessError.invalidTransfer }
            return result
        }
    }

    private struct TransferPayload: Decodable {
        let app_token: String
        let org_token: String?
    }

    private func receive(using client: any AccessHTTPClient, pollInterval: Duration) async throws -> AccessCredentials {
        for attempt in 0..<10 {
            try Task.checkCancellation()
            var request = URLRequest(url: transferURL)
            request.timeoutInterval = 60
            request.setValue(AccessRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
            let response = try await client.send(request, maximumResponseBytes: 256 * 1024)
            try Task.checkCancellation()
            guard response.url == transferURL else { throw AccessError.unexpectedResponse }
            guard response.body.count <= 256 * 1024 else { throw AccessError.responseTooLarge }
            if response.statusCode != 200 {
                // The official transfer service long-polls while the browser
                // is open. Keep retries bounded even if it responds immediately.
                guard response.statusCode < 500 else { throw AccessError.httpStatus(response.statusCode) }
                if attempt < 9 { try await Task.sleep(for: pollInterval) }
                continue
            }
            guard let servicePublicKey = response.headers["service-public-key"],
                  let peerKey = AccessBase64.decodeURL(servicePublicKey), peerKey.count == 32 else {
                throw AccessError.invalidPublicKey
            }
            guard let encoded = String(data: response.body, encoding: .utf8),
                  let encrypted = Data(base64Encoded: encoded), encrypted.count >= 40 else { throw AccessError.invalidTransfer }
            guard var plaintext = Sodium().box.open(nonceAndAuthenticatedCipherText: Array(encrypted),
                                                    senderPublicKey: Array(peerKey), recipientSecretKey: secretKey) else {
                throw AccessError.decryptionFailed
            }
            defer { Sodium().utils.zero(&plaintext) }
            guard let tokens = try? JSONDecoder().decode(TransferPayload.self, from: Data(plaintext)),
                  !tokens.app_token.isEmpty else { throw AccessError.invalidTransfer }
            let jwks = try await AccessApplicationDiscovery.fetchKeys(for: application, using: client)
            try Task.checkCancellation()
            let now = Date()
            let identity = try AccessJWTValidator.validateApplicationToken(tokens.app_token, jwks: jwks, application: application, now: now)
            var organizationExpiry: Date?
            if let orgToken = tokens.org_token, !orgToken.isEmpty {
                organizationExpiry = try AccessJWTValidator.validateOrganizationToken(orgToken, jwks: jwks,
                    application: application, subject: identity.subject, now: now).expiresAt
            }
            return AccessCredentials(application: application, applicationToken: tokens.app_token, identity: identity,
                                     organizationToken: tokens.org_token?.isEmpty == false ? tokens.org_token : nil,
                                     organizationExpiresAt: organizationExpiry)
        }
        throw AccessError.deadlineExceeded
    }
}
