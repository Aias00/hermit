import Foundation
import Testing
@testable import Moshpit

/// Exercises the actual SecItem backend used by Cloudflare Access, including
/// on Simulator. This must fail on missing entitlements or inaccessible storage;
/// neither the in-memory backend nor the simulator file vault is a substitute.
@Suite("Cloudflare system Keychain persistence")
struct CloudflareSystemKeychainTests {
    @Test("The real system Keychain saves, reloads and deletes an isolated synthetic credential")
    func systemRoundTrip() throws {
        let service = "com.cluas.moshpit.tests.cloudflare-system.\(UUID().uuidString)"
        let account = "synthetic-access-credential"
        let backend = SystemKeychainBackend(service: service)
        // Synthetic bytes only; assertions compare booleans, never emit contents.
        let secret = Data("synthetic-only-\(UUID().uuidString)".utf8)
        defer { try? backend.delete(account: account) }

        try backend.save(secret: secret, account: account, requireBiometry: false)
        #expect(backend.exists(account: account))
        // A fresh instance rules out success from an object-local cache.
        let reopened = SystemKeychainBackend(service: service)
        let loaded = try reopened.load(account: account, prompt: "Verify isolated test storage")
        #expect(loaded.elementsEqual(secret))
        try reopened.delete(account: account)
        #expect(!backend.exists(account: account))
        #expect(throws: KeychainError.notFound) {
            _ = try backend.load(account: account, prompt: "Verify test cleanup")
        }
    }
}
