import Foundation
import Observation
import CloudKit

@MainActor @Observable
final class CloudSyncService {
    static let shared = CloudSyncService()
    private(set) var enabled: Bool
    private(set) var syncCredentials: Bool
    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var message: String?
    let available: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: (any CloudSyncBackend)?
    @ObservationIgnored private var local: CloudSyncLocalStore?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    private static let enabledKey = "moshpit.icloud.enabled.v1"
    private static let credentialsKey = "moshpit.icloud.credentials.v1"
    static let journalKey = "moshpit.icloud.journal.v1"

    init(defaults: UserDefaults = .standard, backend: (any CloudSyncBackend)? = nil,
         discoverEntitlements: Bool = true) {
        self.defaults = defaults
        if let backend { self.backend = backend; available = true }
        else if discoverEntitlements, let container = CloudSyncEntitlements.container() {
            self.backend = CloudKitSyncBackend(containerIdentifier: container); available = true
        } else { self.backend = nil; available = false }
        enabled = defaults.bool(forKey: Self.enabledKey) && available
        syncCredentials = defaults.object(forKey: Self.credentialsKey) as? Bool ?? true
        lastSync = defaults.object(forKey: "moshpit.icloud.lastSync.v1") as? Date
        if !available { message = CloudSyncError.unavailable.localizedDescription }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.accountChanged() }
            }
    }

    func configure(_ local: CloudSyncLocalStore) { self.local = local }

    func setEnabled(_ value: Bool) {
        guard available else { message = CloudSyncError.unavailable.localizedDescription; return }
        generation += 1
        preferencesLoaded = true
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value {
            // Account changes are never an implicit migration. This explicit
            // re-enable is the user's choice to copy local data to that account.
            if defaults.bool(forKey: "moshpit.icloud.accountChanged.v1") {
                defaults.removeObject(forKey: "moshpit.icloud.lastSync.v1")
                lastSync = nil
            }
            message = nil
        }
    }

    func setSyncCredentials(_ value: Bool) {
        generation += 1
        preferencesLoaded = true
        syncCredentials = value
        defaults.set(value, forKey: Self.credentialsKey)
    }

    func accountChanged() {
        generation += 1
        preferencesLoaded = true
        enabled = false; lastSync = nil
        defaults.set(false, forKey: Self.enabledKey)
        defaults.set(true, forKey: "moshpit.icloud.accountChanged.v1")
        defaults.removeObject(forKey: "moshpit.icloud.lastSync.v1")
        message = CloudSyncError.accountChanged.localizedDescription
    }

    /// Foreground/manual only. No background task or CK subscription is
    /// claimed, and automatic foreground passes never open biometric prompts.
    func sync(manual: Bool = false) async {
        guard available, !syncing, let backend, let local else { return }
        if !preferencesLoaded {
            // A prewarm before first unlock can return empty UserDefaults.
            // Re-read the opt-in only once trusted storage becomes available.
            do { try local.requireReadable() }
            catch { message = error.localizedDescription; return }
            enabled = defaults.bool(forKey: Self.enabledKey)
            syncCredentials = defaults.object(forKey: Self.credentialsKey) as? Bool ?? true
            lastSync = defaults.object(forKey: "moshpit.icloud.lastSync.v1") as? Date
            preferencesLoaded = true
        }
        guard enabled else { return }
        syncing = true; message = nil
        defer { syncing = false }
        let operation = generation
        let credentials = syncCredentials
        do {
            try local.requireReadable()
            await local.keychain.beginSSHSyncExport(allowAuthentication: manual)
            try ensureCurrent(operation)
            let account = CloudSyncObject.digest(Data(try await backend.accountIdentifier().utf8))
            try ensureCurrent(operation)
            var journal = try readJournal(account: account)
            if journal.account != account {
                guard defaults.bool(forKey: "moshpit.icloud.accountChanged.v1") else {
                    accountChanged(); throw CloudSyncError.accountChanged
                }
                // Re-enable after the account-change message authorizes a new
                // account. Re-authenticating the SAME account keeps revisions.
                journal = CloudSyncJournal(account: account)
                try local.requireReadable()
                defaults.set(try JSONEncoder.cloudSync.encode(journal), forKey: Self.journalKey)
            }
            defaults.set(false, forKey: "moshpit.icloud.accountChanged.v1")
            let writer = try await deviceIdentifier(keychain: local.keychain)
            try ensureCurrent(operation)
            let captured = try await local.capture(includeCredentials: credentials, allowAuthentication: manual)
            try ensureCurrent(operation)
            var pending = try CloudSyncMerge.prepare(captured, journal: journal, writer: writer)
            let remote = try await backend.fetch()
            try ensureCurrent(operation)
            // Validate injected backends too, before any mutation.
            for (id, object) in remote { guard id == object.id else { throw CloudSyncError.invalidData }; _ = try object.validated() }
            // A previous upload may have committed before the process died
            // or local apply failed. Further local edits need a NEW revision,
            // not a different payload carrying that already-uploaded version.
            for (id, value) in pending {
                if let cloud = remote[id], let previous = journal.entries[id],
                   value.writer == writer, value.writer == cloud.writer,
                   value.revision == cloud.revision, value.payload != cloud.payload,
                   captured.hashes[id] != previous.localHash {
                    guard value.revision < Int64.max else { throw CloudSyncError.invalidData }
                    pending[id]?.revision += 1
                }
            }
            let merged = CloudSyncMerge.merge(local: pending, remote: remote, journal: journal, includeCredentials: credentials)
            try ensureCurrent(operation)
            try await ensureAccount(account, backend: backend)
            try ensureCurrent(operation)
            let beforeApply = try await local.capture(includeCredentials: credentials, allowAuthentication: manual)
            try ensureCurrent(operation)
            guard captured == beforeApply else { throw CloudSyncError.localChanged }
            let uploads = merged.values.filter { remote[$0.id] != $0 }
            // Record intent BEFORE upload, without payloads. If CloudKit
            // commits but the app dies before apply, further local edits must
            // advance that uploaded version, including on the very first sync.
            for object in uploads {
                journal.entries[object.id] = CloudSyncEntry(domain: object.domain,
                    revision: object.revision, writer: object.writer, deleted: object.deleted,
                    localHash: captured.hashes[object.id])
            }
            defaults.set(try JSONEncoder.cloudSync.encode(journal), forKey: Self.journalKey)
            try await backend.save(uploads)
            try ensureCurrent(operation)
            try await ensureAccount(account, backend: backend)
            try ensureCurrent(operation)
            let beforeCommit = try await local.capture(includeCredentials: credentials, allowAuthentication: manual)
            try ensureCurrent(operation)
            guard captured == beforeCommit else { throw CloudSyncError.localChanged }
            // Applying only changed values also avoids rewriting unchanged
            // biometric Keychain items and unnecessary view reconstruction.
            let changed = merged.filter { captured.values[$0.key]?.payload != $0.value.payload }
            try await local.apply(changed, includeCredentials: credentials,
                                  checkCurrent: { try self.ensureCurrent(operation) })
            try ensureCurrent(operation)
            let committed = try await local.capture(includeCredentials: credentials, allowAuthentication: manual)
            try ensureCurrent(operation)
            for (id, object) in merged {
                journal.entries[id] = CloudSyncEntry(domain: object.domain, revision: object.revision,
                    writer: object.writer, deleted: object.deleted,
                    localHash: committed.hashes[id])
            }
            defaults.set(try JSONEncoder.cloudSync.encode(journal), forKey: Self.journalKey)
            let now = Date(); lastSync = now
            defaults.set(now, forKey: "moshpit.icloud.lastSync.v1")
        } catch {
            // Errors contain no payloads, credential references, or server
            // record descriptions. CloudKit's localized description is safe
            // for account/network/service errors and useful to the user.
            if error is CancellationError {
                message = defaults.bool(forKey: "moshpit.icloud.accountChanged.v1")
                    ? CloudSyncError.accountChanged.localizedDescription
                    : (enabled ? CloudSyncError.localChanged.localizedDescription : nil)
            } else { message = error.localizedDescription }
        }
        await local.keychain.endSSHSyncExport()
    }

    private func ensureCurrent(_ operation: Int) throws {
        guard enabled, operation == generation else { throw CancellationError() }
    }

    private func ensureAccount(_ expected: String, backend: any CloudSyncBackend) async throws {
        let current = CloudSyncObject.digest(Data(try await backend.accountIdentifier().utf8))
        guard current == expected else { accountChanged(); throw CloudSyncError.accountChanged }
    }

    private func deviceIdentifier(keychain: KeychainService) async throws -> String {
        // A backup restored onto another device must not clone a writer ID.
        let reference = "moshpit.icloud.writer.v1"
        do {
            let data = try await keychain.loadSecret(forRef: reference, reason: "Read iCloud sync device identity")
            guard let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil else {
                throw CloudSyncError.invalidData
            }
            return value
        } catch KeychainError.notFound {
            let value = UUID().uuidString
            try await keychain.saveSecret(Data(value.utf8), forRef: reference, requireBiometry: false)
            return value
        }
    }

    private func readJournal(account: String) throws -> CloudSyncJournal {
        guard let object = defaults.object(forKey: Self.journalKey) else { return CloudSyncJournal(account: account) }
        guard let data = object as? Data, let journal = try? JSONDecoder().decode(CloudSyncJournal.self, from: data),
              journal.schema == 1,
              journal.entries.allSatisfy({ id, entry in
                  id.hasPrefix(entry.domain.rawValue + "/") && entry.revision >= 0 && UUID(uuidString: entry.writer) != nil
              }) else { throw CloudSyncError.invalidData }
        return journal
    }
}
