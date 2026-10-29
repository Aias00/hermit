import Foundation

/// Provider credentials are local keychain items, deliberately outside the
/// portable SSH-reference namespace and never embedded in a DictationRequest.
actor DoubaoVoiceCredentials {
    static let shared = DoubaoVoiceCredentials()
    static let keychainReference = "hermit.voice.doubao.api-key"
    private let keychain: KeychainService

    init(keychain: KeychainService = KeychainService()) { self.keychain = keychain }

    func hasKey() async -> Bool {
        await keychain.contains(ref: Self.keychainReference)
    }

    func save(_ key: String) async throws {
        let key = try DoubaoVoiceClient.validatedAPIKey(key)
        do {
            try await keychain.savePasswordPreservingAccessPolicy(
                key, forRef: Self.keychainReference, requireBiometry: false)
        } catch { throw DoubaoVoiceFailure.credentialsUnavailable }
    }

    func clear() async throws {
        do { try await keychain.delete(forRef: Self.keychainReference) }
        catch KeychainError.notFound { return }
        catch { throw DoubaoVoiceFailure.credentialsUnavailable }
    }

    func apiKey() async throws -> String {
        do {
            let key = try await keychain.loadPassword(forRef: Self.keychainReference,
                                                    reason: "Use Doubao speech recognition")
            return try DoubaoVoiceClient.validatedAPIKey(key)
        } catch KeychainError.notFound {
            throw DoubaoVoiceFailure.missingAPIKey
        } catch let failure as DoubaoVoiceFailure { throw failure }
        catch { throw DoubaoVoiceFailure.credentialsUnavailable }
    }
}
