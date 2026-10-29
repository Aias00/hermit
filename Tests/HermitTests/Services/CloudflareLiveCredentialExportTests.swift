import CloudflareAccess
import Darwin
import Foundation
import Testing
@testable import Moshpit

/// One-off official-client comparison only. xcodebuild forwards these as
/// TEST_RUNNER_MOSHPIT_CF_LIVE_EXPORT_CREDENTIALS and
/// TEST_RUNNER_MOSHPIT_CF_LIVE_FIXTURE. The caller removes the export as soon as
/// the comparison finishes; ordinary test runs never read or export credentials.
@Suite("Cloudflare explicit live credential export", .tags(.integration), .serialized)
struct CloudflareLiveCredentialExportTests {
    private static let outputPath = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_EXPORT_CREDENTIALS"]
    private static let fixturePath = ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_FIXTURE"]
    private static let isConfigured = outputPath?.isEmpty == false && fixturePath?.isEmpty == false

    // Never propagate framework errors or assertion values from secret-bearing
    // operations into the test log, even if a decoder includes its input.
    private enum ExportError: Error {
        case invalidConfiguration, credentialValidationFailed, encodingFailed
        case unsafeOutputDirectory, outputCreationFailed, outputWriteFailed
    }

    private struct Fixture: Decodable {
        let kind: String
        let status: String
        let endpoint: URL
        let teamDomain: String
        let audience: String

        enum CodingKeys: String, CodingKey {
            case kind, status, endpoint, audience
            case teamDomain = "team_domain"
        }

        static func settings(at path: String) throws -> CloudflareConnectionSettings {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 256 * 1024 else { throw ExportError.invalidConfiguration }
                let fixture = try JSONDecoder().decode(Self.self, from: data)
                guard fixture.kind == "moshpit-cloudflare-access-live-v1", fixture.status == "ready",
                      let endpoint = URLComponents(url: fixture.endpoint, resolvingAgainstBaseURL: false),
                      endpoint.scheme == "wss", let hostname = endpoint.host,
                      endpoint.path == "/", endpoint.port == nil || endpoint.port == 443,
                      endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil else {
                    throw ExportError.invalidConfiguration
                }
                return try CloudflareConnectionSettings.validated(hostname: hostname,
                    teamDomain: fixture.teamDomain, audience: fixture.audience)
            } catch {
                throw ExportError.invalidConfiguration
            }
        }
    }

    @Test("Explicitly export freshly validated App Keychain credentials to a private new file",
          .enabled(if: isConfigured), .timeLimit(.minutes(1)))
    func exportForOfficialComparison() async throws {
        guard let outputPath = Self.outputPath, let fixturePath = Self.fixturePath,
              outputPath.hasPrefix("/"), !outputPath.hasSuffix("/"), !outputPath.utf8.contains(0) else {
            throw ExportError.invalidConfiguration
        }
        let url = URL(fileURLWithPath: outputPath)
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw ExportError.invalidConfiguration
        }
        // Anchor the write to the checked directory descriptor, so a path
        // replacement cannot redirect the secret after the permission check.
        let directory = Darwin.open(url.deletingLastPathComponent().path,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ExportError.unsafeOutputDirectory }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o7777 == 0o700,
              directoryInfo.st_uid == getuid() else {
            throw ExportError.unsafeOutputDirectory
        }

        let settings = try Fixture.settings(at: fixturePath)
        let credentials: AccessCredentials
        do {
            let stored = try await CloudflareAccessAuth.shared.credentials(settings: settings)
            // Explicitly revalidate even when another test populated the actor's
            // memory cache. This path never starts an interactive login.
            credentials = try await AccessJWTValidator.validateCredentials(stored,
                for: CloudflareAccessAuth.application(settings))
        } catch {
            throw ExportError.credentialValidationFailed
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw ExportError.encodingFailed
        }
        guard !data.isEmpty, data.count <= 256 * 1024 else { throw ExportError.encodingFailed }
        try Task.checkCancellation()
        try writeNewFile(data, filename: filename, directory: directory)
    }

    private func writeNewFile(_ data: Data, filename: String, directory: Int32) throws {
        let descriptor = openat(directory, filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ExportError.outputCreationFailed }
        var isOpen = true
        var succeeded = false
        defer {
            if isOpen { Darwin.close(descriptor) }
            // O_EXCL succeeded, so cleanup can only remove this attempt's new
            // file. Existing files and symlinks are never opened or truncated.
            if !succeeded { unlinkat(directory, filename, 0) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw ExportError.outputWriteFailed }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw ExportError.outputWriteFailed
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ExportError.outputWriteFailed }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ExportError.outputWriteFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ExportError.outputWriteFailed }
        try Task.checkCancellation()
        let closeResult = Darwin.close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw ExportError.outputWriteFailed }
        succeeded = true
    }
}
