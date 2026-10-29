import Foundation
import Testing
@testable import Moshpit

/// The liveness-probe primitive's ONE load-bearing contract: it returns at
/// the deadline no matter what the probed operation does. Every lifecycle
/// flow (keepalive, sidecar rebuild, reconnect, protocol switch) funnels
/// through guards that a single hung probe wedges forever — which is exactly
/// what happened when the old task-group implementation waited for a
/// cancellation-ignoring SSH exec on a half-open socket.
@Suite("withTimeoutValue contract")
struct TimeoutValueTests {

    private actor SuspendedOperation {
        private var continuation: CheckedContinuation<Int, Never>?
        private var finished = false

        func run() async -> Int {
            guard !finished else { return 0 }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            finished = true
            continuation?.resume(returning: 0)
            continuation = nil
        }
    }

    @Test("An op that hangs AND ignores cancellation cannot hold the caller past the deadline")
    func hangingUncancellableOpReturnsNilOnTime() async {
        let operation = SuspendedOperation()
        let started = Date()
        let result: Int? = await withTimeoutValue(0.2) {
            // Stay suspended through cancellation, like an exec bridged off
            // a NIO future. The test releases it only after the deadline wins.
            await operation.run()
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == nil)
        #expect(elapsed < 2.0, "the deadline arm must win unconditionally; \(elapsed)s means the caller waited on the straggler")
        await operation.finish()
    }

    @Test("A fast op wins and delivers its value")
    func fastOpDeliversValue() async {
        let result: String? = await withTimeoutValue(2.0) { "alive" }
        #expect(result == "alive")
    }

    @Test("A throwing op reads as nil, not a crash")
    func throwingOpIsNil() async {
        struct Boom: Error {}
        let result: Int? = await withTimeoutValue(2.0) { throw Boom() }
        #expect(result == nil)
    }

    @Test("A straggler finishing after the deadline is dropped, not double-resumed")
    func lateCompletionIsHarmless() async throws {
        let result: Int? = await withTimeoutValue(0.05) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return 42
        }
        #expect(result == nil)
        // Give the straggler time to finish resuming into the once-guard —
        // a double resume would crash the process right here.
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}
