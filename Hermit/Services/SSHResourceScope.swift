/// Scope an SSH subresource without allowing failed cleanup to replace the
/// operation's original error (especially cancellation or a transport failure).
/// A cleanup failure after a successful operation is still reported.
enum SSHResourceScope {
    static func withCleanup<Value: Sendable>(
        operation: @Sendable () async throws -> Value,
        cleanup: @Sendable () async throws -> Void
    ) async throws -> Value {
        let value: Value
        do {
            value = try await operation()
        } catch {
            try? await cleanup()
            throw error
        }
        try await cleanup()
        return value
    }
}
