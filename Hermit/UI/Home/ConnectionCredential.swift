import Foundation

/// What saving the connection editor does with credentials, decided in a pure
/// function these tests can hold still.
///
/// A managed SSH key owns its keychain item, and every connection that picked
/// the key points at that same item. So a connection only ever writes a secret
/// to — or keeps holding — a ref it owns itself (`sshKeyId == nil`): writing a
/// password into a managed key's ref would overwrite the private key under
/// every other connection using it, and keeping that ref as its own would let
/// deleting the connection delete the key.
enum ConnectionCredential {

    /// Points `connection` at its credential. Returns the secret the caller
    /// still has to write to the keychain at `connection.keychainRef`, or nil
    /// when there is nothing new to write.
    static func apply(
        to connection: inout ServerConnection,
        authMethod: AuthMethod,
        selectedKeyId: UUID?,
        keys: [SSHKeyRecord],
        password: String,
        privateKeyPEM: String,
        newRef: () -> String
    ) -> String? {
        if authMethod == .key, let id = selectedKeyId {
            if let key = keys.first(where: { $0.id == id }) {
                // Managed key: point at the key's own keychain blob; the raw
                // algorithm tells SSHService how to interpret it (SE keys are
                // dataRepresentation handles, not PEM).
                connection.keychainRef = key.keychainRef
                connection.sshKeyId = key.id
                connection.sshKeyAlgorithmRaw = key.algorithm.rawValue
                return nil
            }
            if id == connection.sshKeyId, privateKeyPEM.isEmpty {
                // Deleted from SSH Keys since: the list entry is gone but the
                // keychain item isn't, and this connection still signs with
                // it. Nothing new was pasted, so it stays pointed there.
                return nil
            }
        }

        let ownsRef = connection.sshKeyId == nil
        connection.sshKeyId = nil
        connection.sshKeyAlgorithmRaw = nil
        if !ownsRef { connection.keychainRef = nil }
        let secret = authMethod == .password ? password : privateKeyPEM
        // Empty = keep whatever this connection already stored for itself.
        guard !secret.isEmpty else { return nil }
        if connection.keychainRef == nil { connection.keychainRef = newRef() }
        return secret
    }
}
