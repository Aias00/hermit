import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import Moshpit

@Suite("Existing-channel SSH authentication completion")
struct SSHChannelAuthenticationTests {
    private enum Rejection: Error { case hostKey }

    @Test("Activation alone does not complete; the actual auth event reaches the consumer before success")
    func authenticatesAndForwards() async throws {
        try await withGate { channel, gate, observer in
            try await channel.eventLoop.submit {
                gate.promise.futureResult.whenSuccess { observer.completed = true }
                gate.activationCompleted()
                #expect(!observer.completed)
                channel.pipeline.fireUserInboundEventTriggered("unrelated")
                #expect(!observer.completed)
                channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
            }.get()
            try await gate.promise.futureResult.get()
            try await channel.eventLoop.submit {
                #expect(observer.authEvents == 1)
                #expect(observer.otherEvents == 1)
                #expect(observer.authEventPrecededCompletion)
                #expect(channel.isActive)
                // A late timeout/error cannot settle the completed gate twice.
                gate.fail(SSHChannelAuthentication.Failure.timedOut)
                #expect(channel.isActive)
            }.get()
        }
    }

    @Test("The original host-key/auth rejection is forwarded and closes the pending channel")
    func rejectsAndForwards() async throws {
        try await withGate { channel, gate, observer in
            try await channel.eventLoop.submit {
                gate.activationCompleted()
                channel.pipeline.fireErrorCaught(Rejection.hostKey)
            }.get()
            await #expect(throws: Rejection.self) { try await gate.promise.futureResult.get() }
            try await channel.closeFuture.get()
            try await channel.eventLoop.submit {
                #expect(observer.errors == 1)
                #expect(observer.inactiveEvents == 1)
            }.get()
        }
    }

    @Test("A silent authentication reaches its deadline and closes the channel")
    func deadlineClosesChannel() async throws {
        try await withGate(timeout: .milliseconds(30)) { channel, gate, _ in
            try await channel.eventLoop.submit { gate.activationCompleted() }.get()
            await #expect(throws: SSHChannelAuthentication.Failure.timedOut) {
                try await gate.promise.futureResult.get()
            }
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
        }
    }

    @Test("Cancellation and premature EOF resolve once, close, and cannot be revived by a late auth event")
    func cancellationAndEOF() async throws {
        for cancelled in [true, false] {
            try await withGate { channel, gate, observer in
                try await channel.eventLoop.submit {
                    if cancelled { gate.fail(CancellationError()) }
                    else { channel.close(promise: nil) }
                }.get()
                if cancelled {
                    await #expect(throws: CancellationError.self) { try await gate.promise.futureResult.get() }
                } else {
                    await #expect(throws: SSHChannelAuthentication.Failure.connectionClosed) {
                        try await gate.promise.futureResult.get()
                    }
                }
                try await channel.closeFuture.get()
                try await channel.eventLoop.submit {
                    gate.activationCompleted()
                    gate.fail(SSHChannelAuthentication.Failure.timedOut)
                    #expect(observer.inactiveEvents == 1)
                    #expect(!channel.isActive)
                }.get()
            }
        }
    }

    @Test("Cancelling complete cancels its pending activation task and closes the carrier",
          .timeLimit(.minutes(1)))
    func cancellingCompleteCancelsActivation() async throws {
        try await withChannel { channel in
            try await channel.eventLoop.submit {
                let configuration = SSHClientConfiguration(
                    userAuthDelegate: SSHAuthenticationMethod.passwordBased(username: "fixture", password: "unused"),
                    serverAuthDelegate: SSHHostKeyValidator.acceptAnything())
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .client(configuration), allocator: channel.allocator,
                    inboundChildChannelInitializer: nil))
            }.get()
            let beganActivation = channel.eventLoop.makePromise(of: Void.self)
            let cancelledActivation = channel.eventLoop.makePromise(of: Void.self)
            let pending = Task {
                try await SSHChannelAuthentication.complete(on: channel, timeout: .seconds(5)) {
                    beganActivation.succeed(())
                    do {
                        // The peer deliberately supplies no SSH banner. Only
                        // task cancellation can finish this activation early.
                        try await Task.sleep(for: .seconds(30))
                        cancelledActivation.fail(SSHChannelAuthentication.Failure.timedOut)
                    } catch {
                        cancelledActivation.succeed(())
                        throw error
                    }
                }
            }
            defer { pending.cancel() }
            try await beganActivation.futureResult.get()
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            try await cancelledActivation.futureResult.get()
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
        }
    }

    @Test("A real peer EOF behind NIOSSH is reported as closed instead of waiting for the authentication deadline",
          .timeLimit(.minutes(1)))
    func peerEOFDuringAuthentication() async throws {
        try await withChannelPair { channel, peer in
            try await channel.eventLoop.submit {
                let configuration = SSHClientConfiguration(
                    userAuthDelegate: SSHAuthenticationMethod.passwordBased(username: "fixture", password: "unused"),
                    serverAuthDelegate: SSHHostKeyValidator.acceptAnything())
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .client(configuration), allocator: channel.allocator,
                    inboundChildChannelInitializer: nil))
            }.get()
            let beganActivation = channel.eventLoop.makePromise(of: Void.self)
            let pending = Task {
                try await SSHChannelAuthentication.complete(on: channel, timeout: .milliseconds(500)) {
                    beganActivation.succeed(())
                }
            }
            defer { pending.cancel() }
            try await beganActivation.futureResult.get()
            try await peer.close().get()
            await #expect(throws: SSHChannelAuthentication.Failure.connectionClosed) {
                try await pending.value
            }
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
        }
    }

    private final class Observer: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        var completed = false
        var authEvents = 0
        var otherEvents = 0
        var authEventPrecededCompletion = false
        var errors = 0
        var inactiveEvents = 0

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is UserAuthSuccessEvent {
                authEvents += 1
                authEventPrecededCompletion = !completed
            } else { otherEvents += 1 }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { errors += 1 }
        func channelInactive(context: ChannelHandlerContext) {
            inactiveEvents += 1
            context.fireChannelInactive()
        }
    }

    /// An offline loopback channel exercises real event-loop scheduling and
    /// close propagation without an SSH server or an additional test dependency.
    private func withGate(timeout: TimeAmount = .seconds(2),
                          body: (Channel, SSHChannelAuthentication.Gate, Observer) async throws -> Void) async throws {
        try await withChannel { channel in
            let gate = SSHChannelAuthentication.Gate(channel: channel)
            let observer = Observer()
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandlers(gate, observer)
                gate.startDeadline(timeout)
            }.get()
            try await body(channel, gate, observer)
        }
    }

    private func withChannel(body: (Channel) async throws -> Void) async throws {
        try await withChannelPair { channel, _ in try await body(channel) }
    }

    private func withChannelPair(body: (Channel, Channel) async throws -> Void) async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let accepted = group.next().makePromise(of: Channel.self)
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            accepted.succeed(channel)
            return channel.eventLoop.makeSucceededVoidFuture()
        }.bind(host: "127.0.0.1", port: 0).get()
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group).connect(to: try #require(listener.localAddress)).get()
        } catch {
            try? await listener.close()
            throw error
        }
        let peer = try await accepted.futureResult.get()
        do {
            try await body(channel, peer)
        } catch {
            try? await channel.close()
            try? await peer.close()
            try? await listener.close()
            throw error
        }
        try? await channel.close()
        try? await peer.close()
        try? await listener.close()
    }
}
