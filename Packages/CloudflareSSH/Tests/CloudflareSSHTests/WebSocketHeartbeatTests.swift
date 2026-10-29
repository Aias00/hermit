import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import CloudflareSSH

final class WebSocketHeartbeatTests: XCTestCase {
    func testReplyBudgetStartsAfterQueuedPingHasActuallyBeenWritten() throws {
        let writer = ControlledWriter()
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        let ping = try XCTUnwrap(writer.ping)
        channel.embeddedEventLoop.advanceTime(by: .seconds(8))
        writer.completePing()
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        XCTAssertTrue(channel.isActive, "Eight seconds queued plus five seconds awaiting reply is not a ten-second missing pong")
        guard channel.isActive else { return }
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ping.data))
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        XCTAssertTrue(channel.isActive)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testContinuedFrameWriteProgressKeepsAQueuedPingAlive() throws {
        let writer = ControlledWriter(holdBinary: true)
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        let transfer = channel.eventLoop.makePromise(of: Void.self)
        channel.write(ByteBuffer(repeating: 0x61, count: 64 * 1024), promise: transfer)
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        let ping = try XCTUnwrap(writer.ping)
        // Four queued 16 KiB frames drain slowly but steadily. A deadline based
        // on the whole 64 KiB write would also incorrectly call this stalled.
        for _ in 0..<4 {
            channel.embeddedEventLoop.advanceTime(by: .seconds(8))
            XCTAssertTrue(channel.isActive, "A queue making bounded forward progress must not expire its unsent ping")
            guard channel.isActive else { return }
            writer.completeNextBinary()
        }
        try transfer.futureResult.wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        writer.completePing()
        channel.embeddedEventLoop.advanceTime(by: .seconds(5))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ping.data))
        XCTAssertTrue(channel.isActive)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testSynchronousPongDoesNotLeaveAGhostDeadline() throws {
        let writer = ControlledWriter(synchronousPong: true)
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(state.snapshot.matchingPongsReceived, 1)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testPongArrivingBeforeWriteCompletionCannotArmALateDeadline() throws {
        let writer = ControlledWriter()
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        let ping = try XCTUnwrap(writer.ping)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .pong, data: ping.data))
        writer.completePing()
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))
        XCTAssertTrue(channel.isActive)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testPingAndPongWriteErrorsAreReportedImmediately() throws {
        for opcode: WebSocketOpcode in [.ping, .pong] {
            let writer = ControlledWriter(rejecting: opcode)
            let (channel, state) = try makeChannel(writer)
            defer { _ = try? channel.finish() }
            if opcode == .ping {
                channel.embeddedEventLoop.advanceTime(by: .seconds(20))
            } else {
                try channel.writeInbound(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "peer")))
            }
            XCTAssertFalse(channel.isActive)
            XCTAssertEqual(state.snapshot.firstFailure, .socketFailure(code: 54))
            XCTAssertEqual(state.snapshot.firstTermination?.kind, .failed(.socketFailure(code: 54)))
        }
    }

    func testLocalCloseWithPendingPingLeavesNoHeartbeatTimer() throws {
        let writer = ControlledWriter()
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        try channel.close().wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(120))
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(state.snapshot.firstTermination?.kind, .localCloseRequested)
        XCTAssertNil(state.snapshot.firstFailure)
    }

    func testQueuedPingWithNoWriteProgressHasABoundedDistinctDeadline() throws {
        let writer = ControlledWriter()
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        XCTAssertEqual(state.snapshot.lastEvent?.kind, .pingQueued)
        XCTAssertEqual(state.snapshot.pingsSent, 0)
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(state.snapshot.firstFailure, .heartbeatWriteTimedOut)
    }

    func testDataWriteProgressAfterPingSentCannotExtendThePongDeadline() throws {
        let writer = ControlledWriter(holdBinary: true)
        let (channel, state) = try makeChannel(writer)
        defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(20))
        writer.completePing()
        let transfer = channel.eventLoop.makePromise(of: Void.self)
        channel.write(ByteBuffer(repeating: 0x61, count: 16 * 1024), promise: transfer)
        channel.embeddedEventLoop.advanceTime(by: .seconds(8))
        writer.completeNextBinary()
        try transfer.futureResult.wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(state.snapshot.firstFailure, .heartbeatTimedOut)
    }

    private func makeChannel(_ writer: ControlledWriter) throws -> (EmbeddedChannel, CloudflareSSHDiagnostics) {
        let state = CloudflareSSHDiagnostics()
        let stream = WebSocketByteStreamHandler(heartbeatInterval: .seconds(20), heartbeatTimeout: .seconds(10), diagnostics: state)
        let channel = EmbeddedChannel(handlers: [writer, stream, ErrorConsumer()])
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        return (channel, state)
    }

    private final class ErrorConsumer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        func errorCaught(context: ChannelHandlerContext, error: Error) {}
    }

    private final class ControlledWriter: ChannelOutboundHandler {
        typealias OutboundIn = WebSocketFrame
        let holdBinary: Bool
        let synchronousPong: Bool
        let rejecting: WebSocketOpcode?
        var ping: WebSocketFrame?
        private var pingCompletion: EventLoopPromise<Void>?
        private var binaryCompletions: [EventLoopPromise<Void>] = []

        init(holdBinary: Bool = false, synchronousPong: Bool = false, rejecting: WebSocketOpcode? = nil) {
            self.holdBinary = holdBinary
            self.synchronousPong = synchronousPong
            self.rejecting = rejecting
        }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let frame = unwrapOutboundIn(data)
            if frame.opcode == rejecting {
                promise?.fail(IOError(errnoCode: 54, reason: "synthetic reset"))
            } else if frame.opcode == .ping {
                ping = frame
                if synchronousPong {
                    context.pipeline.fireChannelRead(WebSocketFrame(fin: true, opcode: .pong, data: frame.data))
                    promise?.succeed(())
                } else { pingCompletion = promise }
            } else if frame.opcode == .binary && holdBinary {
                if let promise { binaryCompletions.append(promise) }
            } else { context.write(data, promise: promise) }
        }

        func completePing() {
            let completion = pingCompletion
            pingCompletion = nil
            completion?.succeed(())
        }

        func completeNextBinary() {
            if !binaryCompletions.isEmpty { binaryCompletions.removeFirst().succeed(()) }
        }

        func handlerRemoved(context: ChannelHandlerContext) {
            let ping = pingCompletion
            pingCompletion = nil
            let binary = binaryCompletions
            binaryCompletions.removeAll()
            ping?.fail(ChannelError.ioOnClosedChannel)
            for completion in binary { completion.fail(ChannelError.ioOnClosedChannel) }
        }
    }
}
