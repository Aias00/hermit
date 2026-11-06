import Foundation
import Testing
@testable import Moshpit

@Suite("File upload queue", .serialized) @MainActor
struct FileUploadQueueTests {
    @Test("A failed file does not block later files; retry publishes only unfinished paths")
    func partialFailureAndRetry() async throws {
        let queue = FileUploadQueue()
        let draft = TerminalComposerDraft()
        queue.enqueue([URL(fileURLWithPath: "/first.txt"), URL(fileURLWithPath: "/bad.txt"), URL(fileURLWithPath: "/last.txt")])
        let calls = Calls()
        queue.start(upload: { url, name, progress in
            await calls.append(url.lastPathComponent)
            progress(0.5)
            if url.lastPathComponent == "bad.txt" { throw Failure.rejected }
            return "/uploads/" + name
        }, publish: { draft.text += $0 + "\n" })
        try await finished(queue)
        #expect(queue.completedCount == 2)
        #expect(queue.hasRetryableItems)
        let firstPaths = draft.text
        queue.start(retry: true, upload: { url, name, _ in
            await calls.append(url.lastPathComponent)
            return "/uploads/" + name
        }, publish: { draft.text += $0 + "\n" })
        try await finished(queue)
        #expect(queue.completedCount == 3)
        #expect(!queue.hasRetryableItems)
        #expect(draft.text.hasPrefix(firstPaths))
        #expect(draft.text.split(separator: "\n").count == 3)
        let actual = await calls.names
        #expect(actual == ["first.txt", "bad.txt", "last.txt", "bad.txt"])
    }

    @Test("Cancel returns without an unresponsive worker; late progress and success cannot affect retry")
    func cancellationAndLateCompletion() async throws {
        let queue = FileUploadQueue()
        let gate = UploadGate()
        var paths: [String] = []
        queue.enqueue([URL(fileURLWithPath: "/slow.txt"), URL(fileURLWithPath: "/next.txt")])
        queue.start(upload: { _, _, progress in
            await gate.wait(progress)
            return "/stale-path"
        }, publish: { paths.append($0) })
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        queue.cancel()
        #expect(!queue.isRunning)
        #expect(queue.items.allSatisfy { $0.state == .cancelled })
        queue.start(retry: true, upload: { url, _, _ in "/fresh/" + url.lastPathComponent },
                    publish: { paths.append($0) })
        try await finished(queue)
        await gate.release()
        for _ in 0..<25 { await Task.yield() }
        #expect(paths == ["/fresh/slow.txt", "/fresh/next.txt"])
        #expect(queue.completedCount == 2)
        #expect(!queue.isRunning)
        queue.clear()
        #expect(queue.items.isEmpty)
    }

    @Test("Cancelling or removing one in-flight file lets the next file finish; late results are ignored")
    func individualCancellationAndRemoval() async throws {
        for remove in [false, true] {
            let queue = FileUploadQueue()
            let gate = UploadGate()
            var paths: [String] = []
            queue.enqueue([URL(fileURLWithPath: "/slow.txt"), URL(fileURLWithPath: "/next.txt")])
            let slowID = queue.items[0].id
            queue.start(upload: { url, _, progress in
                if url.lastPathComponent == "slow.txt" { await gate.wait(progress) }
                return "/remote/" + url.lastPathComponent
            }, publish: { paths.append($0) })
            for _ in 0..<200 {
                if await gate.entered { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await gate.entered)
            if remove { queue.remove(itemID: slowID) } else { queue.cancel(itemID: slowID) }
            try await finished(queue)
            #expect(paths == ["/remote/next.txt"])
            #expect(queue.completedCount == 1)
            if remove { #expect(queue.items.count == 1) }
            else { #expect(queue.items.first?.state == .cancelled) }
            await gate.release()
            for _ in 0..<25 { await Task.yield() }
            #expect(paths == ["/remote/next.txt"])
        }
    }

    @Test("A queued file can be removed during an upload and individual retry leaves other failures untouched")
    func targetedRetryAndQueuedRemoval() async throws {
        let queue = FileUploadQueue()
        let gate = UploadGate()
        queue.enqueue([URL(fileURLWithPath: "/active.txt"), URL(fileURLWithPath: "/removed.txt"), URL(fileURLWithPath: "/last.txt")])
        let removedID = queue.items[1].id
        var paths: [String] = []
        queue.start(upload: { url, _, progress in
            if url.lastPathComponent == "active.txt" { await gate.wait(progress) }
            throw Failure.rejected
        }, publish: { paths.append($0) })
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        queue.remove(itemID: removedID)
        await gate.release()
        try await finished(queue)
        #expect(queue.items.count == 2 && queue.completedCount == 0)
        let retryID = queue.items[1].id
        queue.start(retry: true, itemID: retryID, upload: { url, _, _ in "/remote/" + url.lastPathComponent },
                    publish: { paths.append($0) })
        try await finished(queue)
        #expect(paths == ["/remote/last.txt"])
        #expect(queue.items[0].state.canRetry)
        queue.remove(itemID: retryID)
        #expect(paths == ["/remote/last.txt"], "removing history must not modify the draft or delete remote files")
    }

    @Test("Upload completion stays with the captured connection draft when another draft is selected")
    func completionOwnership() async throws {
        let first = TerminalComposerDraft()
        let second = TerminalComposerDraft()
        second.text = "other host"
        let gate = UploadGate()
        first.uploads.enqueue([URL(fileURLWithPath: "/first-host.txt")])
        first.uploads.start(upload: { _, _, progress in
            await gate.wait(progress)
            return "/first-host/path"
        }, publish: { [weak first] path in first?.text += path })
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await gate.release()
        try await finished(first.uploads)
        #expect(first.text == "/first-host/path")
        #expect(second.text == "other host")
    }

    @Test("Source validation rejects directories and files over 20 MB")
    func validatesSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("large")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 20 * 1024 * 1024 + 1)
        try handle.close()
        for url in [root, big] {
            do { _ = try await FileUploadQueue.readFile(url); Issue.record("must reject invalid source") }
            catch { #expect(error is LocalizedError) }
        }
        let small = root.appendingPathComponent("small")
        try Data("valid".utf8).write(to: small)
        #expect(try await FileUploadQueue.readFile(small) == Data("valid".utf8))
        let queue = FileUploadQueue()
        queue.enqueue([small, root])
        #expect(queue.items[0].source.byteCount == 5)
        #expect(queue.items[1].source.byteCount == nil)
    }

    private func finished(_ queue: FileUploadQueue) async throws {
        for _ in 0..<400 {
            if !queue.isRunning { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("upload queue did not settle")
        queue.cancel()
    }
    private enum Failure: Error { case rejected }
    private actor Calls {
        var names: [String] = []
        func append(_ name: String) { names.append(name) }
    }
    private actor UploadGate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var progress: (@Sendable (Double) -> Void)?
        func wait(_ progress: @escaping @Sendable (Double) -> Void) async {
            self.progress = progress
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            progress?(1)
            continuation?.resume()
            continuation = nil
        }
    }
}
