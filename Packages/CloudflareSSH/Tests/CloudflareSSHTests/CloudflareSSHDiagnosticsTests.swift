import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import CloudflareSSH

final class CloudflareSSHDiagnosticsTests: XCTestCase {
    func testFirstFailureSurvivesCleanupAndSnapshotDoesNotRetainAnEventArray() {
        let state = CloudflareSSHDiagnostics()
        state.record(.dialStarted)
        state.record(.failed(.heartbeatTimedOut))
        state.record(.closed)
        state.record(.failed(.connectionClosed))
        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.firstFailure, .heartbeatTimedOut)
        XCTAssertEqual(snapshot.firstTermination?.kind, .failed(.heartbeatTimedOut))
        XCTAssertEqual(snapshot.lastEvent?.kind, .failed(.connectionClosed))
    }

    func testHeartbeatTimeoutRemainsVisibleWhenDownstreamConsumesTheError() throws {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(heartbeatInterval: .seconds(2),
            heartbeatTimeout: .seconds(1), diagnostics: state)
        let channel = EmbeddedChannel(handlers: [stream, ErrorConsumer()])
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        let ping = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(ping.opcode, .ping)
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        XCTAssertFalse(channel.isActive)
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        XCTAssertEqual(state.snapshot.pingsSent, 1)
        XCTAssertEqual(state.snapshot.pongsReceived, 0)
        XCTAssertEqual(state.snapshot.firstFailure, .heartbeatTimedOut)
        XCTAssertEqual(state.snapshot.lastEvent?.kind, .closed)
    }

    func testPeerCloseKeepsOnlyItsNumericCodeAndPreservesItsPriority() throws {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(heartbeatInterval: nil, diagnostics: state)
        let channel = EmbeddedChannel(handler: stream)
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        var payload = ByteBuffer()
        payload.writeInteger(UInt16(1008))
        payload.writeString("https://private.invalid/?token=must-not-retain account@example.invalid")
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))
        state.record(.failed(.connectionClosed))
        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.peerCloseCode, 1008)
        XCTAssertEqual(snapshot.firstTermination?.kind, .peerClose(code: 1008))
        let description = String(describing: snapshot)
        XCTAssertFalse(description.contains("private.invalid"))
        XCTAssertFalse(description.contains("must-not-retain"))
        XCTAssertFalse(description.contains("account@"))
    }

    func testMatchingAndUnmatchedPongsAreCountedWithoutRetainingPayload() throws {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(heartbeatInterval: .seconds(2),
            heartbeatTimeout: .seconds(1), diagnostics: state)
        let channel = EmbeddedChannel(handler: stream)
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        let ping = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer(string: "wrong")))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ping.data))
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(state.snapshot.pongsReceived, 2)
        XCTAssertEqual(state.snapshot.matchingPongsReceived, 1)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testUnknownErrorsAreSanitizedBeforeTheyReachTheSnapshot() {
        struct Sensitive: Error, CustomStringConvertible {
            var description: String { "https://private.invalid/?token=must-not-retain" }
        }
        let state = CloudflareSSHDiagnostics()
        state.recordFailure(Sensitive())
        XCTAssertEqual(state.snapshot.firstFailure, .upgradeFailed)
        XCTAssertFalse(String(describing: state.snapshot).contains("private.invalid"))
    }

    func testLocalCloseIsDistinguishedFromUnannouncedTransportEOF() throws {
        let localState = CloudflareSSHDiagnostics()
        let local = EmbeddedChannel(handler: WebSocketByteStreamHandler(heartbeatInterval: nil, diagnostics: localState))
        defer { _ = try? local.finish() }
        try local.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        try local.close().wait()
        XCTAssertEqual(localState.snapshot.firstTermination?.kind, .localCloseRequested)
        XCTAssertEqual(localState.snapshot.lastEvent?.kind, .closed)

        let eofState = CloudflareSSHDiagnostics()
        let remoteStream = WebSocketByteStreamHandler(heartbeatInterval: nil, diagnostics: eofState)
        let remote = EmbeddedChannel(handler: remoteStream)
        defer { _ = try? remote.finish() }
        try remote.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        // Close the transport upstream of the WebSocket adapter, as an actual
        // socket EOF does, rather than requesting a WebSocket close handshake.
        try remote.pipeline.syncOperations.context(handler: remoteStream).close().wait()
        XCTAssertEqual(eofState.snapshot.firstTermination?.kind, .transportEOF)
        XCTAssertEqual(eofState.snapshot.lastEvent?.kind, .closed)
        eofState.record(.localCloseRequested)
        XCTAssertEqual(eofState.snapshot.firstTermination?.kind, .transportEOF)
    }

    func testOversizedWriteRecordsItsCauseBeforeAReentrantConsumerCloses() throws {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(maximumBufferedBytes: 4,
            heartbeatInterval: nil, diagnostics: state)
        let channel = EmbeddedChannel(handlers: [stream, ErrorConsumer()])
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        let observation = ReentrantObservation()
        let result = channel.eventLoop.makePromise(of: Void.self)
        result.futureResult.whenFailure { _ in
            channel.close(promise: nil)
            observation.firstCause = state.snapshot.firstTermination?.kind
        }
        channel.write(ByteBuffer(string: "12345"), promise: result)
        XCTAssertThrowsError(try result.futureResult.wait()) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .bufferLimitExceeded)
        }
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(observation.firstCause, .failed(.bufferLimitExceeded))
        XCTAssertEqual(state.snapshot.firstTermination?.kind, .failed(.bufferLimitExceeded))
    }

    func testFailedFrameWriteRecordsItsCauseBeforeAReentrantConsumerCloses() throws {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(heartbeatInterval: nil, diagnostics: state)
        let channel = EmbeddedChannel(handlers: [RejectedBinaryWriter(), stream, ErrorConsumer()])
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        let observation = ReentrantObservation()
        let result = channel.eventLoop.makePromise(of: Void.self)
        result.futureResult.whenFailure { _ in
            channel.close(promise: nil)
            observation.firstCause = state.snapshot.firstTermination?.kind
        }
        channel.write(ByteBuffer(string: "payload"), promise: result)
        XCTAssertThrowsError(try result.futureResult.wait()) {
            XCTAssertEqual($0 as? CloudflareSSHTransportError, .socketFailure(code: 54))
        }
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(observation.firstCause, .failed(.socketFailure(code: 54)))
        XCTAssertEqual(state.snapshot.firstTermination?.kind, .failed(.socketFailure(code: 54)))
    }

    private final class ReentrantObservation: @unchecked Sendable {
        var firstCause: CloudflareSSHDiagnosticEvent.Kind?
    }

    private final class RejectedBinaryWriter: ChannelOutboundHandler {
        typealias OutboundIn = WebSocketFrame
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if unwrapOutboundIn(data).opcode == .binary {
                promise?.fail(IOError(errnoCode: 54, reason: "synthetic reset"))
            } else {
                context.write(data, promise: promise)
            }
        }
    }

    private final class ErrorConsumer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        func errorCaught(context: ChannelHandlerContext, error: Error) {}
    }
}
