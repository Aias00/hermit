import Foundation
import Testing
@testable import Moshpit

@Suite("Folder upload cancellation", .serialized)
@MainActor
struct RemoteFolderCancellationTests {
    @Test("Cancel releases a batch before its dial returns, and late channels cannot upload")
    func cancelledDialCannotAffectReplacementBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("first.txt")
        try Data("upload me".utf8).write(to: local)

        let oldDial = DialGate()
        let replacementDial = DialGate()
        let calls = Counter()
        let transport = RecordingTransport()
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let model = RemoteFolderModel(
            folder: .init(path: "/tmp/folder", isDirectory: true, size: nil, modified: nil),
            files: .init(scope: UUID().uuidString, channel: {
                let call = await calls.increment()
                if call == 1 { await oldDial.wait() }
                else if call == 2 { await replacementDial.wait() }
                else { throw SSHError.sessionClosed }
                // A real, usable session arrives even if the waiter was cancelled.
                return session
            }))

        model.startUpload(files: [local, root.appendingPathComponent("queued.txt")])
        #expect(await eventually { await oldDial.entered })
        #expect(model.uploadName == "first.txt")
        model.cancelUpload()
        #expect(model.cancellingUpload)

        // Deliberately do not release the dial: cancellation must not need a
        // response from the server to stop this batch or free its UI slot.
        #expect(await eventually { model.uploading == nil })
        #expect(!model.cancellingUpload)
        #expect(model.uploadName == nil)
        #expect(model.editFailure == nil)
        #expect(await calls.value == 1, "the queued file and a directory reload must not start")

        model.startUpload(files: [local])
        #expect(await eventually { await replacementDial.entered })
        #expect(model.uploadName == "first.txt", "the cancelled name reservation must be released")
        #expect(model.uploading == 0)
        #expect(!model.cancellingUpload)

        await oldDial.release()
        #expect(await eventually { await oldDial.exited })
        await drainScheduledWork()
        #expect(await transport.commands.isEmpty, "the late session must not start any remote upload")
        #expect(model.uploadName == "first.txt")
        #expect(model.uploading == 0, "an old completion must not retire the replacement batch")
        #expect(model.editFailure == nil)
        #expect(await calls.value == 2)

        model.cancelUpload()
        #expect(await eventually { model.uploading == nil })
        await replacementDial.release()
        #expect(await eventually { await replacementDial.exited })
        await drainScheduledWork()
        #expect(await transport.commands.isEmpty)
        #expect(model.uploading == nil)
        #expect(model.editFailure == nil)
        #expect(await calls.value == 2)
        await session.close()
    }

    @Test("Cancelling before the upload task starts releases its slot without dialing")
    func cancelBeforeFirstTaskTurn() async {
        let gate = DialGate()
        let calls = Counter()
        let model = RemoteFolderModel(
            folder: .init(path: "/tmp/folder", isDirectory: true, size: nil, modified: nil),
            files: .init(scope: UUID().uuidString, channel: {
                await calls.increment()
                await gate.wait()
                throw SSHError.sessionClosed
            }))

        // There is no suspension between starting and cancelling, so the
        // task cannot have entered its first main-actor turn yet.
        model.startUpload(files: [URL(fileURLWithPath: "/tmp/first.txt")])
        model.cancelUpload()
        #expect(model.cancellingUpload)
        #expect(await eventually { model.uploading == nil })
        #expect(await calls.value == 0)
        #expect(model.editFailure == nil)

        model.startUpload(files: [URL(fileURLWithPath: "/tmp/retry.txt")])
        #expect(await eventually { await gate.entered })
        #expect(model.uploadName == "retry.txt")
        #expect(!model.cancellingUpload)
        model.cancelUpload()
        #expect(await eventually { model.uploading == nil })
        await gate.release()
        #expect(await eventually { await gate.exited })
        await drainScheduledWork()
        #expect(await calls.value == 1)
        #expect(model.uploadName == nil)
        #expect(model.editFailure == nil)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func drainScheduledWork() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private actor Counter {
        private(set) var value = 0
        @discardableResult
        func increment() -> Int {
            value += 1
            return value
        }
    }

    /// Intentionally ignores task cancellation, as an in-flight dial can.
    private actor DialGate {
        private(set) var entered = false
        private(set) var exited = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { waiter = $0 } }
            exited = true
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private actor RecordingTransport: SSHClientTransport {
        private(set) var commands: [String] = []

        func run(_ command: String) async throws -> Data {
            commands.append(command)
            return Data("MOSHPIT_EDIT_OK\n".utf8)
        }

        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            throw SSHError.ptyNotReady
        }

        func shutdown() async {}
    }
}
