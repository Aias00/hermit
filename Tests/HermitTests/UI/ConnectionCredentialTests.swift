import Foundation
import Testing
@testable import Moshpit

/// Saving the connection editor must never write into, or take ownership of,
/// a managed SSH key's keychain item — every connection that picked the key
/// shares it (2026-10-10: switching such a connection to Password overwrote
/// the private key with the password; editing one whose key had been deleted
/// dropped it on the floor).
@Suite("Connection credential")
struct ConnectionCredentialTests {

    private let key = SSHKeyRecord(name: "laptop", algorithm: .ed25519, source: .generated,
                                   keychainRef: "moshpit.secret.key-k")
    private let enclaveKey = SSHKeyRecord(name: "phone", algorithm: .seP256, source: .secureEnclave,
                                          keychainRef: "moshpit.secret.key-se")

    /// A saved connection signing with `record`.
    private func using(_ record: SSHKeyRecord) -> ServerConnection {
        var c = ServerConnection()
        c.authMethod = .key
        c.keychainRef = record.keychainRef
        c.sshKeyId = record.id
        c.sshKeyAlgorithmRaw = record.algorithm.rawValue
        return c
    }

    private func save(
        _ connection: inout ServerConnection, _ method: AuthMethod, selected: UUID? = nil,
        keys: [SSHKeyRecord], password: String = "", pem: String = ""
    ) -> String? {
        ConnectionCredential.apply(
            to: &connection, authMethod: method, selectedKeyId: selected, keys: keys,
            password: password, privateKeyPEM: pem, newRef: { "moshpit.secret.fresh" })
    }

    @Test("Picking a managed key points at its own item and writes nothing")
    func picksManagedKey() {
        var c = ServerConnection()
        let secret = save(&c, .key, selected: key.id, keys: [key])
        #expect(secret == nil)
        #expect(c.keychainRef == key.keychainRef)
        #expect(c.sshKeyId == key.id)
        #expect(c.sshKeyAlgorithmRaw == "ED25519")
    }

    @Test("A deleted key, nothing pasted: the connection keeps signing with it", arguments: [true, false])
    func deletedKeyKept(enclave: Bool) {
        let record = enclave ? enclaveKey : key
        var c = using(record)
        let before = c
        let secret = save(&c, .key, selected: record.id, keys: [])
        #expect(secret == nil)
        #expect(c == before)
    }

    @Test("A deleted key replaced by a pasted PEM goes to a fresh item")
    func deletedKeyReplacedByPEM() {
        var c = using(key)
        let secret = save(&c, .key, selected: key.id, keys: [], pem: "-----BEGIN OPENSSH PRIVATE KEY-----")
        #expect(secret == "-----BEGIN OPENSSH PRIVATE KEY-----")
        #expect(c.keychainRef == "moshpit.secret.fresh")
        #expect(c.sshKeyId == nil)
        #expect(c.sshKeyAlgorithmRaw == nil)
    }

    @Test("Switching a managed-key connection to Password never writes into the key's item")
    func passwordDoesNotOverwriteKey() {
        var c = using(key)
        let secret = save(&c, .password, selected: key.id, keys: [key], password: "hunter2")
        #expect(secret == "hunter2")
        #expect(c.keychainRef == "moshpit.secret.fresh")
        #expect(c.sshKeyId == nil)
    }

    @Test("Switching away with no new secret lets go of the key's item")
    func switchingAwayDropsKeyRef() {
        var c = using(key)
        let secret = save(&c, .password, selected: key.id, keys: [key])
        #expect(secret == nil)
        // Holding on would make it connection-owned, and deleting the
        // connection would then delete the key.
        #expect(c.keychainRef == nil)
        #expect(c.sshKeyId == nil)
    }

    @Test("A connection's own password survives an edit that doesn't retype it")
    func ownPasswordKept() {
        var c = ServerConnection()
        c.keychainRef = "moshpit.secret.own"
        let secret = save(&c, .password, keys: [key])
        #expect(secret == nil)
        #expect(c.keychainRef == "moshpit.secret.own")
    }

    @Test("A new password for a connection-owned item reuses that item")
    func ownPasswordReplaced() {
        var c = ServerConnection()
        c.keychainRef = "moshpit.secret.own"
        let secret = save(&c, .password, keys: [key], password: "hunter3")
        #expect(secret == "hunter3")
        #expect(c.keychainRef == "moshpit.secret.own")
    }

    @Test("A new connection's password gets a fresh item")
    func newConnectionPassword() {
        var c = ServerConnection()
        let secret = save(&c, .password, keys: [], password: "hunter2")
        #expect(secret == "hunter2")
        #expect(c.keychainRef == "moshpit.secret.fresh")
    }
}
