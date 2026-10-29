import Foundation

/// Public API contract, independent of any other app's implementation:
/// https://docs.volcengine.com/docs/doubao-voice/large-model-recording-file-lite-recognition-api?lang=en
enum DoubaoVoiceFailure: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey, invalidAPIKey, invalidResourceID, credentialsUnavailable
    case authentication, rateLimited, serviceUnavailable, invalidAudio, noSpeech
    case requestRejected, invalidResponse, network, timedOut, redirectRejected
    case recordingTooLong, audioConversion

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "Add your Doubao API key in Settings → Voice Input → Recognition.")
        case .invalidAPIKey:
            return String(localized: "The Doubao API key is invalid. Paste the key without spaces or line breaks.")
        case .invalidResourceID:
            return String(localized: "The Doubao resource ID is invalid. Check your voice recognition settings.")
        case .credentialsUnavailable:
            return String(localized: "The Doubao API key could not be accessed. Unlock this device and try again.")
        case .authentication:
            return String(localized: "Doubao rejected the API key or resource access. Check your key and enable the speech recognition resource in the Volcengine console.")
        case .rateLimited:
            return String(localized: "Doubao has reached its request limit. Wait a moment before trying again.")
        case .serviceUnavailable:
            return String(localized: "Doubao is temporarily unavailable. Try recognizing the recording again later.")
        case .invalidAudio, .audioConversion:
            return String(localized: "The recording could not be converted for Doubao. Record it again.")
        case .noSpeech:
            return String(localized: "No speech was recognized.")
        case .requestRejected:
            return String(localized: "Doubao rejected the request. Check the speech recognition resource in your settings.")
        case .invalidResponse:
            return String(localized: "Doubao returned an incomplete response. Try recognizing the recording again.")
        case .network:
            return String(localized: "Could not reach Doubao. Check your network and try recognizing the recording again.")
        case .timedOut:
            return String(localized: "Doubao did not respond in time. You can try recognizing the recording again.")
        case .redirectRejected:
            return String(localized: "Doubao redirected the request. The recording was not forwarded to another address.")
        case .recordingTooLong:
            return String(localized: "Cloud voice recordings are limited to two minutes. This recording was not uploaded; record a shorter message.")
        }
    }
}

protocol DoubaoVoiceTranscribing: Sendable {
    func transcribe(wav: Data, apiKey: String, resourceID: String) async throws -> String
}

/// One explicit upload per recording. A session never accepts redirects or
/// cookies, caches a response, retries a paid request, or logs response bodies.
final class DoubaoVoiceClient: DoubaoVoiceTranscribing, @unchecked Sendable {
    static let defaultResourceID = "volc.bigasr.auc_turbo"
    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let maximumWAVBytes = 16_000 * 2 * 120 + 44
    static let maximumResponseBytes = 1_024 * 1_024

    private let session: URLSession
    private let redirectDelegate = DoubaoVoiceRedirectDelegate()

    init(configuration: URLSessionConfiguration = .ephemeral) {
        // Copy before setting policy so a caller's shared configuration stays intact.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func validatedAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DoubaoVoiceFailure.missingAPIKey }
        guard key.utf8.count <= 4_096,
              key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw DoubaoVoiceFailure.invalidAPIKey
        }
        return key
    }

    static func validatedResourceID(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = value.isEmpty ? defaultResourceID : value
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard resource.utf8.count <= 128,
              resource.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DoubaoVoiceFailure.invalidResourceID
        }
        return resource
    }

    func transcribe(wav: Data, apiKey: String, resourceID: String) async throws -> String {
        try Task.checkCancellation()
        let key = try Self.validatedAPIKey(apiKey)
        let resource = try Self.validatedResourceID(resourceID)
        guard wav.count > 44, wav.count <= Self.maximumWAVBytes else {
            throw wav.count > Self.maximumWAVBytes ? DoubaoVoiceFailure.recordingTooLong : .noSpeech
        }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "hermit-voice"],
            "audio": ["data": wav.base64EncodedString()],
            "request": ["model_name": "bigmodel"]
        ])
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw DoubaoVoiceFailure.invalidResponse
            }
            try Self.validate(response)
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw DoubaoVoiceFailure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    throw DoubaoVoiceFailure.invalidResponse
                }
                data.append(byte)
                if data.count.isMultiple(of: 8_192) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            struct Response: Decodable {
                struct Result: Decodable { let text: String }
                let result: Result
            }
            guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
                throw DoubaoVoiceFailure.invalidResponse
            }
            let text = body.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DoubaoVoiceFailure.noSpeech }
            return text
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? DoubaoVoiceFailure { throw failure }
            if (error as? URLError)?.code == .timedOut { throw DoubaoVoiceFailure.timedOut }
            // NSError/userInfo and server error bodies can contain request headers,
            // audio or arbitrary service text. Expose none of them to the logger/UI.
            throw DoubaoVoiceFailure.network
        }
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: break
        case 300..<400: throw DoubaoVoiceFailure.redirectRejected
        case 401, 403: throw DoubaoVoiceFailure.authentication
        case 408, 504: throw DoubaoVoiceFailure.timedOut
        case 429: throw DoubaoVoiceFailure.rateLimited
        case 500..<600: throw DoubaoVoiceFailure.serviceUnavailable
        default: throw DoubaoVoiceFailure.requestRejected
        }
        // HTTP 200 alone is not recognition success: the provider reports its
        // business status independently. Fail closed when it is missing.
        guard let code = response.value(forHTTPHeaderField: "X-Api-Status-Code") else {
            throw DoubaoVoiceFailure.invalidResponse
        }
        switch code {
        case "20000000": return
        case "20000003", "45000002": throw DoubaoVoiceFailure.noSpeech
        case "45000151": throw DoubaoVoiceFailure.invalidAudio
        case "45000001": throw DoubaoVoiceFailure.requestRejected
        default:
            if code.hasPrefix("550") { throw DoubaoVoiceFailure.serviceUnavailable }
            throw DoubaoVoiceFailure.requestRejected
        }
    }
}

/// Reject even same-origin redirects: only the reviewed flash endpoint is
/// allowed to receive the authorization header and audio payload.
final class DoubaoVoiceRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
