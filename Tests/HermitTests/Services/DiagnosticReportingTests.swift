import Foundation
import Testing
@testable import Moshpit

@Suite("Structured diagnostic reporting")
struct DiagnosticReportingTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-" + UUID().uuidString) }

    @Test("Only typed SSH fields are exported; error descriptions and transport secrets are absent")
    func structuredPrivacy() throws {
        let event = SSHConnectionDiagnostic(attemptID: UUID(), connectionID: UUID(), route: .tailscale,
            phase: .authenticationMethod, outcome: .failed,
            errorClass: SSHConnectionDiagnostic.classify(SSHError.unsupportedKeyType("SECRET-PASSWORD 192.168.1.10 /Users/private")))
        let data = try DiagnosticJournal.encoder().encode(DiagnosticRecord.ssh(event))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("ssh.unsupported-key-type"))
        for forbidden in ["SECRET", "192.168", "/Users", "hostname", "password", "token", "command"] { #expect(!text.contains(forbidden)) }
        let invalid = DiagnosticRecord(kind: .health, code: "https://secret.invalid/?token=SECRET")
        #expect(invalid.code == nil)
    }

    @Test("A relaunch recovers buffered records and retries immutable batches until acknowledged")
    func durableBatches() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(root: root)
        await journal.append(DiagnosticRecord(kind: .network, code: "path-changed"))
        let restored = DiagnosticJournal(root: root)
        let first = try await restored.pending()
        #expect(first.count == 1)
        let file = try #require(first.first)
        let bytes = try Data(contentsOf: file)
        let batch = try DiagnosticJournal.decoder().decode(DiagnosticBatch.self, from: bytes)
        #expect(batch.events.count == 1)
        #expect(batch.events[0].code == "path-changed")
        #expect(try await restored.pending() == first)
        #expect(try Data(contentsOf: file) == bytes)
        try await restored.acknowledge(file)
        #expect(try await restored.pending().isEmpty)
    }

    @Test("Journal retention and capacity remain bounded while failed uploads are retained")
    func boundedRetention() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(root: root, maxBytes: 1800, retention: 60)
        for _ in 0..<12 {
            await journal.append(DiagnosticRecord(kind: .health, code: "probe-timeout-confirmed"))
            _ = try await journal.pending()
        }
        let files = try await journal.pending()
        let total = try files.reduce(0) { try $0 + Data(contentsOf: $1).count }
        #expect(total <= 1800)
        #expect(!files.isEmpty)
        for file in files { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: file.path) }
        #expect(try await journal.pending().isEmpty)
        try await journal.clear()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("An in-flight upload keeps an immutable copy when the ring evicts its original batch")
    func inFlightCopy() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(root: root, maxBytes: 1100)
        await journal.append(DiagnosticRecord(kind: .health, code: "probe-failed"))
        let files = try await journal.pending()
        let first = try #require(files.first)
        let configuration = UUID()
        let stage = try await journal.stageUpload(first, configurationID: configuration)
        let original = try Data(contentsOf: stage)
        for _ in 0..<8 {
            await journal.append(DiagnosticRecord(kind: .network, code: "path-changed"))
            _ = try await journal.pending()
        }
        #expect(try Data(contentsOf: stage) == original)
        #expect(!(try await journal.pending()).contains(stage))
        await journal.discardUpload(first.lastPathComponent, configurationID: configuration)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }

    @Test("Upload acknowledgements require the correct batch ID; login pages, bad JSON and errors preserve logs")
    func acknowledgement() {
        let id = UUID().uuidString
        #expect(DiagnosticUploadResponses.accepted(Data("{\"acceptedBatchID\":\"\(id.lowercased())\"}".utf8), status: 202, batchID: id))
        for data in [Data("<html>login</html>".utf8), Data("{}".utf8), Data("{\"acceptedBatchID\":\"other\"}".utf8)] {
            #expect(!DiagnosticUploadResponses.accepted(data, status: 200, batchID: id))
        }
        #expect(!DiagnosticUploadResponses.accepted(Data("{\"acceptedBatchID\":\"\(id)\"}".utf8), status: 401, batchID: id))
        let endpoint = URL(string: "https://logs.example/diagnostics/v1/batches")!
        #expect(DiagnosticUploadResponses.sameEndpoint(request: endpoint, response: endpoint))
        for target in ["https://other.example/diagnostics/v1/batches", "https://logs.example/login", "http://logs.example/diagnostics/v1/batches"] {
            #expect(!DiagnosticUploadResponses.sameEndpoint(request: endpoint, response: URL(string: target)))
        }
    }

    @Test("Configuration requires HTTPS without userinfo, query credentials or untrusted URI fields")
    func receiverConfiguration() throws {
        let token = String(repeating: "a", count: 43)
        let config = try DiagnosticReceiverConfiguration(endpoint: URL(string: "https://logs.example/diagnostics/v1/batches")!, token: token)
        #expect(!String(describing: config).contains(token))
        #expect(!String(reflecting: config).contains(token))
        for text in ["http://logs.example/upload", "https://user:pass@logs.example/upload", "https://logs.example/upload?token=x", "https://logs.example/upload#secret"] {
            #expect(throws: DiagnosticReportingError.self) { try DiagnosticReceiverConfiguration(endpoint: URL(string: text)!, token: token) }
        }
        var link = URLComponents(); link.scheme = "hermit"; link.host = "diagnostics"; link.path = "/configure"
        link.queryItems = [.init(name: "endpoint", value: config.endpoint.absoluteString), .init(name: "token", value: token)]
        #expect(DiagnosticReceiverConfiguration.from(link.url!)?.endpoint == config.endpoint)
        link.scheme = "hermit-diagnostics"
        #expect(DiagnosticReceiverConfiguration.from(link.url!)?.endpoint == config.endpoint)
        link.queryItems?.append(.init(name: "token", value: "duplicated"))
        #expect(DiagnosticReceiverConfiguration.from(link.url!) == nil)
    }
}
