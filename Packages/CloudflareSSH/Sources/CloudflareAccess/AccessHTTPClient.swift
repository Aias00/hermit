import Foundation

enum AccessRequestHeaders {
    // Access metadata discovery can reject the platform's default User-Agent.
    // Identify the client consistently across discovery, transfer, and JWKS.
    static let userAgent = "Moshpit-Access-P0/1 cloudflared-compatible/2026.10.3"
}

public struct AccessHTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }
}

public protocol AccessHTTPClient: Sendable {
    /// Implementations must honor task cancellation and reject redirects.
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccessHTTPResponse
}

/// A separate cookie-free session: authentication data never enters the shared
/// browser or URLSession cookie stores. Tokens are never forwarded on redirects.
public final class URLSessionAccessHTTPClient: AccessHTTPClient, @unchecked Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccessHTTPResponse {
        guard request.url?.scheme == "https", maximumResponseBytes > 0 else { throw AccessError.unexpectedResponse }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            // Ending iteration early (for example on the size cap) must stop
            // the underlying download as well as reject its buffered body.
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, let url = response.url,
                  url == request.url else { throw AccessError.unexpectedResponse }
            if response.expectedContentLength > maximumResponseBytes { throw AccessError.responseTooLarge }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumResponseBytes else { throw AccessError.responseTooLarge }
                body.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return AccessHTTPResponse(url: url, statusCode: response.statusCode, headers: headers, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AccessError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // URLSession errors may embed the transfer capability URL.
            throw AccessError.networkFailure
        }
    }
}
