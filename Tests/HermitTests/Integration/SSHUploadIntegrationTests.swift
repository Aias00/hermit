import Foundation
import Testing
@testable import Moshpit

/// Runs only against the opt-in loopback sshd used by SSHExecInputIntegrationTests.
/// Every synthetic file stays beneath fixture_dir/<UUID>; credentials are read
/// from the fixture and never printed or placed in remote command arguments.
@Suite("SSH upload integration", .tags(.integration), .serialized)
struct SSHUploadIntegrationTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["MOSHPIT_FIX_SSH_FIXTURE"]
    private static let isConfigured = fixturePath?.isEmpty == false

    private struct Fixture: Decodable, Sendable {
        let host: String
        let port: Int
        let username: String
        let privateKeyPath: String
        let hostKeyFingerprint: String
        let fixtureDirectory: String

        enum CodingKeys: String, CodingKey {
            case host, port, username
            case privateKeyPath = "private_key_path"
            case hostKeyFingerprint = "host_key_fingerprint"
            case fixtureDirectory = "fixture_dir"
        }
    }

    @Test("SFTP cancellation preserves the PTY and preview; publication is complete and never overwrites",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func uploadLifecycleOverRealSSH() async throws {
        let fixturePath = try #require(Self.fixturePath)
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        try #require(fixture.host == "127.0.0.1" && (1...65535).contains(fixture.port))
        try #require(fixture.fixtureDirectory.hasPrefix("/") && fixture.fixtureDirectory != "/")
        let root = URL(fileURLWithPath: fixture.fixtureDirectory).resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("source.bin")
        let original = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try original.write(to: local)
        let remoteDirectory = root.appendingPathComponent("remote", isDirectory: true).path
        let previewPath = remoteDirectory + "/preview.txt"
        let cancelledPath = remoteDirectory + "/cancelled.bin"
        let publishedPath = remoteDirectory + "/published.bin"
        let quote = ExecUploadCommands.quote
        let privateKey = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory())
        let connection = ServerConnection(name: "upload-loopback-fixture", host: fixture.host,
            port: fixture.port, username: fixture.username, authMethod: .key, connectionProtocol: .ssh)
        let connected = await withTimeoutValue(15) {
            try await service.connect(connection, overrideSecret: privateKey,
                onUnknownHost: { host, port, fingerprint in
                    host == fixture.host && port == fixture.port && fingerprint == fixture.hostKeyFingerprint
                }, onChangedHost: { _, _, _, _ in false })
        }
        let session = try #require(connected, "Loopback SSH must authenticate with the fixture key")
        let output = TerminalOutput()
        let pump = Task {
            for await chunk in session.dataStream { await output.append(chunk) }
        }
        defer { pump.cancel() }

        do {
            let prepared = await withTimeoutValue(8) {
                _ = try await session.executeCommand("mkdir -m 700 -- \(quote(remoteDirectory)) && printf %s 'preview survives cancellation' > \(quote(previewPath))")
                try await session.requestPTY(rows: 24, cols: 80)
                return true
            }
            try #require(prepared == true)
            let opened = await withTimeoutValue(5) { try await session.openRemoteFile(previewPath) }
            let preview = try #require(opened, "Open a real SFTP preview before the upload starts")

            let gate = CancelAfterFirstChunk()
            let upload = Task {
                try await session.uploadRemoteFile(from: local, to: cancelledPath,
                                                   progress: { gate.observe($0) })
            }
            gate.install { upload.cancel() }
            defer { upload.cancel() }
            let outcome = await withTimeoutValue(10) {
                do { try await upload.value; return "success" }
                catch is CancellationError { return "cancelled" }
                catch { return "other failure" }
            }
            #expect(outcome == "cancelled")
            let cancellation = try #require(gate.snapshot)
            #expect(cancellation.fraction == Double(128 * 1024) / Double(original.count),
                    "Cancel after the first acknowledged SFTP chunk, not an exec fallback")
            #expect(Date().timeIntervalSince(cancellation.time) < 2,
                    "The upload caller must return within two seconds of cancellation")
            #expect(await session.isConnected)

            // Read through the very same SFTP file opened before cancellation.
            // Opening a replacement reader here could hide an incorrectly closed sibling.
            let previewBytes = await withTimeoutValue(3) { try await preview.read(from: 0, length: 128) }
            #expect(previewBytes == Array("preview survives cancellation".utf8))
            let exec = await withTimeoutValue(3) { try await session.executeCommand("printf %s EXEC_SURVIVED") }
            #expect(exec == Data("EXEC_SURVIVED".utf8))
            let terminalAlive = await withTimeoutValue(4) {
                // Control delimiters are produced by printf, never by the PTY's
                // echoed command text, so echo alone cannot satisfy the test.
                try await session.writeText("stty -echo; printf '\\036UPLOAD_PTY_SURVIVED\\037\\n'\n")
                while !Task.isCancelled {
                    if await output.contains("\u{1e}UPLOAD_PTY_SURVIVED\u{1f}") { return true }
                    try await Task.sleep(for: .milliseconds(25))
                }
                return false
            }
            #expect(terminalAlive == true)
            let afterCancellation = try #require(await settledEntries(in: remoteDirectory, session: session))
            #expect(afterCancellation.map(\.path).sorted() == [previewPath],
                    "A cancelled upload must publish no target and leave no scratch directory")

            let uploaded = await withTimeoutValue(10) {
                try await session.uploadRemoteFile(from: local, to: publishedPath)
                return true
            }
            try #require(uploaded == true)
            let downloaded = root.appendingPathComponent("downloaded.bin")
            let readBack = await withTimeoutValue(8) {
                try await session.downloadRemoteFile(publishedPath, to: downloaded)
                return true
            }
            try #require(readBack == true)
            #expect(try Data(contentsOf: downloaded) == original)

            let replacement = root.appendingPathComponent("replacement.bin")
            try Data("must not replace the original".utf8).write(to: replacement)
            let refused = await withTimeoutValue(8) {
                do {
                    try await session.uploadRemoteFile(from: replacement, to: publishedPath)
                    return false
                } catch { return true }
            }
            #expect(refused == true, "Uploading an existing name must fail without replacing its bytes")
            let preserved = await withTimeoutValue(8) {
                try await session.downloadRemoteFile(publishedPath, to: downloaded)
                return true
            }
            try #require(preserved == true)
            #expect(try Data(contentsOf: downloaded) == original)
            let finalEntries = try #require(await settledEntries(in: remoteDirectory, session: session))
            #expect(finalEntries.map(\.path).sorted() == [previewPath, publishedPath].sorted(),
                    "Successful and refused uploads must both remove their private scratch directories")
            _ = await withTimeoutValue(2) { await preview.close(); return true }
            let closed = await withTimeoutValue(3) { await session.close(); return true }
            #expect(closed == true)
        } catch {
            _ = await withTimeoutValue(3) { await session.close(); return true }
            throw error
        }
    }

    private func settledEntries(in path: String, session: SSHSession) async -> [RemoteFileEntry]? {
        await withTimeoutValue(5) {
            while !Task.isCancelled {
                let entries = try await session.listRemoteDirectory(path)
                if !entries.contains(where: { ($0.path as NSString).lastPathComponent.hasPrefix(".hermit-upload-") }) {
                    return entries
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        }
    }

    /// Progress runs synchronously after a write acknowledgement. Cancel from
    /// that callback before the upload can enter its next write or publication.
    /// Installing the task late is safe: a recorded first chunk remains armed.
    private final class CancelAfterFirstChunk: @unchecked Sendable {
        struct Snapshot: Sendable {
            let fraction: Double
            let time: Date
        }
        private let lock = NSLock()
        private var cancel: (@Sendable () -> Void)?
        private var firstChunk: Snapshot?
        var snapshot: Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            return firstChunk
        }
        func install(_ cancellation: @escaping @Sendable () -> Void) {
            lock.lock()
            cancel = cancellation
            let alreadyObserved = firstChunk != nil
            lock.unlock()
            if alreadyObserved { cancellation() }
        }
        func observe(_ fraction: Double) {
            lock.lock()
            guard firstChunk == nil, fraction > 0, fraction < 1 else { lock.unlock(); return }
            firstChunk = Snapshot(fraction: fraction, time: Date())
            let cancellation = cancel
            lock.unlock()
            cancellation?()
        }
    }

    private actor TerminalOutput {
        private var text = ""
        func append(_ data: Data) {
            text += String(decoding: data, as: UTF8.self)
            if text.count > 65_536 { text = String(text.suffix(65_536)) }
        }
        func contains(_ marker: String) -> Bool { text.contains(marker) }
    }
}
