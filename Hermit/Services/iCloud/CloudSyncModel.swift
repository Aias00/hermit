import Foundation
import CryptoKit

enum CloudSyncError: LocalizedError, Equatable {
    case unavailable, signedOut, locked, invalidData, accountChanged, localChanged, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "This build is not signed for iCloud. Install a build with an authorized CloudKit container.")
        case .signedOut: return String(localized: "Sign in to iCloud in system Settings, then try again.")
        case .locked: return String(localized: "Unlock this device and use Sync Now to authorize access to SSH credentials.")
        case .invalidData: return String(localized: "Some saved sync data could not be read. Nothing was replaced; restore the data before syncing.")
        case .accountChanged: return String(localized: "The iCloud account changed. Sync has been turned off. Enable it again only if you want to copy this device’s settings to the current account.")
        case .localChanged: return String(localized: "Settings changed during sync. Use Sync Now to merge the latest changes.")
        case .conflict: return String(localized: "Another device changed iCloud data during sync. Use Sync Now to merge again.")
        }
    }
}

enum CloudSyncDomain: String, Codable, CaseIterable, Sendable {
    case host, key, theme, appTheme, shortcuts, preferences, credential
}

/// One independently versioned object. Payload is only kept in memory and in
/// CloudKit's encrypted field, never in the local reconciliation journal.
struct CloudSyncObject: Codable, Equatable, Sendable {
    var schema = 1
    var id: String
    var domain: CloudSyncDomain
    var revision: Int64
    var writer: String
    var payload: Data?
    var deleted: Bool { payload == nil }

    func validated() throws -> Self {
        guard schema == 1, id.hasPrefix(domain.rawValue + "/"), id.utf8.count <= 256,
              revision >= 0, UUID(uuidString: writer) != nil,
              payload.map({ $0.count <= 750_000 }) ?? true else { throw CloudSyncError.invalidData }
        return self
    }

    func succeeds(_ other: Self) -> Bool {
        revision != other.revision ? revision > other.revision : writer > other.writer
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudSyncEntry: Codable, Equatable, Sendable {
    var domain: CloudSyncDomain
    var revision: Int64
    var writer: String
    var deleted: Bool
    /// The actual local value after applying a remote change. It may still
    /// exist after a credential tombstone: sync never destroys local secrets.
    var localHash: String?
}

struct CloudSyncJournal: Codable, Equatable {
    var schema = 1
    var account: String
    var entries: [String: CloudSyncEntry] = [:]
}

struct CloudSyncCapture: Equatable {
    var values: [String: CloudSyncObject] = [:]
    /// Credentials use a device-keyed HMAC: a public password hash in defaults
    /// would permit offline guessing even though it isn't plaintext.
    var hashes: [String: String] = [:]
    /// Referenced credentials that have not arrived on this device yet are
    /// unknown, not deleted. Disabling credentials excludes the whole domain.
    var unknownIDs: Set<String> = []
    var includesCredentials: Bool
}

enum CloudSyncMerge {
    static func prepare(_ capture: CloudSyncCapture, journal: CloudSyncJournal,
                        writer: String) throws -> [String: CloudSyncObject] {
        var result: [String: CloudSyncObject] = [:]
        for (id, var value) in capture.values {
            let hash = capture.hashes[id] ?? (value.domain == .credential ? nil : value.payload.map(CloudSyncObject.digest))
            guard value.domain != .credential || hash != nil else { throw CloudSyncError.invalidData }
            if let previous = journal.entries[id] {
                let changed = hash != previous.localHash
                guard !changed || previous.revision < Int64.max else { throw CloudSyncError.invalidData }
                value.revision = previous.revision + (changed ? 1 : 0)
                value.writer = changed ? writer : previous.writer
                if !changed && previous.deleted { value.payload = nil }
            } else {
                value.revision = 1
                value.writer = writer
            }
            result[id] = value
        }
        for (id, previous) in journal.entries where result[id] == nil {
            guard previous.domain != .credential || capture.includesCredentials,
                  !capture.unknownIDs.contains(id) else { continue }
            let changed = previous.localHash != nil
            guard !changed || previous.revision < Int64.max else { throw CloudSyncError.invalidData }
            result[id] = CloudSyncObject(id: id, domain: previous.domain,
                revision: previous.revision + (changed ? 1 : 0),
                writer: changed ? writer : previous.writer, payload: nil)
        }
        return result
    }

    static func merge(local: [String: CloudSyncObject], remote: [String: CloudSyncObject],
                      journal: CloudSyncJournal, includeCredentials: Bool) -> [String: CloudSyncObject] {
        var result = local
        for (id, cloud) in remote {
            guard cloud.domain != .credential || includeCredentials else { continue }
            // A fresh install has no history for fixed IDs (appearance and
            // toolbar). Its shipped defaults must not overwrite iCloud.
            if journal.entries[id] == nil || result[id] == nil || cloud.succeeds(result[id]!)
                || (cloud.revision == result[id]!.revision && cloud.writer == result[id]!.writer) {
                result[id] = cloud
            }
        }
        return result
    }
}

@MainActor
protocol CloudSyncBackend {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> [String: CloudSyncObject]
    /// Must reject a changed server version rather than overwrite it.
    func save(_ objects: [CloudSyncObject]) async throws
}

extension JSONEncoder {
    static var cloudSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
