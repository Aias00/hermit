import Darwin
import Foundation

/// A transfer publishes its local file only after the last write succeeds.
/// Each attempt owns a different sibling so simultaneous previews and a
/// cancelled retry cannot truncate or remove one another's bytes.
enum LocalTransferFile {
    static func write(
        to destination: URL,
        operation: (URL) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".hermit-transfer-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await operation(staging)
        try Task.checkCancellation()
        // Same-directory rename is atomic and preserves an existing copy if
        // any network, write or cancellation error occurs before this point.
        guard rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
