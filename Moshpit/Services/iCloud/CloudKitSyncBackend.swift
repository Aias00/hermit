import Foundation
import CloudKit

/// Read our executable's signed entitlement blob. SecTask is not public iOS
/// API; an Info.plist flag alone does not establish that CloudKit is signed in.
/// Fail closed for unsigned simulators and Personal Team installations, before
/// creating CKContainer (which can raise an exception without entitlements).
enum CloudSyncEntitlements {
    static func container(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let entitlements = signedEntitlements(in: data),
              let services = entitlements["com.apple.developer.icloud-services"] as? [String],
              services.contains("CloudKit"),
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return nil }
        let configured = bundle.object(forInfoDictionaryKey: "MoshpitCloudKitContainerIdentifier") as? String
        if let configured, containers.contains(configured) { return configured }
        return containers.count == 1 ? containers.first : nil
    }

    static func signedEntitlements(in data: Data) -> [String: Any]? {
        func word(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = Array(data[offset..<(offset + 4)])
            return big ? bytes.reduce(0) { ($0 << 8) | UInt32($1) }
                : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0), magic == 0xfeedfacf || magic == 0xfeedface,
              let count = word(16), count < 4096 else { return nil }
        var command = magic == 0xfeedfacf ? 32 : 28
        for _ in 0..<count {
            guard let kind = word(command), let size = word(command + 4), size >= 8,
                  Int(size) <= data.count - command else { return nil }
            defer { command += Int(size) }
            guard kind == 0x1d else { continue } // LC_CODE_SIGNATURE
            guard size >= 16, let startWord = word(command + 8), let lengthWord = word(command + 12) else { return nil }
            let start = Int(startWord), length = Int(lengthWord)
            guard start <= data.count, length <= data.count - start, length >= 12,
                  word(start, big: true) == 0xfade0cc0,
                  let blobs = word(start + 8, big: true), blobs <= 4096,
                  12 + Int(blobs) * 8 <= length else { return nil }
            for index in 0..<Int(blobs) {
                let entry = start + 12 + index * 8
                guard word(entry, big: true) == 5,
                      let offset = word(entry + 4, big: true), Int(offset) <= length - 8 else { continue }
                let blob = start + Int(offset)
                guard word(blob, big: true) == 0xfade7171,
                      let blobLength = word(blob + 4, big: true), blobLength >= 8,
                      Int(blobLength) <= length - Int(offset) else { return nil }
                let xml = Data(data[(blob + 8)..<(blob + Int(blobLength))].prefix { $0 != 0 })
                return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
            }
        }
        return nil
    }
}

@MainActor
final class CloudKitSyncBackend: CloudSyncBackend {
    private let container: CKContainer
    private let zone = CKRecordZone.ID(zoneName: "MoshpitSyncV1", ownerName: CKCurrentUserDefaultName)
    private var fetched: [String: CKRecord] = [:]
    private var database: CKDatabase { container.privateCloudDatabase }

    init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }

    func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncError.signedOut }
        return try await container.userRecordID().recordName
    }

    func fetch() async throws -> [String: CloudSyncObject] {
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
        var result: [String: CloudSyncObject] = [:]
        var records: [String: CKRecord] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            for (_, change) in page.modificationResultsByID {
                let record = try change.get().record
                guard record.recordType == "MoshpitSyncV1",
                      let data = record.encryptedValues["payload"] as? Data else { throw CloudSyncError.invalidData }
                let value = try JSONDecoder().decode(CloudSyncObject.self, from: data).validated()
                guard record.recordID.recordName == recordName(value.id), result[value.id] == nil else {
                    throw CloudSyncError.invalidData
                }
                result[value.id] = value
                records[value.id] = record
            }
            // App deletions are retained as encrypted tombstone records.
            // A console-side physical deletion must not resurrect an item
            // encountered earlier in a paginated full-zone read.
            for deletion in page.deletions {
                if let id = records.first(where: { $0.value.recordID == deletion.recordID })?.key {
                    records[id] = nil; result[id] = nil
                }
            }
            token = page.changeToken
            more = page.moreComing
        }
        fetched = records
        return result
    }

    func save(_ objects: [CloudSyncObject]) async throws {
        for offset in stride(from: 0, to: objects.count, by: 100) {
            let records = try objects[offset..<min(offset + 100, objects.count)].map { object in
                let object = try object.validated()
                let record = fetched[object.id] ?? CKRecord(recordType: "MoshpitSyncV1",
                    recordID: CKRecord.ID(recordName: recordName(object.id), zoneID: zone))
                record.encryptedValues["payload"] = try JSONEncoder.cloudSync.encode(object) as NSData
                return record
            }
            do {
                let result = try await database.modifyRecords(saving: records, deleting: [],
                                                              savePolicy: .ifServerRecordUnchanged, atomically: true)
                for (_, saved) in result.saveResults { _ = try saved.get() }
            } catch let error as CKError where error.code == .serverRecordChanged || error.code == .batchRequestFailed {
                throw CloudSyncError.conflict
            }
        }
    }

    private func recordName(_ id: String) -> String { CloudSyncObject.digest(Data(id.utf8)) }
}
