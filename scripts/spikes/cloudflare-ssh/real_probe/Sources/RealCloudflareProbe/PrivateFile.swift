import Darwin
import Foundation

enum PrivateFile {
    static func writeNew(_ data: Data, to path: String) throws {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProbeError.privateFile }
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed { Darwin.unlink(path) }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw ProbeError.privateFile }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProbeError.privateFile }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ProbeError.privateFile }
        completed = true
    }

    static func read(_ path: String, maximumBytes: Int = 256 * 1024) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProbeError.privateFile }
        defer { Darwin.close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_mode & (S_IRWXG | S_IRWXO) == 0,
              attributes.st_size >= 0, attributes.st_size <= maximumBytes else { throw ProbeError.privateFile }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ProbeError.privateFile }
            if count == 0 { return result }
            guard result.count + count <= maximumBytes else { throw ProbeError.privateFile }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshpit-real-access-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ProbeError.privateFile }
        return path
    }

    static func loginPage(for capabilityURL: URL) -> Data {
        let escaped = capabilityURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // No scripts, remote resources, auto-navigation, or automatic opening.
        // This page is removed as soon as the owning login attempt completes.
        return Data("""
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <title>Moshpit Cloudflare compatibility probe</title>
        <h1>Cloudflare Access login</h1>
        <p>Keep the terminal probe running. This link belongs to this one login attempt.</p>
        <p><a rel="noreferrer" href="\(escaped)">Continue to your configured Cloudflare Access application</a></p>
        <p>No browser credentials are copied. The probe receives an encrypted, signed application token.</p>
        </html>
        """.utf8)
    }
}
