import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
import XCTest
@testable import CloudflareSSH

final class WebSocketByteStreamTests: XCTestCase {
    private func makeChannel(limit: Int = 1024 * 1024) throws -> (EmbeddedChannel, WebSocketByteStreamHandler) {
        let handler = WebSocketByteStreamHandler(maximumBufferedBytes: limit, heartbeatInterval: nil)
        let channel = EmbeddedChannel(handler: handler)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        return (channel, handler)
    }

    private func activate(_ handler: WebSocketByteStreamHandler, on channel: EmbeddedChannel) throws {
        try handler.activate(context: channel.pipeline.syncOperations.context(handler: handler))
    }

    private func frame(_ text: String, opcode: WebSocketOpcode = .binary, fin: Bool = true) -> WebSocketFrame {
        WebSocketFrame(fin: fin, opcode: opcode, data: ByteBuffer(string: text))
    }

    func testBannerWaitsForConsumerAndActivationIsIdempotent() throws {
        let (channel, handler) = try makeChannel()
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame("SSH-2.0-test\r\n"))
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
        try activate(handler, on: channel)
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self), ByteBuffer(string: "SSH-2.0-test\r\n"))
        try activate(handler, on: channel)
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
    }

    func testFragmentsAndInterleavedControlPreserveByteOrder() throws {
        let (channel, handler) = try makeChannel()
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame("a", fin: false))
        try channel.writeInbound(frame("ping", opcode: .ping))
        try channel.writeInbound(frame("", opcode: .continuation, fin: false))
        try channel.writeInbound(frame("b", opcode: .continuation))
        try channel.writeInbound(frame(""))
        try channel.writeInbound(frame("c"))
        let pong = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(pong.opcode, .pong)
        XCTAssertNotNil(pong.maskKey)
        XCTAssertEqual(pong.data, ByteBuffer(string: "ping"))
        try activate(handler, on: channel)
        var received = ByteBuffer()
        while var bytes = try channel.readInbound(as: ByteBuffer.self) { received.writeBuffer(&bytes) }
        XCTAssertEqual(received, ByteBuffer(string: "abc"))
    }

    func testRandomBinaryHasNoEnvelopeAndOutboundFramesAreMasked() throws {
        let (channel, handler) = try makeChannel()
        defer { _ = try? channel.finish() }
        try activate(handler, on: channel)
        let bytes = ByteBuffer(bytes: (0..<(128 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try channel.writeOutbound(bytes)
        var received = ByteBuffer()
        var frames = 0
        while let outgoing = try channel.readOutbound(as: WebSocketFrame.self) {
            XCTAssertEqual(outgoing.opcode, .binary)
            XCTAssertTrue(outgoing.fin)
            XCTAssertNotNil(outgoing.maskKey)
            XCTAssertLessThanOrEqual(outgoing.data.readableBytes, 16 * 1024)
            // Encoder applies the mask on the wire; the adapter's data is raw.
            var data = outgoing.data
            received.writeBuffer(&data)
            frames += 1
        }
        XCTAssertEqual(frames, 8)
        XCTAssertEqual(received, bytes)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .binary, data: bytes))
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self), bytes)
    }

    func testPreConsumerBufferIsBounded() throws {
        let (channel, _) = try makeChannel(limit: 4)
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame("1234"))
        XCTAssertThrowsError(try channel.writeInbound(frame("5"))) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .bufferLimitExceeded)
        }
        XCTAssertFalse(channel.isActive)
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
    }

    func testOversizedWriteFailsWithoutSendingPartialPayload() throws {
        let (channel, _) = try makeChannel(limit: 4)
        defer { _ = try? channel.finish() }
        XCTAssertThrowsError(try channel.writeOutbound(ByteBuffer(string: "12345")))
        let outgoing = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(outgoing.opcode, .connectionClose)
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertFalse(channel.isActive)
    }

    func testSlowWriterCannotAccumulateUnboundedPendingWrites() throws {
        let blocker = BlockedFrameWriter()
        let handler = WebSocketByteStreamHandler(maximumBufferedBytes: 4, heartbeatInterval: nil)
        let channel = EmbeddedChannel(handlers: [blocker, handler])
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        let first = channel.eventLoop.makePromise(of: Void.self)
        let second = channel.eventLoop.makePromise(of: Void.self)
        channel.write(ByteBuffer(string: "123"), promise: first)
        channel.write(ByteBuffer(string: "456"), promise: second)
        XCTAssertThrowsError(try second.futureResult.wait()) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .bufferLimitExceeded)
        }
        XCTAssertThrowsError(try first.futureResult.wait())
        XCTAssertEqual(blocker.payloads, [ByteBuffer(string: "123")])
        XCTAssertFalse(channel.isActive)
        _ = try? channel.throwIfErrorCaught()
    }

    func testRejectsTextMaskedServerAndInvalidFragmentSequence() throws {
        let badFrames = [
            frame("html", opcode: .text),
            frame("continuation", opcode: .continuation),
            WebSocketFrame(fin: true, opcode: .binary, maskKey: [1, 2, 3, 4], data: ByteBuffer(string: "masked")),
            frame("ping", opcode: .ping, fin: false)
        ]
        for bad in badFrames {
            let (channel, _) = try makeChannel()
            defer { _ = try? channel.finish() }
            XCTAssertThrowsError(try channel.writeInbound(bad))
            XCTAssertFalse(channel.isActive)
            XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
        }
    }

    func testNewBinaryCannotInterruptFragmentedMessage() throws {
        let (channel, _) = try makeChannel()
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame("start", fin: false))
        XCTAssertThrowsError(try channel.writeInbound(frame("replacement")))
        XCTAssertFalse(channel.isActive)
    }

    func testCloseEchoIsMaskedAndSentOnce() throws {
        let (channel, _) = try makeChannel()
        defer { _ = try? channel.finish() }
        var payload = ByteBuffer()
        payload.writeInteger(UInt16(1000))
        payload.writeString("done")
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))
        let close = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(close.opcode, .connectionClose)
        XCTAssertNotNil(close.maskKey)
        XCTAssertEqual(close.data, payload)
        _ = try? channel.close().wait()
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertFalse(channel.isActive)
    }

    func testInvalidCloseCodeAndUTF8AreRejected() throws {
        for bytes: [UInt8] in [[0], [0x03, 0xed], [0x03, 0xe8, 0xff]] {
            let (channel, _) = try makeChannel()
            defer { _ = try? channel.finish() }
            XCTAssertThrowsError(try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: bytes))))
            XCTAssertFalse(channel.isActive)
        }
    }

    func testMissingPongClosesRatherThanLeavingDeadStream() throws {
        let handler = WebSocketByteStreamHandler(heartbeatInterval: .seconds(2), heartbeatTimeout: .seconds(1))
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        XCTAssertEqual(try channel.readOutbound(as: WebSocketFrame.self)?.opcode, .ping)
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        XCTAssertFalse(channel.isActive)
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .heartbeatTimedOut)
        }
    }

    func testOnlyMatchingPongAcknowledgesHeartbeat() throws {
        let handler = WebSocketByteStreamHandler(heartbeatInterval: .seconds(2), heartbeatTimeout: .seconds(1))
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        let ping = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ping.data))
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        XCTAssertTrue(channel.isActive)
    }

    func testUpgradeAndBannerInOneTCPReadSurviveConsumerHandoff() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let future = try CloudflareSSHDialer.configureUpgrade(
            on: channel,
            destination: .init(URL(string: "wss://ssh.example.test/custom%20path?test=1")!),
            accessToken: "test-token"
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        let request = try readRequest(channel)
        XCTAssertTrue(request.hasPrefix("GET /custom%20path?test=1 HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("Cf-Access-Token: test-token\r\n"))
        XCTAssertFalse(request.lowercased().contains("sec-websocket-protocol:"))
        XCTAssertFalse(request.lowercased().contains("sec-websocket-extensions:"))
        let response = try response101(to: request)
        var packet = ByteBuffer(string: response)
        let banner = Array("SSH-2.0-local-fixture\r\n".utf8)
        packet.writeBytes([0x82, UInt8(banner.count)])
        packet.writeBytes(banner)
        try channel.writeInbound(packet)
        channel.embeddedEventLoop.run()
        let connection = try future.wait()
        XCTAssertTrue(connection.channel === channel)
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
        let handlerContext = try channel.pipeline.syncOperations.context(handlerType: WebSocketByteStreamHandler.self)
        let handler = try channel.pipeline.syncOperations.handler(type: WebSocketByteStreamHandler.self)
        try handler.activate(context: handlerContext)
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self), ByteBuffer(bytes: banner))
    }

    func testHTTPRejectionsAreNeverGivenToSSH() throws {
        for status in [302, 401, 403, 502, 530] {
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }
            let future = try CloudflareSSHDialer.configureUpgrade(
                on: channel, destination: .init(URL(string: "wss://ssh.example.test")!), accessToken: nil
            )
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
            _ = try readRequest(channel)
            _ = try? channel.writeInbound(ByteBuffer(string: "HTTP/1.1 \(status) Rejected\r\nContent-Length: 5\r\n\r\nlogin"))
            channel.embeddedEventLoop.run()
            XCTAssertThrowsError(try future.wait()) {
                XCTAssertEqual($0 as? CloudflareSSHTransportError, .httpStatus(status))
            }
            XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
        }
    }

    func testUnrequestedExtensionsAreRejected() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let future = try CloudflareSSHDialer.configureUpgrade(
            on: channel, destination: .init(URL(string: "wss://ssh.example.test")!), accessToken: nil
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        let request = try readRequest(channel)
        let response = try response101(to: request, extra: "Sec-WebSocket-Extensions: permessage-deflate\r\n")
        _ = try? channel.writeInbound(ByteBuffer(string: response))
        channel.embeddedEventLoop.run()
        XCTAssertThrowsError(try future.wait()) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .unsupportedWebSocketOptions)
        }
    }

    func testInvalidAcceptKeyDoesNotExposeBannerAsSSH() throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let future = try CloudflareSSHDialer.configureUpgrade(
            on: channel, destination: .init(URL(string: "wss://ssh.example.test")!), accessToken: nil
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        _ = try readRequest(channel)
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: invalid\r\n\r\n"
        _ = try? channel.writeInbound(ByteBuffer(string: response))
        channel.embeddedEventLoop.run()
        XCTAssertThrowsError(try future.wait())
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
    }

    func testEndpointValidationPreservesPathAndRejectsUnsafeSchemes() throws {
        let destination = try CloudflareSSHDialer.Destination(URL(string: "wss://ssh.example.test:8443/a%20b?x=y")!)
        XCTAssertEqual(destination.path, "/a%20b?x=y")
        XCTAssertEqual(destination.authority, "ssh.example.test:8443")
        for input in ["ws://ssh.example.test", "https://ssh.example.test", "wss://user:password@ssh.example.test", "wss://ssh.example.test/#fragment", "wss://ssh.example.test:0"] {
            XCTAssertThrowsError(try CloudflareSSHDialer.Destination(URL(string: input)!))
        }
    }

    private func readRequest(_ channel: EmbeddedChannel) throws -> String {
        var request = ""
        while let part = try channel.readOutbound(as: ByteBuffer.self) {
            request += String(decoding: part.readableBytesView, as: UTF8.self)
        }
        return request
    }

    private func response101(to request: String, extra: String = "") throws -> String {
        let keyLine = try XCTUnwrap(request.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        })
        let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\(extra)\r\n"
    }
}

private final class BlockedFrameWriter: ChannelOutboundHandler {
    typealias OutboundIn = WebSocketFrame
    var payloads: [ByteBuffer] = []
    private var pending: [EventLoopPromise<Void>] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapOutboundIn(data)
        if frame.opcode == .connectionClose {
            let writes = pending
            pending.removeAll()
            for write in writes { write.fail(ChannelError.ioOnClosedChannel) }
            promise?.succeed(())
        } else {
            payloads.append(frame.data)
            if let promise { pending.append(promise) }
        }
    }
}
