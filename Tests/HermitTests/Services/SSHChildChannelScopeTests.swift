import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import Citadel

@Suite("SSH upload child channel cancellation")
struct SSHChildChannelScopeTests {
    // Keep these tests synchronous: EmbeddedEventLoop is confined to the
    // creating thread. Its channels use no sockets and contact no SSH server.
    private func activeChannel(on loop: EmbeddedEventLoop) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        #expect(channel.isActive)
        return channel
    }

    @Test("Cancel closes owned upload channels and preserves the connection and sibling channels")
    func cancellationIsLimitedToOwnedChannels() throws {
        let loop = EmbeddedEventLoop()
        // Separate live NIO channels stand in for the connection, terminal,
        // preview, and two children created by this upload. Only the upload
        // children are registered with this cancellation scope.
        let connection = try activeChannel(on: loop)
        let terminal = try activeChannel(on: loop)
        let preview = try activeChannel(on: loop)
        let uploadSFTP = try activeChannel(on: loop)
        let uploadExec = try activeChannel(on: loop)
        let channels = [connection, terminal, preview, uploadSFTP, uploadExec]
        defer { for channel in channels { _ = try? channel.finish(acceptAlreadyClosed: true) } }
        let scope = SSHChildChannelScope()
        #expect(scope.register(uploadSFTP))
        #expect(scope.register(uploadExec))

        scope.cancel()
        loop.run()

        #expect(!uploadSFTP.isActive)
        #expect(!uploadExec.isActive)
        #expect(connection.isActive)
        #expect(terminal.isActive)
        #expect(preview.isActive)
        #expect(throws: CancellationError.self) { try scope.checkCancellation() }

        // Unrelated channels remain usable, beyond merely reporting active.
        try terminal.writeOutbound(ByteBuffer(string: "terminal still usable"))
        let output = try terminal.readOutbound(as: ByteBuffer.self)
        #expect(output == ByteBuffer(string: "terminal still usable"))
    }

    @Test("A child that arrives after cancellation is immediately closed and rejected")
    func lateRegistrationCannotLeakAChannel() throws {
        let loop = EmbeddedEventLoop()
        let scope = SSHChildChannelScope()
        scope.cancel()
        let lateChild = try activeChannel(on: loop)
        defer { _ = try? lateChild.finish(acceptAlreadyClosed: true) }

        #expect(!scope.register(lateChild))
        loop.run()

        #expect(!lateChild.isActive)
        #expect(throws: CancellationError.self) { try scope.checkCancellation() }
    }

    @Test("Cancellation rejects a later request before its submission closure runs")
    func cancelledScopeDoesNotSubmitAnotherStage() throws {
        let scope = SSHChildChannelScope()
        var submittedStages: [String] = []
        try scope.runIfActive { submittedStages.append("begin") }
        scope.cancel()

        #expect(throws: CancellationError.self) {
            try scope.runIfActive { submittedStages.append("publish") }
        }

        #expect(submittedStages == ["begin"])
    }

    @Test("Repeated registration and cancellation close each child only once")
    func repeatedCancellationIsSafe() throws {
        let loop = EmbeddedEventLoop()
        let lifecycle = LifecycleRecorder()
        let channel = EmbeddedChannel(handler: lifecycle, loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        let scope = SSHChildChannelScope()
        #expect(scope.register(channel))
        #expect(scope.register(channel))

        scope.cancel()
        scope.cancel()
        loop.run()
        scope.cancel()

        #expect(!channel.isActive)
        #expect(lifecycle.inactiveCount == 1)
        #expect(throws: CancellationError.self) { try scope.checkCancellation() }
        try channel.throwIfErrorCaught()
    }

    @Test("A child that finishes normally does not prevent later scope cancellation")
    func normallyClosedChildCanBeRemovedBeforeCancellation() throws {
        let loop = EmbeddedEventLoop()
        let completed = try activeChannel(on: loop)
        let pending = try activeChannel(on: loop)
        defer {
            _ = try? completed.finish(acceptAlreadyClosed: true)
            _ = try? pending.finish(acceptAlreadyClosed: true)
        }
        let scope = SSHChildChannelScope()
        #expect(scope.register(completed))
        #expect(scope.register(pending))
        try completed.close().wait()
        loop.run()
        try scope.checkCancellation()
        #expect(pending.isActive)

        scope.cancel()
        loop.run()

        #expect(!completed.isActive)
        #expect(!pending.isActive)
        try completed.throwIfErrorCaught()
        try pending.throwIfErrorCaught()
    }

    private final class LifecycleRecorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private(set) var inactiveCount = 0

        func channelInactive(context: ChannelHandlerContext) {
            inactiveCount += 1
            context.fireChannelInactive()
        }
    }
}
