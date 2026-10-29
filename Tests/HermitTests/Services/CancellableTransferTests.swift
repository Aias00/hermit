import Foundation
import Testing
@testable import Moshpit

@Suite("Cancellable transfer contract")
struct CancellableTransferTests {
    private enum Failure: Error { case interrupted }
    private enum Outcome: Equatable, Sendable {
        case value(Int)
        case cancelled
        case interrupted
        case unexpectedError
    }

    @Test("Cancellation returns before an unresponsive operation, discarding its late result",
          arguments: [false, true])
    func unresponsiveOperationCannotHoldCancellation(throwsLate: Bool) async {
        let gate = Gate()
        let cancellations = Counter()
        let completions = Counter()
        let cancelledWorkers = Counter()
        let work = Task {
            await Self.outcome {
                try await CancellableTransfer.run(onCancel: { cancellations.increment() }) {
                    // No cancellation handler or throwing suspension: this
                    // represents a network future that never acknowledges Cancel.
                    await gate.wait()
                    if Task.isCancelled { cancelledWorkers.increment() }
                    completions.increment()
                    if throwsLate { throw Failure.interrupted }
                    return 42
                }
            }
        }

        let entered = await withTimeoutValue(2) { await gate.waitUntilEntered() }
        #expect(entered == true)
        work.cancel()
        work.cancel()

        // An outer deadline keeps a regression from hanging the test process.
        // The gate is still closed when the caller must report cancellation.
        let result = await withTimeoutValue(2) { await work.value }
        #expect(result == .cancelled)
        #expect(completions.value == 0)
        #expect(cancellations.value == 1)

        await gate.release()
        #expect(await eventually { completions.value == 1 })
        #expect(cancelledWorkers.value == 1, "the abandoned operation task must also be cancelled")
        // Let its completion race run into the already-finished state. A late
        // success/error must neither replace cancellation nor double-resume.
        for _ in 0..<20 { await Task.yield() }
        let afterLateResult = await withTimeoutValue(2) { await work.value }
        #expect(afterLateResult == .cancelled)
        #expect(cancellations.value == 1)
    }

    @MainActor
    @Test("An already-cancelled caller never starts the operation")
    func cancellationBeforeStartSkipsOperation() async {
        let starts = Counter()
        let cancellations = Counter()
        let work = Task { @MainActor in
            await Self.outcome {
                try await CancellableTransfer.run(onCancel: { cancellations.increment() }) {
                    starts.increment()
                    return 42
                }
            }
        }
        // The task cannot run until this main-actor turn suspends.
        work.cancel()
        work.cancel()
        let result = await withTimeoutValue(2) { await work.value }
        #expect(result == .cancelled)
        #expect(starts.value == 0)
        #expect(cancellations.value == 1)
    }

    @Test("Successful completion returns the value without running cancellation cleanup")
    func successDoesNotCancel() async {
        let starts = Counter()
        let cancellations = Counter()
        let work = Task {
            await Self.outcome {
                try await CancellableTransfer.run(onCancel: { cancellations.increment() }) {
                    starts.increment()
                    return 42
                }
            }
        }
        let result = await withTimeoutValue(2) { await work.value }
        #expect(result == .value(42))
        #expect(starts.value == 1)
        #expect(cancellations.value == 0)
        work.cancel()
        #expect(cancellations.value == 0, "cancelling a completed caller must not clean up a successful transfer")
    }

    @Test("An ordinary operation error is preserved without cancellation cleanup")
    func failurePreservesError() async {
        let cancellations = Counter()
        let result = await withTimeoutValue(2) {
            await Self.outcome {
                try await CancellableTransfer.run(onCancel: { cancellations.increment() }) {
                    throw Failure.interrupted
                }
            }
        }
        #expect(result == .interrupted)
        #expect(cancellations.value == 0)
    }

    private static func outcome(_ operation: @Sendable () async throws -> Int) async -> Outcome {
        do { return .value(try await operation()) }
        catch is CancellationError { return .cancelled }
        catch Failure.interrupted { return .interrupted }
        catch { return .unexpectedError }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private actor Gate {
        private var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Bool, Never>] = []

        func wait() async {
            entered = true
            observers.forEach { $0.resume(returning: true) }
            observers.removeAll()
            if !released { await withCheckedContinuation { waiter = $0 } }
        }

        func waitUntilEntered() async -> Bool {
            if entered { return true }
            if released { return false }
            return await withCheckedContinuation { observers.append($0) }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
            // Also finish an observer if a regression prevented the operation
            // from starting at all; no test-created continuation remains parked.
            observers.forEach { $0.resume(returning: entered) }
            observers.removeAll()
        }
    }
}
