import Foundation
import Testing
@testable import Moshpit

@Suite("Remote HTTP preview addresses")
struct RemoteWebPreviewTests {
    @Test(arguments: ["localhost:3000/path?q=中文#heading", "http://127.0.0.1:5173/a%20b?q=%2F", "http://[::1]:8080", "http://0.0.0.0:3000", "http://[::]:4000", "http://localhost"])
    func acceptsRemoteLoopback(_ text: String) throws {
        let address = try RemoteWebAddress(text)
        let local = address.localURL(port: 54321)
        #expect(local.host == "127.0.0.1" && local.port == 54321 && local.scheme == "http")
        let original = URLComponents(url: address.url, resolvingAgainstBaseURL: false)!
        let mapped = URLComponents(url: local, resolvingAgainstBaseURL: false)!
        #expect(original.percentEncodedPath == mapped.percentEncodedPath)
        #expect(original.percentEncodedQuery == mapped.percentEncodedQuery)
        #expect(original.percentEncodedFragment == mapped.percentEncodedFragment)
    }
    @Test("Default-port links open automatically and invalid URLs never acquire SSH") @MainActor
    func explicitLinkAndInvalidInput() {
        var acquisitions = 0
        let acquire: () async throws -> SSHSession = { acquisitions += 1; throw SSHError.sessionClosed }
        let manual = RemoteWebPreviewModel(host: "fixture", acquire: acquire)
        let link = RemoteWebPreviewModel(host: "fixture", url: URL(string: "http://localhost:3000")!, acquire: acquire)
        #expect(!manual.opensOnPresentation && link.opensOnPresentation)
        manual.address = "https://localhost:3000"
        manual.start()
        #expect(manual.error != nil && !manual.connecting && manual.localURL == nil)
        #expect(acquisitions == 0)
        manual.stop(); manual.suspend()
        #expect(manual.suspended && manual.localURL == nil)
    }
    @Test(arguments: ["", "https://localhost:3000", "file:///tmp/index.html", "javascript:alert(1)", "http://example.com:3000", "http://127.0.0.1.evil.com", "http://localhost:0", "http://localhost:65536", "http://user:secret@localhost:3000", "http://localhost:3000/\r\nHeader", "http://192.168.1.3:3000"])
    func rejectsOtherDestinations(_ text: String) {
        #expect(throws: RemoteWebPreviewError.self) { try RemoteWebAddress(text) }
    }
}

@Suite("SSH remote web preview integration", .tags(.integration), .serialized)
struct RemoteWebPreviewIntegrationTests {
    private static let path = ProcessInfo.processInfo.environment["MOSHPIT_WEB_SSH_FIXTURE"]
    private struct Fixture: Decodable {
        let port: Int
        let username: String
        let fingerprint: String
        let fixture_dir: String
        let web_preview_port: Int
    }
    @Test("HTTP assets, large bodies, POST, SSE and WebSocket survive forwarding; dismissal preserves SSH",
          .enabled(if: path != nil), .timeLimit(.minutes(1)))
    func loopbackLifecycle() async throws {
        let path = try #require(Self.path)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(fixture.fixture_dir.hasPrefix("/private/tmp/moshpit-ui-lab-") || fixture.fixture_dir.hasPrefix("/tmp/moshpit-ui-lab-"))
        let key = try String(contentsOfFile: fixture.fixture_dir + "/client_key", encoding: .utf8)
        let connection = ServerConnection(name: "web-preview-fixture", host: "127.0.0.1", port: fixture.port,
            username: fixture.username, authMethod: .key, connectionProtocol: .ssh)
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory())
        let session = try await service.connect(connection, overrideSecret: key,
            onUnknownHost: { host, port, fingerprint in host == "127.0.0.1" && port == fixture.port && fingerprint == fixture.fingerprint },
            onChangedHost: { _, _, _, _ in false })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        do {
            try await lateAcquisitionCannotReopen(session: session)
            try await session.requestPTY(rows: 32, cols: 93)
            let sibling = try await session.openRemoteFile(fixture.fixture_dir + "/marker.txt")
            let tunnel = try await session.startWebPreview(port: fixture.web_preview_port)
            defer { tunnel.stop() }
            let address = try RemoteWebAddress("localhost:\(fixture.web_preview_port)")
            let base = address.localURL(port: tunnel.localPort)
            let (html, response) = try await http.data(from: base)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: html, as: UTF8.self).contains("Hermit 远端预览"))
            let (script, _) = try await http.data(from: base.appendingPathComponent("asset.js"))
            #expect(String(decoding: script, as: UTF8.self).contains("WebSocket"))
            let (large, _) = try await http.data(from: base.appendingPathComponent("large"))
            #expect(large == Data((0..<2_097_152).map { UInt8(truncatingIfNeeded: $0) }))
            var post = URLRequest(url: base.appendingPathComponent("echo")); post.httpMethod = "POST"
            post.httpBody = Data(repeating: 0x71, count: 524_288)
            let (echo, _) = try await http.data(for: post)
            #expect(echo == post.httpBody)
            let (events, _) = try await http.data(from: base.appendingPathComponent("events"))
            #expect(String(decoding: events, as: UTF8.self) == "data: 0\n\ndata: 1\n\ndata: 2\n\ndata: 3\n\n")
            var ws = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            ws.scheme = "ws"
            let socket = http.webSocketTask(with: ws.url!)
            socket.resume()
            try await socket.send(.string("HMR 中文 test"))
            let message = try await socket.receive()
            if case .string(let value) = message { #expect(value == "HMR 中文 test") }
            else { Issue.record("WebSocket echo was not a text frame") }
            let concurrent = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
                for _ in 0..<6 { group.addTask { try await http.data(from: base.appendingPathComponent("asset.js")).0.count } }
                var values: [Int] = []; for try await value in group { values.append(value) }; return values
            }
            #expect(concurrent.count == 6 && concurrent.allSatisfy { $0 == script.count })
            let capped = try await session.startWebPreview(port: fixture.web_preview_port)
            defer { capped.stop() }
            var sockets: [URLSessionWebSocketTask] = []
            defer { for socket in sockets { socket.cancel(with: .goingAway, reason: nil) } }
            var capURL = URLComponents(url: address.localURL(port: capped.localPort).appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            capURL.scheme = "ws"
            for _ in 0..<16 {
                let socket = http.webSocketTask(with: capURL.url!); sockets.append(socket); socket.resume()
                try await socket.send(.string("capacity")); _ = try await socket.receive()
            }
            let excess = http.webSocketTask(with: capURL.url!); excess.resume()
            let rejected = await withTimeoutValue(3) {
                do { try await excess.send(.string("excess")); _ = try await excess.receive(); return false }
                catch { return true }
            }
            excess.cancel(with: .goingAway, reason: nil)
            #expect(rejected == true, "A seventeenth local connection must be rejected")
            capped.stop()
            tunnel.stop(); tunnel.stop()
            let socketClosed = await withTimeoutValue(3) {
                do { _ = try await socket.receive(); return false } catch { return true }
            }
            #expect(socketClosed == true)
            socket.cancel(with: .goingAway, reason: nil)
            let reopened = await withTimeoutValue(3) {
                do { _ = try await http.data(from: base); return true } catch { return false }
            }
            #expect(reopened == false, "The loopback listener must be closed")
            #expect(await session.isConnected)
            #expect(await session.rows == 32)
            #expect(await session.cols == 93)
            #expect(try await session.executeCommand("printf %s PREVIEW_SSH_SURVIVED") == Data("PREVIEW_SSH_SURVIVED".utf8))
            #expect(try await sibling.read(from: 0, length: 128) == Array("Hermit isolated simulator file browser fixture\n".utf8))
            await sibling.close()
            // Repeat creation to catch retained listeners and one-shot scope reuse.
            for _ in 0..<3 {
                let next = try await session.startWebPreview(port: fixture.web_preview_port)
                let (bytes, _) = try await http.data(from: address.localURL(port: next.localPort))
                #expect(bytes == html); next.stop()
            }
            await session.close()
        } catch { await session.close(); throw error }
    }
    @MainActor private func lateAcquisitionCannotReopen(session: SSHSession) async throws {
        var pending: CheckedContinuation<SSHSession, Never>?
        let model = RemoteWebPreviewModel(host: "bound-fixture") {
            await withCheckedContinuation { pending = $0 }
        }
        model.start()
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let reply = try #require(pending)
        model.stop()
        reply.resume(returning: session)
        for _ in 0..<5 { await Task.yield() }
        #expect(!model.connecting && model.localURL == nil && model.error == nil)
        #expect(await session.isConnected)
    }

}
