import Foundation
import Testing
@testable import Moshpit

@Suite("File transfer cancellation and publication")
struct RemoteTransferTests {
    private enum Failure: Error { case interrupted }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A failed transfer preserves the existing file and removes its partial bytes")
    func failedDownloadKeepsExistingCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: destination)
        await #expect(throws: Failure.self) {
            try await LocalTransferFile.write(to: destination) { staged in
                try Data("unfinished".utf8).write(to: staged)
                throw Failure.interrupted
            }
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["report.txt"])
    }

    @Test("Cancellation after the final network response never publishes its bytes")
    func cancelledDownloadDoesNotPublish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        let gate = Gate()
        let work = Task {
            try await LocalTransferFile.write(to: destination) { staged in
                try Data("complete but cancelled".utf8).write(to: staged)
                await gate.wait()
            }
        }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Overlapping thumbnail and open requests cannot clean up each other's download")
    func overlappingAttemptsOwnDifferentStagingFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        let gate = Gate()
        let first = Task {
            try await LocalTransferFile.write(to: destination) { staged in
                try Data("partial".utf8).write(to: staged)
                await gate.wait()
                throw Failure.interrupted
            }
        }
        await gate.waitUntilEntered()
        try await LocalTransferFile.write(to: destination) { staged in
            try Data("complete".utf8).write(to: staged)
        }
        await gate.release()
        await #expect(throws: Failure.self) { try await first.value }
        #expect(try Data(contentsOf: destination) == Data("complete".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["report.txt"])
    }

    @Test("A successful transfer atomically replaces a previous longer copy")
    func successfulReplacementHasNoOldTail() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        try Data(repeating: 7, count: 1000).write(to: destination)
        try await LocalTransferFile.write(to: destination) { staged in
            try Data([1, 2, 3]).write(to: staged)
            #expect(try Data(contentsOf: destination).count == 1000)
        }
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
    }

    @MainActor
    @Test("Cancelling a folder batch stops queued files even if dialing returns a different error")
    func cancelledBatchDoesNotStartNextFile() async throws {
        let gate = Gate()
        let calls = Counter()
        let model = RemoteFolderModel(
            folder: .init(path: "/tmp/folder", isDirectory: true, size: nil, modified: nil),
            files: .init(scope: UUID().uuidString, channel: {
                await calls.increment()
                await gate.wait()
                throw SSHError.sessionClosed
            }))
        model.startUpload(files: [URL(fileURLWithPath: "/tmp/first.txt"),
                                 URL(fileURLWithPath: "/tmp/second.txt")])
        await gate.waitUntilEntered()
        #expect(model.uploadName == "first.txt")
        model.cancelUpload()
        #expect(model.cancellingUpload)
        await gate.release()
        for _ in 0..<1000 where model.uploading != nil { await Task.yield() }
        #expect(model.uploading == nil)
        #expect(model.editFailure == nil)
        #expect(await calls.value == 1, "no next upload or post-cancel directory reload")
        model.startUpload(files: [URL(fileURLWithPath: "/tmp/retry.txt")])
        #expect(!model.cancellingUpload)
        for _ in 0..<1000 where model.uploading != nil { await Task.yield() }
        #expect(model.uploading == nil)
        #expect(await calls.value >= 2, "the completed cancellation must release the batch slot")
    }

    @Test("Cancelling an exec upload cleans only its scratch files and never starts its finish command")
    func cancelledExecUploadCleansScratch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("input.txt")
        try Data(repeating: 17, count: 100_000).write(to: local)
        let gate = Gate()
        let transport = UploadTransport(gate: gate)
        let session = SSHSession(
            connection: ServerConnection(name: "test", host: "192.0.2.1", username: "test"),
            transport: transport)
        let work = Task { try await session.uploadRemoteFile(from: local, to: "/tmp/remote.txt") }
        await gate.waitUntilEntered()
        work.cancel()
        let outcome = await withTimeoutValue(2) {
            do { try await work.value; return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        #expect(outcome == true, "cancel returns while the chunk reply is still withheld")
        #expect(await transport.shutdownCount == 0, "the shared SSH parent must stay alive")
        await gate.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        for _ in 0..<200 {
            if await transport.commands.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let commands = await transport.commands
        #expect(commands.count == 3, "one begin, one chunk, then cleanup")
        #expect(!commands.contains { $0.contains("base64 -d") }, "no decode/publish after cancellation")
        #expect(commands.last?.contains("rm -f --") == true)
        #expect(commands.last?.contains(".b64part") == true)
        await session.close()
    }

    @Test("An unresponsive cleanup cannot keep the caller in cancelling state forever")
    func hungCleanupHasDeadline() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("input.txt")
        try Data([1, 2, 3]).write(to: local)
        let chunkGate = Gate()
        let cleanupGate = Gate()
        let transport = UploadTransport(gate: chunkGate, cleanupGate: cleanupGate)
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let work = Task { try await session.uploadRemoteFile(from: local, to: "/tmp/remote.txt") }
        await chunkGate.waitUntilEntered()
        work.cancel()
        await chunkGate.release()
        await cleanupGate.waitUntilEntered()
        let started = Date()
        let outcome = await withTimeoutValue(3) {
            do { try await work.value; return "unexpected success" }
            catch is CancellationError { return "cancelled" }
            catch { return "unexpected error" }
        }
        #expect(outcome == "cancelled")
        #expect(Date().timeIntervalSince(started) < 2.5)
        // Release the deliberately non-cooperative straggler after asserting
        // that the caller has already returned; it cannot affect another batch.
        await cleanupGate.release()
        _ = try? await work.value
        await session.close()
    }

    @Test("A failed or unconfirmed begin never enables remote scratch cleanup")
    func failedBeginHasNoCleanupOwnership() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("input.txt")
        try Data([1, 2, 3]).write(to: local)
        let transport = UploadTransport(gate: Gate(), failBegin: true)
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        await #expect(throws: SSHError.self) {
            try await session.uploadRemoteFile(from: local, to: "/tmp/remote.txt")
        }
        let commands = await transport.commands
        #expect(commands.count == 1)
        #expect(commands.first?.contains("mkdir -m 700") == true)
        await session.close()
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor UploadTransport: SSHClientTransport {
        let gate: Gate
        let cleanupGate: Gate?
        let failBegin: Bool
        private(set) var commands: [String] = []
        private(set) var shutdownCount = 0
        init(gate: Gate, cleanupGate: Gate? = nil, failBegin: Bool = false) {
            self.gate = gate
            self.cleanupGate = cleanupGate
            self.failBegin = failBegin
        }
        func run(_ command: String) async throws -> Data {
            commands.append(command)
            if failBegin, command.contains("mkdir -m 700") { throw Failure.interrupted }
            // The fake chunk deliberately ignores cancellation, just like a
            // request whose response was already queued when Cancel was tapped.
            if command.contains("printf %s") { await gate.wait() }
            if command.contains("rm -f --"), let cleanupGate { await cleanupGate.wait() }
            return Data("MOSHPIT_EDIT_OK\n".utf8)
        }
        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            throw SSHError.ptyNotReady
        }
        func shutdown() async { shutdownCount += 1 }
    }

    private actor Gate {
        private var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            observers.forEach { $0.resume() }
            observers.removeAll()
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
}
