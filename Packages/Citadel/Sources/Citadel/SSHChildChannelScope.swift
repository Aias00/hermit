import Foundation
import NIO
import NIOConcurrencyHelpers

/// Owns only the SSH child channels opened for one operation.
///
/// Canceling a scope never closes its parent SSH connection. Cancellation is
/// sticky: a child created after cancellation is immediately closed, and no
/// further request may be submitted through this scope. The caller remains
/// responsible for racing non-cooperative waits against task cancellation and
/// calling `cancel()` on completion to release any remaining children.
public final class SSHChildChannelScope: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var channels: [ObjectIdentifier: Channel] = [:]
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    public func checkCancellation() throws {
        try runIfActive {}
    }

    /// Initiates child-channel shutdown without waiting for the peer to reply.
    /// Safe to invoke from a task cancellation handler and safe to repeat.
    public func cancel() {
        let channels = state.withLockedValue { state -> [Channel] in
            guard !state.cancelled else { return [] }
            state.cancelled = true
            let channels = Array(state.channels.values)
            state.channels.removeAll()
            return channels
        }
        // Never execute channel callbacks while holding the state lock.
        for channel in channels {
            channel.close(promise: nil)
        }
    }

    /// Registers a child before any subsystem or command request is sent.
    /// A late child must not outlive an already canceled operation.
    @discardableResult
    internal func register(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        let accepted = state.withLockedValue { state -> Bool in
            guard !state.cancelled else { return false }
            state.channels[id] = channel
            return true
        }
        guard accepted else {
            channel.close(promise: nil)
            return false
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            // A close can occur synchronously while runIfActive submits an
            // outbound operation. Defer removal to avoid reentering its lock.
            channel.eventLoop.execute { [weak self] in
                _ = self?.state.withLockedValue { $0.channels.removeValue(forKey: id) }
            }
        }
        return true
    }

    /// Atomically checks cancellation and submits a synchronous operation.
    /// Keep the body short; do not await or call back into the scope from it.
    internal func runIfActive<Result>(_ body: () throws -> Result) throws -> Result {
        try state.withLockedValue { state in
            guard !state.cancelled else { throw CancellationError() }
            return try body()
        }
    }

    /// Submit on the channel's event loop so cancellation is checked when the
    /// request is actually enqueued, rather than before an event-loop hop.
    internal func submit<Result: Sendable>(
        on channel: Channel,
        _ body: @escaping () -> EventLoopFuture<Result>
    ) async throws -> Result {
        try await channel.eventLoop.flatSubmit {
            do {
                return try self.runIfActive(body)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.get()
    }
}
