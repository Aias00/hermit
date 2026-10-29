import Foundation
import NIOCore
import NIOSSH

/// Citadel's existing-channel initializer installs SSH handlers but returns
/// before user authentication. Hold channel creation until that real event.
enum SSHChannelAuthentication {
    enum Failure: Error, LocalizedError, Equatable {
        case timedOut, connectionClosed

        var errorDescription: String? {
            switch self {
            case .timedOut: return "SSH authentication did not complete in time."
            case .connectionClosed: return "The connection closed before SSH authentication completed."
            }
        }
    }

    /// Install while the carrier still buffers inbound SSH bytes. The observer
    /// precedes Citadel's consumer of UserAuthSuccessEvent, without replacing
    /// NIOSSH's host-key validation or authentication delegates.
    static func complete(on channel: Channel,
                         timeout: TimeAmount = .seconds(30),
                         activating: @escaping @Sendable () async throws -> Void) async throws {
        let gate = Gate(channel: channel)
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await channel.eventLoop.submit {
                    guard channel.isActive else { throw Failure.connectionClosed }
                    let ssh = try channel.pipeline.syncOperations.context(handlerType: NIOSSHHandler.self)
                    try channel.pipeline.syncOperations.addHandler(gate, position: .after(ssh.handler))
                    gate.startDeadline(timeout)
                }.get()
                let activation = Task {
                    do {
                        try Task.checkCancellation()
                        try await activating()
                        channel.eventLoop.execute { gate.activationCompleted() }
                    } catch {
                        channel.eventLoop.execute { gate.fail(error) }
                    }
                }
                defer { activation.cancel() }
                try await gate.promise.futureResult.get()
                try Task.checkCancellation()
            } catch {
                // Includes handler-install errors and cancellation before install.
                _ = try? await channel.eventLoop.submit {
                    gate.fail(error)
                    if channel.isActive { channel.close(promise: nil) }
                }.get()
                throw error
            }
        } onCancel: {
            channel.eventLoop.execute { gate.fail(CancellationError()) }
        }
    }

    final class Gate: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<Void>
        private let channel: Channel
        private var context: ChannelHandlerContext?
        private var deadline: Scheduled<Void>?
        private var authenticated = false
        private var activated = false
        private var finished = false

        init(channel: Channel) {
            self.channel = channel
            promise = channel.eventLoop.makePromise(of: Void.self)
            // NIOSSH consumes channelInactive instead of forwarding it to this
            // observer. The channel's completion still reports a real EOF, so
            // do not turn an already-closed transport into a later auth timeout.
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.fail(Failure.connectionClosed)
            }
        }

        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
        func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

        func startDeadline(_ timeout: TimeAmount) {
            channel.eventLoop.preconditionInEventLoop()
            guard !finished else { return }
            deadline = channel.eventLoop.scheduleTask(in: timeout) { self.fail(Failure.timedOut) }
        }

        func activationCompleted() {
            channel.eventLoop.preconditionInEventLoop()
            activated = true
            succeedIfReady()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            // Citadel must receive this before callers can create SSH channels.
            context.fireUserInboundEventTriggered(event)
            if event is UserAuthSuccessEvent {
                authenticated = true
                succeedIfReady()
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            // Preserve the original authentication/host-key error even if a
            // downstream consumer synchronously closes on receiving it.
            let shouldClose = settleFailure(error)
            context.fireErrorCaught(error)
            if shouldClose { channel.close(promise: nil) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            context.fireChannelInactive()
            fail(Failure.connectionClosed)
        }

        private func succeedIfReady() {
            guard !finished, authenticated, activated else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            if let context { context.pipeline.removeHandler(self, promise: nil) }
            promise.succeed(())
        }

        func fail(_ error: Error) {
            if settleFailure(error) { channel.close(promise: nil) }
        }

        private func settleFailure(_ error: Error) -> Bool {
            channel.eventLoop.preconditionInEventLoop()
            guard !finished else { return false }
            finished = true
            deadline?.cancel()
            deadline = nil
            promise.fail(error)
            return true
        }
    }
}
