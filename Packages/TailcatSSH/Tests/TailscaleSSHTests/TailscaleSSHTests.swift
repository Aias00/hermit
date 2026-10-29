import CTailcat
import Foundation
import NIOCore
import NIOPosix
import XCTest
@_spi(EmbeddedTransport) import TailcatSSH
@testable import TailscaleSSH

final class TailscaleSSHTests: XCTestCase {
    func testConfigurationRejectsMalformedSecretPathAndControlURL() throws {
        let directory = URL(fileURLWithPath: "/tmp/moshpit-tailscale-package-test")
        let key = Data(repeating: 0x41, count: 32)
        let valid = try TailscaleNodeConfiguration(stateDirectory: directory, stateEncryptionKey: key, hostname: "moshpit-test")
        XCTAssertFalse(String(describing: valid).contains("moshpit-test"))
        XCTAssertFalse(String(reflecting: valid).contains(key.base64EncodedString()))
        XCTAssertThrowsError(try TailscaleNodeConfiguration(stateDirectory: directory, stateEncryptionKey: key.dropLast(), hostname: "test"))
        XCTAssertThrowsError(try TailscaleNodeConfiguration(stateDirectory: URL(string: "https://secret.example/state")!, stateEncryptionKey: key, hostname: "test"))
        for host in ["bad name", "-name", "name-", "bad\u{0}name", String(repeating: "x", count: 64)] {
            XCTAssertThrowsError(try TailscaleNodeConfiguration(stateDirectory: directory, stateEncryptionKey: key, hostname: host))
        }
        for url in ["http://remote.example", "https://user:password@example.com", "https://example.com/?token=SECRET", "https://example.com/#SECRET"] {
            XCTAssertThrowsError(try TailscaleNodeConfiguration(stateDirectory: directory, stateEncryptionKey: key, hostname: "test", controlURL: URL(string: url)!)) {
                XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testStatusDecodesPeersAndDoesNotDescribeLoginCapability() throws {
        let status = try TailscaleNodeStatus.decode(statusData(authURL: "https://login.tailscale.com/a/SECRET"))
        XCTAssertEqual(status.backendState, "Running")
        XCTAssertEqual(status.accountIdentity, "account-1")
        XCTAssertEqual(status.selfPeer?.id, "self-id")
        XCTAssertEqual(status.peers.first?.hostname, "mini")
        XCTAssertEqual(status.peers.first?.addresses, ["100.64.1.2", "fd7a:115c:a1e0::1"])
        XCTAssertEqual(status.authURL?.host, "login.tailscale.com")
        XCTAssertFalse(String(describing: status).contains("SECRET"))
        XCTAssertFalse(String(reflecting: status).contains("user@example.com"))
    }

    func testStatusRejectsUntrustedLoginURLsAndUnknownSchema() throws {
        for url in ["http://login.tailscale.com/a/SECRET", "https://login.tailscale.com.evil.test/a/SECRET", "https://user@login.tailscale.com/a/SECRET", "https://login.tailscale.com:444/a/SECRET", "https://login.tailscale.com/a/SECRET#fragment", "javascript:alert(1)"] {
            XCTAssertThrowsError(try TailscaleNodeStatus.decode(statusData(authURL: url))) {
                XCTAssertEqual($0 as? TailscaleSSHTransportError, .invalidLoginURL)
                XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            }
        }
        XCTAssertThrowsError(try TailscaleNodeStatus.decode(statusData(schema: 2)))
        XCTAssertThrowsError(try TailscaleNodeStatus.decode(Data("not JSON SECRET".utf8)))
    }

    func testStatusHealthCodesAreOptionalAndIgnoreUnknownNativeValues() throws {
        XCTAssertTrue(try TailscaleNodeStatus.decode(statusData()).healthIssues.isEmpty)
        XCTAssertTrue(TailscaleNodeStatus(backendState: "NeedsLogin").healthIssues.isEmpty)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: statusData()) as? [String: Any])
        document["health_issues"] = ["network_unavailable", "dns_unavailable", "tls_failure", "control_unreachable", "timeout", "future_code", "https://login.tailscale.com/a/SECRET"]
        let status = try TailscaleNodeStatus.decode(JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(status.healthIssues, [.networkUnavailable, .dnsUnavailable, .tlsFailure, .controlUnreachable, .timeout])
        XCTAssertFalse(String(reflecting: status.healthIssues).contains("SECRET"))
        XCTAssertFalse(String(reflecting: status).contains("SECRET"))
        document["health_issues"] = NSNull()
        XCTAssertTrue(try TailscaleNodeStatus.decode(JSONSerialization.data(withJSONObject: document)).healthIssues.isEmpty)
    }

    func testPermanentErrorsNeverTriggerTransportRetry() throws {
        for error in [TailscaleSSHTransportError.authenticationRequired, .approvalRequired, .invalidStoredState,
                      .storageUnavailable, .invalidLoginURL, .nodeAlreadyOpen, .invalidConfiguration] {
            XCTAssertFalse(error.isRetryable)
        }
        let timeout = TailscaleSSHTransportError.nativeFailure(operation: .dial, code: Int32(TC_TIMEOUT))
        XCTAssertTrue(timeout.isRetryable)
        XCTAssertTrue(timeout.isTimeout)
        XCTAssertThrowsError(try LiveTailscaleNativeAPI.check(Int32(MT_AUTH_REQUIRED), operation: .dial)) {
            XCTAssertEqual($0 as? TailscaleSSHTransportError, .authenticationRequired)
        }
        XCTAssertThrowsError(try LiveTailscaleNativeAPI.check(Int32(TC_CANCELLED), operation: .dial)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testHostValidationSupportsMagicDNSAndIPv6WithoutPortInjection() throws {
        XCTAssertEqual(try TailscaleSSHDialer.normalizedHost(" Mini.tailnet.ts.net. "), "mini.tailnet.ts.net")
        XCTAssertEqual(try TailscaleSSHDialer.normalizedHost("100.64.1.2"), "100.64.1.2")
        XCTAssertEqual(try TailscaleSSHDialer.normalizedHost("[fd7a:115c:a1e0::1]"), "fd7a:115c:a1e0::1")
        for host in ["", "ssh://mini", "mini:22", "user@mini", "bad..name", "a/b", "a\u{0}b", "fd7a:invalid", "bad name"] {
            XCTAssertThrowsError(try TailscaleSSHDialer.normalizedHost(host))
        }
    }

    func testRealNativeCreationAndStatusDoNotStartEnrollment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try TailscaleNodeConfiguration(stateDirectory: directory,
                                                           stateEncryptionKey: Data(repeating: 0x73, count: 32), hostname: "moshpit-offline-test")
        let node = try await TailscaleNode(configuration: configuration)
        let status = try await node.status()
        XCTAssertEqual(status.backendState, "Stopped")
        XCTAssertNil(status.authURL)
        XCTAssertTrue(status.peers.isEmpty)
        do {
            let duplicate = try await TailscaleNode(configuration: configuration)
            await duplicate.close()
            XCTFail("two live nodes opened one account directory")
        } catch { XCTAssertEqual(error as? TailscaleSSHTransportError, .nodeAlreadyOpen) }
        await node.close(); await node.close()
        let reopened = try await TailscaleNode(configuration: configuration)
        await reopened.close()
    }

    func testDialRequiresLoginWithoutStartingBrowserFlow() async throws {
        let api = FakeTailscaleAPI(state: "NeedsLogin")
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            _ = try await TailscaleSSHDialer().connect(node: node, host: "mini", port: 22, on: group)
            XCTFail("unauthenticated node dialed")
        } catch { XCTAssertEqual(error as? TailscaleSSHTransportError, .authenticationRequired) }
        XCTAssertEqual(api.loginCount, 0)
        XCTAssertEqual(api.startCount, 0)
        await node.close()
        try await group.shutdownGracefully()
    }

    func testExplicitLoginAndLogoutRemainSeparateFromLocalClose() async throws {
        let api = FakeTailscaleAPI(state: "NeedsLogin")
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        try await node.start()
        let initial = try await node.status()
        XCTAssertNil(initial.authURL)
        let login = try await node.startLogin()
        XCTAssertEqual(login.authURL?.host, "login.tailscale.com")
        XCTAssertEqual(api.loginCount, 1)
        try await node.logout()
        let loggedOut = try await node.status()
        XCTAssertNil(loggedOut.authURL)
        XCTAssertEqual(api.logoutCount, 1)
        XCTAssertEqual(api.closeCount, 0)
        await node.close()
        XCTAssertEqual(api.closeCount, 1)
    }

    func testFailedRemoteLogoutIsReportedWithoutDestroyingNode() async throws {
        let api = FakeTailscaleAPI(failLogout: true)
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        do { try await node.logout(); XCTFail("failed remote logout was reported as success") }
        catch { XCTAssertEqual(error as? TailscaleSSHTransportError, .nativeFailure(operation: .logout, code: Int32(TC_FAILURE))) }
        XCTAssertEqual(api.closeCount, 0)
        let status = try await node.status()
        XCTAssertTrue(status.isRunning)
        await node.close()
    }

    func testConcurrentSSHStreamsShareNodeAndPreserveUTF8Bytes() async throws {
        let api = FakeTailscaleAPI()
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        async let a = TailscaleSSHDialer().connect(node: node, host: "mini", port: 22, on: group)
        async let b = TailscaleSSHDialer().connect(node: node, host: "mini", port: 22, on: group)
        let (first, second) = try await (a, b)
        XCTAssertEqual(api.makeCount, 1)
        XCTAssertEqual(api.streams.count, 2)
        await first.close()
        XCTAssertEqual(api.closeCount, 0)
        XCTAssertTrue(second.channel.isActive)
        let payload = Data((String(repeating: "中文🙂\u{0}\u{1}\r\n", count: 4096)).utf8)
        let received = expectation(description: "UTF8 and binary bytes")
        let collector = ByteCollector(expected: payload.count) { received.fulfill() }
        try await second.channel.pipeline.addHandler(collector).get()
        try await second.activate()
        var buffer = second.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try await second.channel.writeAndFlush(buffer).get()
        await fulfillment(of: [received], timeout: 5)
        let actual = try await second.channel.eventLoop.submit { collector.bytes }.get()
        XCTAssertEqual(actual, payload)
        await node.close()
        try await second.channel.closeFuture.get()
        await second.close()
        XCTAssertEqual(api.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testEarlyBannerIsGatedUntilSSHConsumerActivates() async throws {
        let read = expectation(description: "native read")
        let received = expectation(description: "banner received")
        let payload = Data("SSH-2.0-test\r\n".utf8)
        let stream = EchoByteStream(initial: payload, onRead: { read.fulfill() })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = try await TailscaleSSHDialer.adapt(stream: stream, on: group)
        let collector = ByteCollector(expected: payload.count) { received.fulfill() }
        try await connection.channel.pipeline.addHandler(collector).get()
        await fulfillment(of: [read], timeout: 2)
        let before = try await connection.channel.eventLoop.submit { collector.bytes }.get()
        XCTAssertTrue(before.isEmpty)
        try await connection.activate()
        await fulfillment(of: [received], timeout: 2)
        await connection.close()
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    func testCancellationRacingSuccessfulNativeDialClosesOnlyItsStream() async throws {
        let dialing = expectation(description: "dial entered native worker")
        let release = DispatchSemaphore(value: 0)
        let api = FakeTailscaleAPI(beforeDial: { dialing.fulfill(); release.wait() })
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let task = Task { try await TailscaleSSHDialer().connect(node: node, host: "mini", port: 22, on: group) }
        await fulfillment(of: [dialing], timeout: 2)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("canceled dial succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(api.streams.first?.closeCount, 1)
        XCTAssertEqual(api.closeCount, 0)
        await node.close()
        try await group.shutdownGracefully()
    }

    func testConcurrentCloseWaitsForDestructionAndClosedNodeCannotRestart() async throws {
        let closing = expectation(description: "native close started")
        let release = DispatchSemaphore(value: 0)
        let api = FakeTailscaleAPI(beforeClose: { closing.fulfill(); release.wait() })
        let node = try await TailscaleNode(configuration: configuration(), api: api)
        let first = Task { await node.close() }
        await fulfillment(of: [closing], timeout: 2)
        let second = Task { await node.close() }
        do { try await node.start(); XCTFail("closed node restarted") }
        catch { XCTAssertEqual(error as? TailscaleSSHTransportError, .connectionClosed) }
        release.signal()
        await first.value; await second.value
        await node.close()
        XCTAssertEqual(api.closeCount, 1)
        XCTAssertEqual(api.startCount, 0)
    }

    func testWriteBudgetFailureUsesTailscaleErrorAndCleansUp() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let stream = EchoByteStream()
        let connection = try await TailscaleSSHDialer.adapt(stream: stream, on: group)
        var bytes = connection.channel.allocator.buffer(capacity: 1_048_577)
        bytes.writeRepeatingByte(0x41, count: 1_048_577)
        do { try await connection.channel.write(bytes).get(); XCTFail("unbounded write accepted") }
        catch { XCTAssertEqual(error as? TailscaleSSHTransportError, .backpressureExceeded) }
        await connection.close()
        XCTAssertEqual(stream.closeCount, 1)
        try await group.shutdownGracefully()
    }

    private func configuration() throws -> TailscaleNodeConfiguration {
        try TailscaleNodeConfiguration(stateDirectory: URL(fileURLWithPath: "/tmp/fake-tailscale"),
                                       stateEncryptionKey: Data(repeating: 1, count: 32), hostname: "moshpit-test")
    }

    private func statusData(authURL: String = "", schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": schema, "backend_state": "Running", "auth_url": authURL,
            "tailnet_name": "example-tailnet", "user_login": "user@example.com", "account_identity": "account-1",
            "self": ["id": "self-id", "hostname": "iphone", "dns_name": "iphone.tailnet.ts.net", "ips": ["100.64.1.1"], "online": true],
            "peers": [["id": "peer-id", "hostname": "mini", "dns_name": "mini.tailnet.ts.net", "ips": ["100.64.1.2", "fd7a:115c:a1e0::1"], "online": true]]
        ])
    }
}

private final class FakeTailscaleAPI: TailscaleNativeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0, started = 0, logins = 0, logouts = 0, closed = 0
    private var connections: [EchoByteStream] = []
    private let state: String
    private var authURL: URL?
    private let failLogout: Bool
    private let beforeDial: (@Sendable () -> Void)?
    private let beforeClose: (@Sendable () -> Void)?
    init(state: String = "Running", beforeDial: (@Sendable () -> Void)? = nil, beforeClose: (@Sendable () -> Void)? = nil, failLogout: Bool = false) {
        self.state = state; self.beforeDial = beforeDial; self.beforeClose = beforeClose; self.failLogout = failLogout
    }
    var makeCount: Int { lock.lock(); defer { lock.unlock() }; return created }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var loginCount: Int { lock.lock(); defer { lock.unlock() }; return logins }
    var logoutCount: Int { lock.lock(); defer { lock.unlock() }; return logouts }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closed }
    var streams: [EchoByteStream] { lock.lock(); defer { lock.unlock() }; return connections }
    func makeNode(_ configuration: TailscaleNodeConfiguration) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }; created += 1; return 100
    }
    func start(node: UInt64, token: UInt64) throws { lock.lock(); started += 1; lock.unlock() }
    func status(node: UInt64, token: UInt64) throws -> TailscaleNodeStatus {
        lock.lock(); defer { lock.unlock() }; return .init(backendState: state, authURL: authURL)
    }
    func startLogin(node: UInt64, token: UInt64) throws {
        lock.lock(); logins += 1; authURL = URL(string: "https://login.tailscale.com/a/SECRET"); lock.unlock()
    }
    func logout(node: UInt64, token: UInt64) throws {
        if failLogout { throw TailscaleSSHTransportError.nativeFailure(operation: .logout, code: Int32(TC_FAILURE)) }
        lock.lock(); logouts += 1; authURL = nil; lock.unlock()
    }
    func dial(node: UInt64, token: UInt64, host: String, port: UInt16) throws -> any BlockingByteStream {
        beforeDial?()
        guard state == "Running" else { throw TailscaleSSHTransportError.authenticationRequired }
        let stream = EchoByteStream()
        lock.lock(); connections.append(stream); lock.unlock()
        return stream
    }
    func closeNode(_ node: UInt64) {
        beforeClose?()
        lock.lock(); closed += 1; let streams = connections; lock.unlock()
        streams.forEach { $0.cancel(); $0.close() }
    }
}

private final class EchoByteStream: BlockingByteStream, @unchecked Sendable {
    private let condition = NSCondition()
    private var inbound: Data
    private var stopped = false
    private var closures = 0
    private var onRead: (@Sendable () -> Void)?
    init(initial: Data = Data(), onRead: (@Sendable () -> Void)? = nil) { inbound = initial; self.onRead = onRead }
    var closeCount: Int { condition.lock(); defer { condition.unlock() }; return closures }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        condition.lock(); defer { condition.unlock() }
        let notify = onRead; onRead = nil; notify?()
        while inbound.isEmpty && !stopped { condition.wait() }
        if inbound.isEmpty { return 0 }
        let count = min(buffer.count, inbound.count, 113)
        inbound.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
        inbound.removeFirst(count)
        return count
    }
    func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { throw TailscaleSSHTransportError.connectionClosed }
        inbound.append(buffer.bindMemory(to: UInt8.self)); condition.broadcast()
    }
    func cancel() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func close() { condition.lock(); if closures == 0 { closures = 1 }; stopped = true; condition.broadcast(); condition.unlock() }
}

/// All mutation and inspection is confined to the owning channel's event loop.
private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var bytes = Data()
    private let expected: Int
    private var reached: (() -> Void)?
    init(expected: Int, reached: @escaping () -> Void) { self.expected = expected; self.reached = reached }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        if bytes.count >= expected { reached?(); reached = nil }
    }
}
