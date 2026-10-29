#if DEBUG && targetEnvironment(simulator)
import Foundation
import Testing
@testable import Moshpit

@Suite("Simulator Access public-key handoff files")
struct CloudflareSimulatorLoginLinkTests {
    private let publicURL = URL(string: "https://verification.example/cdn-cgi/access/cli?token=synthetic-public-key&aud=synthetic-audience")!

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("The link is atomically published with private permissions and removed on completion")
    func privatePermissionsAndCleanup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("handoff", isDirectory: true)
        let attempt = UUID()
        let link = try CloudflareSimulatorLoginLink.publish(browserURL: publicURL, directoryPath: directory.path, attempt: attempt)
        defer { link.remove() }
        let file = directory.appendingPathComponent("login-\(attempt.uuidString).html")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [file.lastPathComponent])
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("synthetic-public-key&amp;aud=synthetic-audience"))
        link.remove()
        link.remove()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Unsafe directories fail without publishing or changing their permissions")
    func rejectSharedAndSymlinkDirectories() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: CloudflareSimulatorLoginLink.Failure.self) {
            try CloudflareSimulatorLoginLink.publish(browserURL: publicURL, directoryPath: shared.path, attempt: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
        let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: privateDirectory)
        #expect(throws: CloudflareSimulatorLoginLink.Failure.self) {
            try CloudflareSimulatorLoginLink.publish(browserURL: publicURL, directoryPath: alias.path + "/", attempt: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: privateDirectory.path).isEmpty)
    }

    @Test("Releasing the attempt also removes its temporary public-key link")
    func releaseRemovesFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var link: CloudflareSimulatorLoginLink? = try CloudflareSimulatorLoginLink.publish(
            browserURL: publicURL, directoryPath: root.path, attempt: UUID())
        #expect(link != nil)
        link = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
#endif
