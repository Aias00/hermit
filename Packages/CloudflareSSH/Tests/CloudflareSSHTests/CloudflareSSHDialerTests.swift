import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import XCTest
@testable import CloudflareSSH

final class CloudflareSSHDialerTests: XCTestCase {
    func testTLSHandshakeEOFRemainsDistinctFromCertificateAndProtocolFailures() {
        let transient: [NIOSSLError] = [
            .handshakeFailed(.sslError([.eofDuringHandshake])),
            .handshakeFailed(.sslError([.eofDuringAdditionalCertficiateChainValidation])),
            .uncleanShutdown
        ]
        for error in transient {
            XCTAssertEqual(
                CloudflareSSHDialer.sanitizedError(error) as? CloudflareSSHTransportError,
                .tlsFailure(.connectionClosed)
            )
        }
        XCTAssertEqual(
            CloudflareSSHDialer.sanitizedError(NIOSSLError.unableToValidateCertificate) as? CloudflareSSHTransportError,
            .tlsFailure(.certificateRejected)
        )
        XCTAssertEqual(
            CloudflareSSHDialer.sanitizedError(NIOSSLError.handshakeFailed(.sslError([]))) as? CloudflareSSHTransportError,
            .tlsFailure(.handshakeFailed)
        )
    }

    func testRealTLSUpgradePreservesBannerUntilConsumerIsInstalled() async throws {
        let certificate = try NIOSSLCertificate(bytes: Array(LocalTLSFixture.certificate.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(LocalTLSFixture.privateKey.utf8), format: .pem)
        let tls = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)
        ))
        try await withServer(initializer: { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(NIOSSLServerHandler(context: tls), LocalUpgradeServer())
            }
        }) { port, group in
            let dialer = try CloudflareSSHDialer(trustRoots: .certificates([certificate]))
            let connection = try await dialer.connect(
                endpoint: URL(string: "wss://localhost:\(port)")!, accessToken: "local-fixture-token", on: group
            )
            // The server has already sent the 101 response and first frame in
            // one TLS write. This delay exercises the real consumer handoff.
            try await Task.sleep(for: .milliseconds(20))
            let banner = connection.channel.eventLoop.makePromise(of: ByteBuffer.self)
            try await connection.channel.eventLoop.submit {
                try connection.channel.pipeline.syncOperations.addHandler(BannerReceiver(promise: banner))
            }.get()
            try await connection.activate()
            let result = try await banner.futureResult.get()
            XCTAssertEqual(result, ByteBuffer(string: "SSH-2.0-local-tls-fixture\r\n"))
            await connection.close()
        }
    }

    func testTLSUsesFullHostnameVerification() async throws {
        let certificate = try NIOSSLCertificate(bytes: Array(LocalTLSFixture.wrongHostnameCertificate.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(LocalTLSFixture.privateKey.utf8), format: .pem)
        let tls = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)
        ))
        try await withServer(initializer: { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(NIOSSLServerHandler(context: tls), LocalUpgradeServer())
            }
        }) { port, group in
            let dialer = try CloudflareSSHDialer(trustRoots: .certificates([certificate]))
            do {
                let connection = try await dialer.connect(
                    endpoint: URL(string: "wss://localhost:\(port)")!, accessToken: nil, on: group
                )
                await connection.close()
                XCTFail("Trusting the fixture root must not bypass its wrong DNS hostname")
            } catch {
                XCTAssertEqual(error as? CloudflareSSHTransportError, .tlsFailure(.hostnameMismatch))
            }
        }
    }

    func testDeadlineIncludesStalledTLSHandshake() async throws {
        try await withServer(initializer: { $0.eventLoop.makeSucceededVoidFuture() }) { port, group in
            let dialer = try CloudflareSSHDialer()
            let start = ContinuousClock.now
            do {
                let connection = try await dialer.connect(
                    endpoint: URL(string: "wss://localhost:\(port)")!, accessToken: nil, on: group,
                    timeout: .milliseconds(100)
                )
                await connection.close()
                XCTFail("Expected the TLS handshake deadline")
            } catch {
                XCTAssertEqual(error as? CloudflareSSHTransportError, .deadlineExceeded)
            }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        }
    }

    func testCancellationClosesStalledHandshakePromptly() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let accepted = group.next().makePromise(of: Void.self)
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.succeed(())
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try XCTUnwrap(listener.localAddress?.port)
            let dialer = try CloudflareSSHDialer()
            let task = Task {
                try await dialer.connect(endpoint: URL(string: "wss://localhost:\(port)")!, accessToken: nil, on: group)
            }
            try await accepted.futureResult.get()
            let start = ContinuousClock.now
            task.cancel()
            do {
                let connection = try await task.value
                await connection.close()
                XCTFail("Expected task cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func testHeaderInjectionIsRejectedBeforeNetworkAccess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let dialer = try CloudflareSSHDialer()
        do {
            _ = try await dialer.connect(
                endpoint: URL(string: "wss://invalid.example.test")!, accessToken: "value\r\nX-Injected: yes", on: group
            )
            XCTFail("Expected invalid credential")
        } catch { XCTAssertEqual(error as? CloudflareSSHTransportError, .invalidCredential) }
        try await group.shutdownGracefully()
    }

    private func withServer(
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>,
        body: (Int, MultiThreadedEventLoopGroup) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer(initializer)
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            try await body(try XCTUnwrap(listener.localAddress?.port), group)
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class LocalUpgradeServer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var request = ByteBuffer()
    private var responded = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        var bytes = unwrapInboundIn(data)
        request.writeBuffer(&bytes)
        guard request.readableBytes <= 16 * 1024 else { context.close(promise: nil); return }
        let text = String(decoding: request.readableBytesView, as: UTF8.self)
        guard text.contains("\r\n\r\n"), let keyLine = text.components(separatedBy: "\r\n").first(where: {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }) else { return }
        responded = true
        let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        var packet = ByteBuffer(string: "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n")
        let banner = Array("SSH-2.0-local-tls-fixture\r\n".utf8)
        packet.writeBytes([0x82, UInt8(banner.count)])
        packet.writeBytes(banner)
        context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
    }
}

private final class BannerReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<ByteBuffer>
    private var complete = false

    init(promise: EventLoopPromise<ByteBuffer>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !complete else { return }
        complete = true
        promise.succeed(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !complete { complete = true; promise.fail(CloudflareSSHTransportError.connectionClosed) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !complete { complete = true; promise.fail(error) }
        context.close(promise: nil)
    }
}
