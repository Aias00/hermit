import Foundation
import Security
import Testing
@testable import Moshpit

/// Exercise the production backend's decisions with failed Security calls;
/// no operation in these tests reaches the real keychain.
@Suite("Non-destructive keychain updates")
struct SystemKeychainUpdateTests {
    private let old = Data("previous-key".utf8)
    private let new = Data("replacement-key".utf8)
    private let account = "hermit.voice.doubao.api-key"

    @Test("A failed update keeps the existing key and never falls back to delete/add")
    func failedUpdatePreservesExistingKey() throws {
        let security = SecurityProbe(value: old, updateStatuses: [errSecInteractionNotAllowed])
        let backend = backend(security)
        #expect(throws: KeychainError.interactionNotAllowed) {
            try backend.savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        }
        let snapshot = security.snapshot()
        #expect(snapshot.value == old)
        #expect(snapshot.calls == ["update"])
    }

    @Test("A successful update changes only the secret and keeps the existing access policy")
    func updateRetainsAccessControl() throws {
        let security = SecurityProbe(value: old)
        try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        let snapshot = security.snapshot()
        #expect(snapshot.value == new)
        #expect(snapshot.calls == ["update"])
        #expect(Set(snapshot.updateAttributes.keys) == Set([kSecValueData as String]))
        #expect(snapshot.updateQuery[kSecAttrAccount as String] as? String == account)
        #expect(snapshot.updateQuery[kSecAttrService as String] as? String == "test.hermit.atomic-key")
        #expect(snapshot.updateQuery[kSecAttrAccessGroup as String] as? String == "test-only-group")
        #expect(snapshot.updateQuery[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test("Only a missing item is added, using device-bound accessibility")
    func createsMissingItem() throws {
        let security = SecurityProbe()
        try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        let snapshot = security.snapshot()
        #expect(snapshot.value == new)
        #expect(snapshot.calls == ["update", "add"])
        #expect(snapshot.addAttributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(snapshot.addAttributes[kSecAttrAccessControl as String] == nil)
    }

    @Test("Creating a biometric item still applies user-presence access control")
    func missingBiometricItemKeepsRequestedPolicy() throws {
        let security = SecurityProbe()
        try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: true)
        let attributes = security.snapshot().addAttributes
        #expect(attributes[kSecAttrAccessControl as String] != nil)
        #expect(attributes[kSecAttrAccessible as String] == nil)
    }

    @Test("An add failure cannot remove a value inserted by another writer")
    func failedAddPreservesConcurrentInsert() throws {
        let security = SecurityProbe(addStatus: errSecNotAvailable, insertBeforeAdd: old)
        #expect(throws: KeychainError.unhandled(errSecNotAvailable)) {
            try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        }
        let snapshot = security.snapshot()
        #expect(snapshot.value == old)
        #expect(snapshot.calls == ["update", "add"])
    }

    @Test("A concurrent insert is handled by an in-place retry")
    func duplicateInsertRetriesUpdate() throws {
        let security = SecurityProbe(insertBeforeAdd: old)
        try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        let snapshot = security.snapshot()
        #expect(snapshot.value == new)
        #expect(snapshot.calls == ["update", "add", "update"])
        #expect(Set(snapshot.updateAttributes.keys) == Set([kSecValueData as String]))
    }

    @Test("A failed retry after a concurrent insert preserves that writer's key")
    func failedDuplicateRetryPreservesConcurrentInsert() throws {
        let security = SecurityProbe(updateStatuses: [errSecItemNotFound, errSecAuthFailed],
                                     insertBeforeAdd: old)
        #expect(throws: KeychainError.authenticationFailed) {
            try backend(security).savePreservingAccessPolicy(secret: new, account: account, requireBiometry: false)
        }
        let snapshot = security.snapshot()
        #expect(snapshot.value == old)
        #expect(snapshot.calls == ["update", "add", "update"])
    }

    @Test("Sync restore uses the same non-destructive missing-item path")
    func syncRestoreDoesNotDeleteConcurrentInsert() throws {
        let security = SecurityProbe(updateStatuses: [errSecItemNotFound, errSecInteractionNotAllowed],
                                     insertBeforeAdd: old)
        #expect(throws: KeychainError.interactionNotAllowed) {
            try backend(security).saveForSync(secret: new, account: account, requireBiometry: true)
        }
        let snapshot = security.snapshot()
        #expect(snapshot.value == old)
        #expect(snapshot.calls == ["update", "add", "update"])
    }

    @Test("The cloud credential API preserves the old key on a real-backend write failure")
    func credentialWriteFailure() async throws {
        let security = SecurityProbe(value: old, updateStatuses: [errSecNotAvailable])
        let vault = DoubaoVoiceCredentials(keychain: KeychainService(backend: backend(security)))
        await #expect(throws: DoubaoVoiceFailure.credentialsUnavailable) {
            try await vault.save("replacement-key")
        }
        #expect(await vault.hasKey())
        #expect(try await vault.apiKey() == "previous-key")
        #expect(security.snapshot().calls == ["update", "copy", "copy"])
    }

    private func backend(_ security: SecurityProbe) -> SystemKeychainBackend {
        SystemKeychainBackend(service: "test.hermit.atomic-key", accessGroup: "test-only-group",
                              items: security.operations)
    }

    private final class SecurityProbe: @unchecked Sendable {
        struct Snapshot {
            let value: Data?
            let calls: [String]
            let updateQuery: [String: Any]
            let updateAttributes: [String: Any]
            let addAttributes: [String: Any]
        }
        private let lock = NSLock()
        private var value: Data?
        private var updateStatuses: [OSStatus]
        private let addStatus: OSStatus?
        private var insertBeforeAdd: Data?
        private var calls: [String] = []
        private var updateQuery: [String: Any] = [:]
        private var updateAttributes: [String: Any] = [:]
        private var addAttributes: [String: Any] = [:]

        init(value: Data? = nil, updateStatuses: [OSStatus] = [],
             addStatus: OSStatus? = nil, insertBeforeAdd: Data? = nil) {
            self.value = value
            self.updateStatuses = updateStatuses
            self.addStatus = addStatus
            self.insertBeforeAdd = insertBeforeAdd
        }

        var operations: KeychainItemOperations {
            .init(update: { [self] query, attributes in update(query, attributes) },
                  add: { [self] attributes in add(attributes) },
                  delete: { [self] _ in remove() },
                  copyMatching: { [self] _ in copy() })
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(value: value, calls: calls, updateQuery: updateQuery,
                            updateAttributes: updateAttributes, addAttributes: addAttributes)
        }

        private func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            calls.append("update")
            updateQuery = query as! [String: Any]
            updateAttributes = attributes as! [String: Any]
            if !updateStatuses.isEmpty {
                let status = updateStatuses.removeFirst()
                if status != errSecSuccess { return status }
            }
            guard value != nil else { return errSecItemNotFound }
            value = updateAttributes[kSecValueData as String] as? Data
            return errSecSuccess
        }

        private func add(_ attributes: CFDictionary) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            calls.append("add")
            addAttributes = attributes as! [String: Any]
            if let insertBeforeAdd {
                value = insertBeforeAdd
                self.insertBeforeAdd = nil
            }
            if let addStatus { return addStatus }
            guard value == nil else { return errSecDuplicateItem }
            value = addAttributes[kSecValueData as String] as? Data
            return errSecSuccess
        }

        private func remove() -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            calls.append("delete")
            value = nil
            return errSecSuccess
        }

        private func copy() -> (OSStatus, CFTypeRef?) {
            lock.lock(); defer { lock.unlock() }
            calls.append("copy")
            guard let value else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, value as NSData)
        }
    }
}
