import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import Moshpit

@Suite("SOCKS handshake completion")
struct SOCKSProxyDialerTests {
    enum Behavior: Sendable, CaseIterable {
        case rejectAuthentication, rejectDestination, close, silent, accept, acceptWithBanner
    }

    @Test("Proxy rejection and EOF fail the dial", arguments: [
        Behavior.rejectAuthentication, .rejectDestination, .close
    ])
    func rejectionAndEOF(behavior: Behavior) async throws {
        try await withProxy(behavior) { port, peer in
            do {
                _ = try await SOCKSProxyDialer.connect(
                    proxyHost: "127.0.0.1", proxyPort: port,
                    targetHost: "example.org", targetPort: 22, timeout: .seconds(2))
                Issue.record("A rejected handshake must not return a channel")
            } catch let error as SOCKSProxyDialer.DialError {
                switch (behavior, error) {
                case (.close, .connectionClosed),
                     (.rejectAuthentication, .connectFailed),
                     (.rejectDestination, .connectFailed): break
                default: Issue.record("Failure was delayed or misclassified: \(error)")
                }
            }
            let channel = try await peer.get()
            try await channel.closeFuture.get()
        }
    }

    @Test("A silent proxy reaches its handshake deadline and closes the socket")
    func silentProxyTimesOut() async throws {
        try await withProxy(.silent) { port, peer in
            do {
                _ = try await SOCKSProxyDialer.connect(
                    proxyHost: "127.0.0.1", proxyPort: port,
                    targetHost: "example.org", targetPort: 22, timeout: .milliseconds(250))
                Issue.record("Silent proxy unexpectedly completed")
            } catch let error as SOCKSProxyDialer.DialError {
                guard case .timedOut = error else {
                    Issue.record("Expected handshake timeout, got \(error)"); return
                }
            }
            let channel = try await peer.get()
            try await channel.closeFuture.get()
        }
    }

    @Test("Cancelling a dial ends its wait and closes the pending socket")
    func cancellationClosesSocket() async throws {
        try await withProxy(.silent) { port, peer in
            let dial = Task {
                try await SOCKSProxyDialer.connect(
                    proxyHost: "127.0.0.1", proxyPort: port,
                    targetHost: "example.org", targetPort: 22, timeout: .seconds(2))
            }
            let channel = try await peer.get()
            dial.cancel()
            await #expect(throws: CancellationError.self) { _ = try await dial.value }
            try await channel.closeFuture.get()
        }
    }

    @Test("A successful SOCKS handshake returns a usable channel")
    func acceptedProxy() async throws {
        try await withProxy(.accept) { port, peer in
            let channel = try await SOCKSProxyDialer.connect(
                proxyHost: "127.0.0.1", proxyPort: port,
                targetHost: "example.org", targetPort: 22, timeout: .seconds(2))
            #expect(channel.isActive)
            try await channel.close()
            try await peer.get().closeFuture.get()
        }
    }

    @Test("CONNECT reply and SSH banner in one packet survive a delayed protocol handoff",
          .timeLimit(.minutes(1)))
    func coalescedBannerSurvivesHandoff() async throws {
        try await withProxy(.acceptWithBanner) { port, peer in
            let channel = try await SOCKSProxyDialer.connect(
                proxyHost: "127.0.0.1", proxyPort: port,
                targetHost: "example.org", targetPort: 22, timeout: .seconds(2))
            // The proxy sent the banner in the CONNECT response packet, before
            // this consumer exists. Other network events may also arrive here.
            try await Task.sleep(for: .milliseconds(30))
            let captured = channel.eventLoop.makePromise(of: ByteBuffer.self)
            let deadline = channel.eventLoop.scheduleTask(in: .seconds(2)) {
                captured.fail(SOCKSProxyDialer.DialError.timedOut)
            }
            defer { deadline.cancel() }
            let expected = "SSH-2.0-moshpit-review\r\n"
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(
                    BannerCollector(promise: captured, expectedBytes: expected.utf8.count))
            }.get()
            try await SOCKSProxyDialer.completeHandoff(on: channel)
            let bytes = try await captured.futureResult.get()
            #expect(String(decoding: bytes.readableBytesView, as: UTF8.self) == expected)
            try await channel.close()
            try await peer.get().closeFuture.get()
        }
    }

    private final class BannerCollector: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let promise: EventLoopPromise<ByteBuffer>
        private let expectedBytes: Int
        private var buffer = ByteBuffer()
        private var finished = false

        init(promise: EventLoopPromise<ByteBuffer>, expectedBytes: Int) {
            self.promise = promise
            self.expectedBytes = expectedBytes
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer.writeBuffer(&bytes)
            if !finished, buffer.readableBytes >= expectedBytes {
                finished = true
                promise.succeed(buffer)
            }
        }
    }

    @Test("Invalid target ports fail before NIOSOCKS narrows them to UInt16", arguments: [-1, 0, 65536])
    func invalidPort(port: Int) async {
        await #expect(throws: SOCKSProxyDialer.DialError.self) {
            _ = try await SOCKSProxyDialer.connect(
                proxyHost: "127.0.0.1", proxyPort: 1080, targetHost: "example.org", targetPort: port)
        }
    }

    private func withProxy(
        _ behavior: Behavior,
        operation: (Int, EventLoopFuture<Channel>) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let peer = group.next().makePromise(of: Channel.self)
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ProxyResponder(behavior: behavior))
                    peer.succeed(channel)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try #require(server.localAddress?.port)
            try await operation(port, peer.futureResult)
            try await server.close()
        } catch {
            peer.futureResult.whenSuccess { $0.close(promise: nil) }
            try? await server.close()
            throw error
        }
    }

    private final class ProxyResponder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private let behavior: Behavior
        private var bytes = ByteBuffer()
        private var greeted = false

        init(behavior: Behavior) { self.behavior = behavior }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            bytes.writeBuffer(&incoming)
            if !greeted {
                guard bytes.readableBytes >= 3 else { return }
                bytes.moveReaderIndex(forwardBy: 3)
                greeted = true
                switch behavior {
                case .close: context.close(promise: nil); return
                case .silent: return
                case .rejectAuthentication:
                    write([5, 255], context); return
                case .accept, .acceptWithBanner, .rejectDestination:
                    write([5, 0], context)
                }
            }
            guard behavior == .accept || behavior == .acceptWithBanner || behavior == .rejectDestination,
                  let length: UInt8 = bytes.getInteger(at: bytes.readerIndex + 4),
                  bytes.readableBytes >= Int(length) + 7 else { return }
            bytes.clear()
            var response: [UInt8] = [5, behavior == .rejectDestination ? 5 : 0, 0, 1, 127, 0, 0, 1, 0, 22]
            if behavior == .acceptWithBanner {
                response += Array("SSH-2.0-moshpit-review\r\n".utf8)
            }
            write(response, context)
        }

        private func write(_ bytes: [UInt8], _ context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: bytes)), promise: nil)
        }
    }
}
