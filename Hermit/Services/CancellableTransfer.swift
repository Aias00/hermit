import Foundation

/// Cancels the caller even when an SSH/NIO await ignores task cancellation.
/// The owner must also close its child channels in onCancel. A late operation
/// result is discarded; no structured task group waits for that straggler.
enum CancellableTransfer {
    static func run<Value: Sendable>(
        onCancel: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let state = State<Value>(onCancel: onCancel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation, operation: operation)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private final class State<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let onCancel: @Sendable () -> Void
        private var finished = false
        private var continuation: CheckedContinuation<Value, Error>?
        private var work: Task<Void, Never>?

        init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

        func start(_ continuation: CheckedContinuation<Value, Error>,
                   operation: @escaping @Sendable () async throws -> Value) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            work = Task {
                do {
                    try Task.checkCancellation()
                    let value = try await operation()
                    try Task.checkCancellation()
                    complete(.success(value))
                } catch { complete(.failure(error)) }
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            let work = self.work
            self.continuation = nil
            self.work = nil
            lock.unlock()
            onCancel()
            work?.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        private func complete(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            work = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
