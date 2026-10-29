import Foundation
import Testing
@testable import Moshpit

@Suite("Doubao voice HTTP contract", .serialized)
struct DoubaoVoiceClientTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Plan {
            var status = 200
            var headers = ["X-Api-Status-Code": "20000000"]
            var body = Data(#"{"result":{"text":"  测试语音  "}}"#.utf8)
            var error: Error?
            var hold = false
        }
        static let lock = NSLock()
        static var plan = Plan()
        static var requests: [URLRequest] = []
        static var stops = 0
        static func reset(_ next: Plan = Plan()) {
            lock.withLock { plan = next; requests = []; stops = 0 }
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let plan = Self.lock.withLock { Self.requests.append(request); return Self.plan }
            if plan.hold { return }
            if let error = plan.error { client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: plan.status,
                                           httpVersion: "HTTP/1.1", headerFields: plan.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
    }

    private func client(_ plan: StubProtocol.Plan = .init()) -> DoubaoVoiceClient {
        StubProtocol.reset(plan)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return DoubaoVoiceClient(configuration: configuration)
    }

    private var recording: Data { Data(repeating: 1, count: 48) }
    private let secret = "unit-test-api-key-never-log"

    private func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    @Test("One official endpoint request carries the key only in its header and requires business success")
    func requestContract() async throws {
        let client = client()
        let text = try await client.transcribe(wav: recording, apiKey: " \(secret)\n", resourceID: "")
        #expect(text == "测试语音")
        let requests = StubProtocol.lock.withLock { StubProtocol.requests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == DoubaoVoiceClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == secret)
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc_turbo")
        #expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
        #expect(UUID(uuidString: request.value(forHTTPHeaderField: "X-Api-Request-Id") ?? "") != nil)
        let data = body(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["user"] as? [String: String])?["uid"] == "hermit-voice")
        #expect((json["request"] as? [String: String])?["model_name"] == "bigmodel")
        let encoded = try #require((json["audio"] as? [String: String])?["data"])
        #expect(Data(base64Encoded: encoded) == recording)
        #expect(String(data: data, encoding: .utf8)?.contains(secret) == false)
    }

    @Test("HTTP success never bypasses provider errors, malformed or empty transcripts",
          arguments: ["20000003", "45000002", "45000151", "45000001", "55000031", "missing", "malformed", "empty"])
    func businessFailures(scenario: String) async throws {
        var plan = StubProtocol.Plan()
        var expected: DoubaoVoiceFailure
        switch scenario {
        case "20000003", "45000002": expected = .noSpeech
        case "45000151": expected = .invalidAudio
        case "45000001": expected = .requestRejected
        case "55000031": expected = .serviceUnavailable
        case "empty": expected = .noSpeech; plan.body = Data(#"{"result":{"text":"  "}}"#.utf8)
        default: expected = .invalidResponse
        }
        if scenario == "missing" { plan.headers = [:] }
        else if scenario == "malformed" { plan.body = Data("invalid \(secret)".utf8) }
        else if scenario != "empty" { plan.headers["X-Api-Status-Code"] = scenario }
        plan.headers["X-Api-Message"] = "sensitive provider message \(secret)"
        let client = client(plan)
        do {
            _ = try await client.transcribe(wav: recording, apiKey: secret, resourceID: "")
            Issue.record("Expected a provider failure")
        } catch let failure as DoubaoVoiceFailure {
            #expect(failure == expected)
            #expect(!failure.localizedDescription.contains(secret))
        }
        #expect(StubProtocol.lock.withLock { StubProtocol.requests.count } == 1)
    }

    @Test("HTTP errors stay distinct without echoing the response body",
          arguments: [401, 403, 408, 429, 500, 504, 302])
    func httpFailures(status: Int) async throws {
        var plan = StubProtocol.Plan()
        plan.status = status
        plan.body = Data("private response: \(secret)".utf8)
        plan.headers["Location"] = "https://unrelated.invalid/collect"
        let expected: DoubaoVoiceFailure
        switch status {
        case 401, 403: expected = .authentication
        case 408, 504: expected = .timedOut
        case 429: expected = .rateLimited
        case 302: expected = .redirectRejected
        default: expected = .serviceUnavailable
        }
        let client = client(plan)
        do {
            _ = try await client.transcribe(wav: recording, apiKey: secret, resourceID: "")
            Issue.record("Expected HTTP failure")
        } catch let failure as DoubaoVoiceFailure {
            #expect(failure == expected)
            #expect(!failure.localizedDescription.contains(secret))
        }
        #expect(StubProtocol.lock.withLock { StubProtocol.requests.count } == 1)
    }

    @Test("The task delegate refuses credential-carrying redirects")
    func redirectDelegateRefuses() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: DoubaoVoiceClient.endpoint)
        let response = try #require(HTTPURLResponse(url: DoubaoVoiceClient.endpoint, statusCode: 307,
                                                    httpVersion: nil, headerFields: nil))
        let proposed = URLRequest(url: URL(string: "https://unrelated.invalid/collect")!)
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            DoubaoVoiceRedirectDelegate().urlSession(session, task: task,
                willPerformHTTPRedirection: response, newRequest: proposed) { continuation.resume(returning: $0) }
        }
        #expect(accepted == nil)
    }

    @Test("Timeouts and transport details are sanitized")
    func timeoutIsSafe() async throws {
        var plan = StubProtocol.Plan()
        plan.error = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "secret \(secret)"])
        let client = client(plan)
        do {
            _ = try await client.transcribe(wav: recording, apiKey: secret, resourceID: "")
            Issue.record("Expected timeout")
        } catch let failure as DoubaoVoiceFailure {
            #expect(failure == .timedOut)
            #expect(!failure.localizedDescription.contains(secret))
        }
    }

    @Test("Cancelling an upload cancels URLSession instead of waiting for its timeout")
    func cancellationStopsTransport() async throws {
        var plan = StubProtocol.Plan(); plan.hold = true
        let client = client(plan)
        let task = Task { try await client.transcribe(wav: recording, apiKey: secret, resourceID: "") }
        for _ in 0..<200 {
            if StubProtocol.lock.withLock({ !StubProtocol.requests.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StubProtocol.lock.withLock { !StubProtocol.requests.isEmpty })
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        for _ in 0..<200 {
            if StubProtocol.lock.withLock({ StubProtocol.stops > 0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StubProtocol.lock.withLock { StubProtocol.stops > 0 })
    }

    @Test("Oversize responses and invalid headers fail before a transcript is used")
    func boundedInputAndOutput() async throws {
        var plan = StubProtocol.Plan()
        plan.headers["Content-Length"] = String(DoubaoVoiceClient.maximumResponseBytes + 1)
        let client = client(plan)
        await #expect(throws: DoubaoVoiceFailure.invalidResponse) {
            try await client.transcribe(wav: recording, apiKey: secret, resourceID: "")
        }
        #expect(throws: DoubaoVoiceFailure.invalidAPIKey) {
            try DoubaoVoiceClient.validatedAPIKey("key\r\ninjected-header")
        }
        #expect(throws: DoubaoVoiceFailure.invalidResourceID) {
            try DoubaoVoiceClient.validatedResourceID("resource\ninjected-header")
        }
    }
}
