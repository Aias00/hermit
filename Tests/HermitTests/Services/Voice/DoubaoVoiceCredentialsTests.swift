import Foundation
import Testing
@testable import Moshpit

@Suite("Doubao voice credentials")
struct DoubaoVoiceCredentialsTests {
    @Test("A key stays in a non-portable provider keychain item and invalid edits preserve the saved key")
    func credentialLifecycle() async throws {
        let keychain = KeychainService.inMemory()
        let vault = DoubaoVoiceCredentials(keychain: keychain)
        #expect(await !vault.hasKey())
        await #expect(throws: DoubaoVoiceFailure.missingAPIKey) { try await vault.apiKey() }
        try await vault.save(" unit-test-key\n")
        #expect(await vault.hasKey())
        #expect(try await vault.apiKey() == "unit-test-key")
        #expect(!KeychainService.isPortableSSHReference(DoubaoVoiceCredentials.keychainReference))
        await #expect(throws: DoubaoVoiceFailure.invalidAPIKey) { try await vault.save("invalid key") }
        #expect(try await vault.apiKey() == "unit-test-key")
        try await vault.clear()
        try await vault.clear()
        #expect(await !vault.hasKey())
        await #expect(throws: DoubaoVoiceFailure.missingAPIKey) { try await vault.apiKey() }
    }
}
