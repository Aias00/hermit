import Foundation
import Testing
@testable import Moshpit

@Suite("iCloud sync", .serialized) @MainActor
struct CloudSyncTests {
    @MainActor private final class Cloud {
        var objects: [String: CloudSyncObject] = [:]
    }
    @MainActor private final class Backend: CloudSyncBackend {
        let cloud: Cloud
        var account = "test-account-A"
        var fetched: [String: CloudSyncObject] = [:]
        var onFetch: (() -> Void)?
        var onSave: (() -> Void)?
        var saves = 0
        init(_ cloud: Cloud) { self.cloud = cloud }
        func accountIdentifier() async throws -> String { account }
        func fetch() async throws -> [String: CloudSyncObject] {
            fetched = cloud.objects; onFetch?(); return fetched
        }
        func save(_ objects: [CloudSyncObject]) async throws {
            for object in objects where cloud.objects[object.id] != fetched[object.id] { throw CloudSyncError.conflict }
            saves += 1
            for object in objects { cloud.objects[object.id] = object }
            onSave?()
        }
    }
    @MainActor private final class Fixture {
        let name = "test.icloud.\(UUID().uuidString)"
        let defaults: UserDefaults
        let local: CloudSyncLocalStore
        let service: CloudSyncService
        let backend: Backend
        let keychain = KeychainService.inMemory()
        init(_ cloud: Cloud? = nil) {
            defaults = UserDefaults(suiteName: name)!
            backend = Backend(cloud ?? Cloud())
            let settings = AppSettings(defaults: defaults)
            // Capture the lock independently from the fixture during init.
            let gate = LockGate()
            lockGate = gate
            local = CloudSyncLocalStore(connections: ConnectionStore(defaults: defaults),
                keys: SSHKeyStore(defaults: defaults), themes: ThemeStore(defaults: defaults),
                appThemes: AppThemeStore(defaults: defaults), shortcuts: ShortcutStore(defaults: defaults),
                settings: settings, keychain: keychain, protectedDataAvailable: { gate.unlocked })
            service = CloudSyncService(defaults: defaults, backend: backend, discoverEntitlements: false)
            service.configure(local)
        }
        let lockGate: LockGate
        @MainActor final class LockGate { var unlocked = true }
        func close() { defaults.removePersistentDomain(forName: name) }
        func sync() async { service.setEnabled(true); await service.sync(manual: true) }
    }

    @Test("main sync defaults off, credential sync defaults on, unsigned builds unavailable")
    func defaultsAndEntitlements() {
        let fixture = Fixture(); defer { fixture.close() }
        #expect(!fixture.service.enabled)
        #expect(fixture.service.syncCredentials)
        let unavailable = CloudSyncService(defaults: fixture.defaults, discoverEntitlements: false)
        unavailable.setEnabled(true)
        #expect(!unavailable.available && !unavailable.enabled)
        #expect(unavailable.message == CloudSyncError.unavailable.localizedDescription)
        #expect(CloudSyncEntitlements.signedEntitlements(in: Data()) == nil)
        #expect(CloudSyncEntitlements.signedEntitlements(in: Data(repeating: 255, count: 128)) == nil)
    }

    @Test("valid signed Mach-O entitlement blob is read and truncated signatures fail closed")
    func signedEntitlementParser() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.test.moshpit"]
        ], format: .xml, options: 0)
        func word(_ value: UInt32, big: Bool) -> Data {
            var value = big ? value.bigEndian : value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var signature = Data()
        for value in [UInt32(0xfade0cc0), UInt32(28 + xml.count), 1, 5, 20, 0xfade7171, UInt32(8 + xml.count)] {
            signature.append(word(value, big: true))
        }
        signature.append(xml)
        var executable = Data(repeating: 0, count: 32)
        executable.replaceSubrange(0..<4, with: word(0xfeedfacf, big: false))
        executable.replaceSubrange(16..<20, with: word(1, big: false))
        executable.replaceSubrange(20..<24, with: word(16, big: false))
        for value in [UInt32(0x1d), 16, 48, UInt32(signature.count)] { executable.append(word(value, big: false)) }
        executable.append(signature)
        let parsed = try #require(CloudSyncEntitlements.signedEntitlements(in: executable))
        #expect(parsed["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(CloudSyncEntitlements.signedEntitlements(in: Data(executable.dropLast())) == nil)
    }

    @Test("fresh device merges saved hosts and restores portable credentials; journal contains no secret")
    func coldRestore() async throws {
        let cloud = Cloud(), a = Fixture(cloud), b = Fixture(cloud)
        defer { a.close(); b.close() }
        let ref = a.keychain.generateRef()
        try await a.keychain.savePassword("fixture-password-only", forRef: ref, requireBiometry: false)
        let host = ServerConnection(name: "Mini", host: "mini.example", username: "test", keychainRef: ref)
        a.local.connections.add(host)
        a.local.settings.fontSize = 19
        await a.sync()
        #expect(a.service.message == nil)
        await b.sync()
        #expect(b.service.message == nil)
        #expect(b.local.connections.connections.first?.id == host.id)
        #expect(b.local.settings.fontSize == 19)
        #expect(try await b.keychain.loadPassword(forRef: ref) == "fixture-password-only")
        let journal = try #require(a.defaults.data(forKey: CloudSyncService.journalKey))
        #expect(!String(decoding: journal, as: UTF8.self).contains("fixture-password-only"))
        #expect(!String(decoding: journal, as: UTF8.self).contains(Data("fixture-password-only".utf8).base64EncodedString()))
    }

    @Test("rename keeps identity, deletion tombstone survives offline device and does not resurrect")
    func renameAndDelete() async throws {
        let cloud = Cloud(), a = Fixture(cloud), b = Fixture(cloud)
        defer { a.close(); b.close() }
        var host = ServerConnection(name: "Old", host: "host.example", username: "test")
        a.local.connections.add(host); await a.sync(); await b.sync()
        host.name = "New"; a.local.connections.update(host); await a.service.sync(manual: true)
        await b.service.sync(manual: true)
        #expect(b.local.connections.connections.map(\.name) == ["New"])
        a.local.connections.delete(id: host.id); await a.service.sync(manual: true)
        await b.service.sync(manual: true)
        #expect(b.local.connections.connections.isEmpty)
        #expect(cloud.objects["host/" + host.id.uuidString]?.deleted == true)
        await b.service.sync(manual: true)
        #expect(cloud.objects["host/" + host.id.uuidString]?.deleted == true)
    }

    @Test("concurrent offline object edits merge deterministically without losing unrelated objects")
    func offlineMerge() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        let low = min(first, second), high = max(first, second)
        let local = CloudSyncObject(id: "host/shared", domain: .host, revision: 4, writer: low, payload: Data("local".utf8))
        let remote = CloudSyncObject(id: local.id, domain: .host, revision: 4, writer: high, payload: nil)
        let separate = CloudSyncObject(id: "host/separate", domain: .host, revision: 1, writer: low, payload: Data("keep".utf8))
        let journal = CloudSyncJournal(account: "a", entries: [local.id: CloudSyncEntry(domain: .host,
            revision: 3, writer: low, deleted: false, localHash: "old")])
        let merged = CloudSyncMerge.merge(local: [local.id: local, separate.id: separate],
            remote: [remote.id: remote], journal: journal, includeCredentials: true)
        #expect(merged[local.id] == remote)
        #expect(merged[separate.id] == separate)
    }

    @Test("locked or corrupt reads cannot upload empty collections or set last sync")
    func lockedAndCorrupt() async {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.lockGate.unlocked = false
        await fixture.sync()
        #expect(fixture.backend.saves == 0)
        #expect(fixture.service.lastSync == nil)
        fixture.lockGate.unlocked = true
        fixture.defaults.set(Data("broken".utf8), forKey: "moshpit.connections")
        await fixture.service.sync(manual: true)
        #expect(fixture.backend.saves == 0)
        #expect(fixture.service.message == CloudSyncError.invalidData.localizedDescription)
        #expect(fixture.defaults.data(forKey: "moshpit.connections") == Data("broken".utf8))
    }

    @Test("credential switch preserves local and already-uploaded secrets and allows later restore")
    func credentialsSwitch() async throws {
        let cloud = Cloud(), a = Fixture(cloud), b = Fixture(cloud)
        defer { a.close(); b.close() }
        let ref = a.keychain.generateRef()
        try await a.keychain.savePassword("before", forRef: ref, requireBiometry: false)
        a.local.connections.add(ServerConnection(name: "Host", host: "host.example", username: "test", keychainRef: ref))
        await a.sync()
        let uploaded = cloud.objects["credential/" + ref]
        a.service.setSyncCredentials(false)
        try await a.keychain.savePassword("after", forRef: ref, requireBiometry: false)
        await a.service.sync(manual: true)
        #expect(cloud.objects["credential/" + ref] == uploaded)
        #expect(try await a.keychain.loadPassword(forRef: ref) == "after")
        b.service.setSyncCredentials(false); await b.sync()
        #expect(!(await b.keychain.contains(ref: ref)))
        b.service.setSyncCredentials(true); await b.service.sync(manual: true)
        #expect(try await b.keychain.loadPassword(forRef: ref) == "before")
        a.service.setSyncCredentials(true); await a.service.sync(manual: true)
        await b.service.sync(manual: true)
        #expect(try await b.keychain.loadPassword(forRef: ref) == "after")
    }

    @Test("remote credential tombstone never erases a local key and is not silently resurrected")
    func secretTombstone() async throws {
        let cloud = Cloud(), fixture = Fixture(cloud)
        defer { fixture.close() }
        let ref = fixture.keychain.generateRef()
        try await fixture.keychain.savePassword("local-only", forRef: ref, requireBiometry: false)
        fixture.local.connections.add(ServerConnection(name: "Host", host: "host.example", username: "test", keychainRef: ref))
        await fixture.sync()
        let id = "credential/" + ref
        var deleted = try #require(cloud.objects[id]); deleted.revision += 1; deleted.payload = nil
        cloud.objects[id] = deleted
        await fixture.service.sync(manual: true)
        #expect(try await fixture.keychain.loadPassword(forRef: ref) == "local-only")
        await fixture.service.sync(manual: true)
        #expect(cloud.objects[id]?.deleted == true)
    }

    @Test("account changes disable sync before any upload to the other account")
    func accountIsolation() async {
        let fixture = Fixture(); defer { fixture.close() }
        await fixture.sync()
        let saves = fixture.backend.saves
        fixture.backend.account = "account-B"
        await fixture.service.sync(manual: true)
        #expect(!fixture.service.enabled)
        #expect(fixture.service.message == CloudSyncError.accountChanged.localizedDescription)
        #expect(fixture.backend.saves == saves)
        #expect(fixture.service.lastSync == nil)
    }

    @Test("same account reauthentication preserves unsynced edits")
    func sameAccountKeepsJournal() async {
        let fixture = Fixture(); defer { fixture.close() }
        await fixture.sync()
        fixture.local.settings.fontSize = 23
        fixture.service.accountChanged()
        await fixture.sync()
        #expect(fixture.service.message == nil)
        #expect(fixture.local.settings.fontSize == 23)
    }

    @Test("first upload interrupted before apply keeps later local edits")
    func firstUploadInterrupted() async {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.local.settings.fontSize = 18
        fixture.backend.onSave = { fixture.local.settings.fontSize = 25 }
        await fixture.sync()
        #expect(fixture.service.message == CloudSyncError.localChanged.localizedDescription)
        #expect(fixture.service.lastSync == nil)
        fixture.backend.onSave = nil
        await fixture.service.sync(manual: true)
        #expect(fixture.service.message == nil)
        #expect(fixture.local.settings.fontSize == 25)
        #expect(fixture.backend.cloud.objects["preferences/appearance"]?.revision == 2)
    }

    @Test("turning sync off during fetch prevents upload")
    func disabledDuringFetch() async {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.backend.onFetch = { fixture.service.setEnabled(false) }
        await fixture.sync()
        #expect(fixture.backend.saves == 0)
        #expect(fixture.service.lastSync == nil)
    }

    @Test("credential journal uses a device-keyed digest, not a public password verifier")
    func keyedCredentialDigest() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        let ref = fixture.keychain.generateRef()
        try await fixture.keychain.savePassword("guessable-fixture", forRef: ref, requireBiometry: false)
        fixture.local.connections.add(ServerConnection(name: "Host", host: "host.example", keychainRef: ref))
        let capture = try await fixture.local.capture(includeCredentials: true, allowAuthentication: true)
        let id = "credential/" + ref
        let payload = try #require(capture.values[id]?.payload)
        #expect(capture.hashes[id] != CloudSyncObject.digest(payload))
        await fixture.sync()
        let data = try #require(fixture.defaults.data(forKey: CloudSyncService.journalKey))
        let journal = try JSONDecoder().decode(CloudSyncJournal.self, from: data)
        #expect(journal.entries[id]?.localHash == capture.hashes[id])
    }

    @Test("restored defaults with an empty device Keychain can recover cloud credentials")
    func deviceBackupRestore() async throws {
        let cloud = Cloud(), source = Fixture(cloud), restored = Fixture(cloud)
        defer { source.close(); restored.close() }
        let ref = source.keychain.generateRef()
        try await source.keychain.savePassword("restore-fixture", forRef: ref, requireBiometry: false)
        source.local.connections.add(ServerConnection(name: "Host", host: "host.example", keychainRef: ref))
        await source.sync()
        restored.defaults.setPersistentDomain(try #require(source.defaults.persistentDomain(forName: source.name)),
                                              forName: restored.name)
        restored.local.connections.load()
        restored.local.keys.reloadAfterCloudSync()
        restored.local.themes.reloadAfterCloudSync()
        restored.local.appThemes.reloadAfterCloudSync()
        restored.local.shortcuts.reloadAfterCloudSync()
        await restored.sync()
        #expect(restored.service.message == nil)
        #expect(try await restored.keychain.loadPassword(forRef: ref) == "restore-fixture")
        let sourceWriter = try await source.keychain.loadSecret(forRef: "moshpit.icloud.writer.v1")
        let restoredWriter = try await restored.keychain.loadSecret(forRef: "moshpit.icloud.writer.v1")
        #expect(sourceWriter != restoredWriter)
    }

    @Test("deleted key-library metadata does not downgrade private-key restore protection")
    func missingKeyMetadataProtection() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        let ref = fixture.keychain.generateRef()
        try await fixture.keychain.savePrivateKey("fixture-key", forRef: ref)
        fixture.local.connections.add(ServerConnection(name: "Host", host: "host.example", authMethod: .key, keychainRef: ref))
        let capture = try await fixture.local.capture(includeCredentials: true, allowAuthentication: true)
        let payload = try #require(capture.values["credential/" + ref]?.payload)
        #expect(try JSONDecoder().decode(CloudSyncCredential.self, from: payload).requireBiometry)
    }

    @Test("local edits and account changes during fetch abort the pending write")
    func changesDuringFetch() async {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.backend.onFetch = { fixture.local.settings.fontSize = 24 }
        await fixture.sync()
        #expect(fixture.backend.saves == 0)
        #expect(fixture.local.settings.fontSize == 24)
        #expect(fixture.service.message == CloudSyncError.localChanged.localizedDescription)
        fixture.backend.onFetch = { fixture.backend.account = "account-B" }
        await fixture.service.sync(manual: true)
        #expect(fixture.backend.saves == 0)
        #expect(!fixture.service.enabled)
    }

    @Test("provider credentials, bindings, trust, and Secure Enclave material never enter capture")
    func deviceSecretsStayLocal() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        var host = ServerConnection(name: "Private transport", host: "host.example", username: "test")
        host.tailcatCredentialRef = "moshpit.tailcat." + UUID().uuidString
        host.tailscaleAccountID = UUID().uuidString
        fixture.local.connections.add(host)
        let ref = fixture.keychain.generateRef()
        try await fixture.keychain.saveSecret(Data("nonexportable-fixture".utf8), forRef: ref, requireBiometry: false)
        fixture.local.keys.add(SSHKeyRecord(name: "Device key", algorithm: .seP256, source: .secureEnclave, keychainRef: ref))
        let capture = try await fixture.local.capture(includeCredentials: true, allowAuthentication: true)
        let serialized = try JSONEncoder().encode(Array(capture.values.values))
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(!text.contains(host.tailcatCredentialRef!))
        #expect(!text.contains(host.tailscaleAccountID!))
        #expect(!capture.values.keys.contains("credential/" + ref))
        let object = try #require(capture.values["host/" + host.id.uuidString])
        let restored = try JSONDecoder().decode(ServerConnection.self, from: #require(object.payload))
        #expect(restored.tailcatCredentialRef == nil && restored.tailscaleAccountID == nil)
        await #expect(throws: KeychainError.invalidData) {
            try await fixture.keychain.exportSSHSecret(ref: "moshpit.knownHosts", allowAuthentication: true)
        }
    }
}
