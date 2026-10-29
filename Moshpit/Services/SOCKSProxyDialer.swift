import Foundation
import NIOCore
import NIOPosix
import NIOSOCKS

/// Dials a SOCKS5 proxy and hands back a `Channel` already past the CONNECT
/// handshake. Incoming target bytes remain buffered until the caller installs
/// its protocol handlers and calls `completeHandoff(on:)`, so an SSH banner
/// coalesced with the SOCKS reply cannot fall through an empty pipeline.
///
/// Only unauthenticated SOCKS5 is supported: `NIOSOCKS.SOCKSClientHandler`
/// always sends `ClientGreeting(methods: [.noneRequired])` — its own source
/// comment says "no authentication currently supported" — so a proxy that
/// requires a username/password will reject the handshake.
enum SOCKSProxyDialer {
    enum DialError: LocalizedError {
        case connectFailed(String)
        case connectionClosed
        case timedOut
        case invalidAddress

        var errorDescription: String? {
            switch self {
            case .connectFailed(let why): return "SOCKS proxy connection failed: \(why)"
            case .connectionClosed: return "The SOCKS proxy closed the connection before completing the handshake."
            case .timedOut: return "The SOCKS proxy did not complete the handshake in time."
            case .invalidAddress: return "The SOCKS host or port is invalid."
            }
        }
    }

    private static let socksHandlerName = "moshpit.socks.client"
    private static let waiterHandlerName = "moshpit.socks.waiter"

    static func connect(proxyHost: String, proxyPort: Int, targetHost: String, targetPort: Int,
                        timeout: TimeAmount = .seconds(15)) async throws -> Channel {
        // NIOSOCKS writes the domain length and port as UInt8/UInt16. Reject
        // invalid saved values before those conversions can trap.
        guard !proxyHost.isEmpty, !targetHost.isEmpty, targetHost.utf8.count <= 255,
              (1...65535).contains(proxyPort), (1...65535).contains(targetPort) else {
            throw DialError.invalidAddress
        }
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let handshake = Handshake(eventLoop: eventLoop)
        eventLoop.execute { handshake.startDeadline(timeout) }

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard handshake.attach(channel) else { throw CancellationError() }
                    try channel.pipeline.syncOperations.addHandler(
                        SOCKSClientHandler(targetAddress: .domain(targetHost, port: targetPort)),
                        name: socksHandlerName)
                    try channel.pipeline.syncOperations.addHandler(
                        ProxyEstablishedWaiter(handshake: handshake), name: waiterHandlerName)
                }
            }

        bootstrap.connect(host: proxyHost, port: proxyPort).whenFailure { error in
            handshake.fail(DialError.connectFailed(error.localizedDescription))
        }
        return try await withTaskCancellationHandler {
            try await handshake.promise.futureResult.get()
        } onCancel: {
            eventLoop.execute { handshake.fail(CancellationError()) }
        }
    }

    /// Call after installing the target protocol's handlers, before awaiting
    /// anything that needs an inbound byte (such as SSH authentication).
    static func completeHandoff(on channel: Channel) async throws {
        guard channel.isActive else { throw DialError.connectionClosed }
        try await channel.pipeline.removeHandler(name: waiterHandlerName).get()
    }

    /// All paths resolve the same promise on the channel's event loop. A proxy
    /// can reject authentication, close after accepting TCP, or never answer;
    /// none of those produces SOCKSProxyEstablishedEvent. The old waiter only
    /// handled that success event and left every other dial suspended forever.
    private final class Handshake: @unchecked Sendable {
        let eventLoop: EventLoop
        let promise: EventLoopPromise<Channel>
        private var channel: Channel?
        private var deadline: Scheduled<Void>?
        private var finished = false

        init(eventLoop: EventLoop) {
            self.eventLoop = eventLoop
            promise = eventLoop.makePromise(of: Channel.self)
        }

        func startDeadline(_ timeout: TimeAmount) {
            eventLoop.preconditionInEventLoop()
            guard !finished else { return }
            deadline = eventLoop.scheduleTask(in: timeout) { [self] in
                fail(DialError.timedOut)
            }
        }

        func attach(_ channel: Channel) -> Bool {
            eventLoop.preconditionInEventLoop()
            guard !finished else {
                channel.close(promise: nil)
                return false
            }
            self.channel = channel
            return true
        }

        func succeed(_ channel: Channel) {
            eventLoop.preconditionInEventLoop()
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            self.channel = nil
            promise.succeed(channel)
        }

        func fail(_ error: Error) {
            eventLoop.preconditionInEventLoop()
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            promise.fail(error)
            channel?.close(promise: nil)
            channel = nil
        }
    }

    private final class ProxyEstablishedWaiter: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        private let handshake: Handshake
        private var established = false
        private var buffered: [ByteBuffer] = []
        private var bufferedBytes = 0
        private static let maxBufferedBytes = 1024 * 1024

        init(handshake: Handshake) { self.handshake = handshake }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if established { context.close(promise: nil) }
            else { handshake.fail(DialError.connectFailed(error.localizedDescription)) }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = unwrapInboundIn(data)
            guard bytes.readableBytes <= Self.maxBufferedBytes - bufferedBytes else {
                handshake.fail(DialError.connectFailed("Target sent too much data before protocol handoff"))
                context.close(promise: nil)
                return
            }
            buffered.append(bytes)
            bufferedBytes += bytes.readableBytes
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            // Replayed together with buffered bytes after the target handler
            // exists; forwarding it now would notify an empty pipeline.
        }

        func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
            let pending = buffered
            buffered.removeAll()
            bufferedBytes = 0
            for bytes in pending { context.fireChannelRead(wrapInboundOut(bytes)) }
            if !pending.isEmpty { context.fireChannelReadComplete() }
            context.leavePipeline(removalToken: removalToken)
        }

        func channelInactive(context: ChannelHandlerContext) {
            handshake.fail(DialError.connectionClosed)
            context.fireChannelInactive()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            guard event is SOCKSProxyEstablishedEvent else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            established = true
            let channel = context.channel
            let handshake = self.handshake
            // Removing NIOSOCKS synchronously flushes bytes following CONNECT.
            // Keep this buffer in place until the SSH handler has been added.
            channel.pipeline.removeHandler(name: socksHandlerName).whenComplete { result in
                switch result {
                case .success: handshake.succeed(channel)
                case .failure(let error): handshake.fail(error)
                }
            }
        }
    }
}
