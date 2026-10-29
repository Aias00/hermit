import Testing
@testable import Moshpit

@Suite("SSH subresource cleanup errors")
struct SSHResourceScopeTests {
    private enum Failure: Error, Equatable { case operation, fileClose, channelClose }

    @Test("A failed SFTP operation keeps its error when file and channel cleanup also fail")
    func nestedCleanupKeepsOperationError() async {
        let calls = Count()
        await #expect(throws: Failure.operation) {
            try await SSHResourceScope.withCleanup(operation: {
                try await SSHResourceScope.withCleanup(operation: { () async throws -> Void in
                    throw Failure.operation
                }, cleanup: {
                    await calls.increment()
                    throw Failure.fileClose
                })
            }, cleanup: {
                await calls.increment()
                throw Failure.channelClose
            })
        }
        #expect(await calls.value == 2)
    }

    @Test("Cancellation cannot become a cleanup failure that enters an exec fallback")
    func cleanupPreservesCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await SSHResourceScope.withCleanup(operation: { () async throws -> Void in
                throw CancellationError()
            }, cleanup: { throw Failure.channelClose })
        }
    }

    @Test("A successful operation still reports a failed close exactly once")
    func successfulOperationDoesNotHideCleanupFailure() async {
        let calls = Count()
        await #expect(throws: Failure.fileClose) {
            try await SSHResourceScope.withCleanup(operation: { "written" }, cleanup: {
                await calls.increment()
                throw Failure.fileClose
            })
        }
        #expect(await calls.value == 1)
    }

    @Test("Successful cleanup preserves the operation result")
    func success() async throws {
        let calls = Count()
        let value = try await SSHResourceScope.withCleanup(operation: { "result" }, cleanup: {
            await calls.increment()
        })
        #expect(value == "result")
        #expect(await calls.value == 1)
    }

    private actor Count {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
