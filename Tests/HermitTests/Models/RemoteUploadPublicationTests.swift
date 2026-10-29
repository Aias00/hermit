import Foundation
import Testing
@testable import Moshpit

#if os(macOS)
@Suite("Remote upload atomic publication")
struct RemoteUploadPublicationTests {
    enum Collision: String, CaseIterable {
        case file, directory, danglingSymlink

        var create: String {
            switch self {
            case .file: return "printf original > \"$2\""
            case .directory: return "/bin/mkdir \"$2\""
            case .danglingSymlink: return "/bin/ln -s \"$2.missing\" \"$2\""
            }
        }
    }

    @Test("A successful finish publishes all bytes and removes its staging directory")
    func completePublication() throws {
        let fixture = try Fixture()
        try fixture.prepare()
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        let reply = try fixture.run(fixture.plan.finish)
        #expect(reply.status == 0)
        #expect(reply.output.contains(RemoteFileEdits.okMarker))
        #expect(try Data(contentsOf: fixture.destination) == fixture.payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["report.txt"])
    }

    @Test("Publication refuses a newly occupied target, including a directory or dangling symlink",
          arguments: Collision.allCases, [false, true])
    func occupiedDestination(kind: Collision, raceAfterPreflight: Bool) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let path: String
        if raceAfterPreflight {
            // Create the competitor only after finish's test for existence.
            // A plain ln would incorrectly publish inside a target directory.
            path = try fixture.installLink(kind.create + "\nexec /bin/link \"$1\" \"$2\"")
        } else {
            let create = "set -- unused " + ExecUploadCommands.quote(fixture.destination.path)
                + "; " + kind.create
            #expect(try fixture.run(create).status == 0)
            path = "/usr/bin:/bin"
        }
        let reply = try fixture.run(fixture.plan.finish, path: path)
        #expect(reply.status != 0)
        #expect(!reply.output.contains(RemoteFileEdits.okMarker))
        #expect(try fixture.run(fixture.plan.cleanup).status == 0)
        switch kind {
        case .file:
            #expect(try Data(contentsOf: fixture.destination) == Data("original".utf8))
        case .directory:
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        case .danglingSymlink:
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path)
                    == fixture.destination.path + ".missing")
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path + ".missing"))
        }
    }

    @Test("A missing or failed link utility never falls back to a visible partial copy",
          arguments: [false, true])
    func failedLinkDoesNotCopy(isMissing: Bool) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let bin = fixture.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Supply only the tools used before publication, deliberately omitting
        // link; a fallback to cat would still work and fail these assertions.
        for name in ["sh", "base64", "cat", "rm", "rmdir"] {
            let system = FileManager.default.isExecutableFile(atPath: "/bin/" + name)
                ? "/bin/" + name : "/usr/bin/" + name
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(name).path,
                                                      withDestinationPath: system)
        }
        if !isMissing { _ = try fixture.installLink("exit 1") }
        let reply = try fixture.run(fixture.plan.finish, path: bin.path)
        #expect(reply.status != 0)
        #expect(!reply.output.contains(RemoteFileEdits.okMarker))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.run(fixture.plan.cleanup).status == 0)
    }

    private final class Fixture {
        let root: URL
        let destination: URL
        let payload = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let plan: RemoteFileEdits.UploadPlan

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermit-publish-\(UUID().uuidString)-it's files")
            destination = root.appendingPathComponent("report.txt")
            plan = RemoteFileEdits.upload(to: destination.path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func prepare() throws {
            #expect(try run(plan.begin).status == 0)
            #expect(try run(plan.append(payload.base64EncodedString())).status == 0)
        }

        func installLink(_ body: String) throws -> String {
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("link")
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return bin.path + ":/usr/bin:/bin"
        }

        func run(_ command: String, path: String = "/usr/bin:/bin") throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}
#endif
