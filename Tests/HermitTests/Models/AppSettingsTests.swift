import Foundation
import Testing
@testable import Moshpit

/// Tests for `AppSettings` use an isolated `UserDefaults` suite per test so
/// they never read or pollute the device's standard defaults. Each test
/// removes its persistent domain on exit to guarantee no cross-test leakage.
@Suite("AppSettings")
struct AppSettingsTests {

    /// Helper that allocates a fresh suite-name and matching `UserDefaults`.
    /// Returns the name so the caller can clean it up via `removePersistentDomain`.
    private static func makeDefaults() -> (UserDefaults, String) {
        let name = "test.appsettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test("default values match the prototype: fontSize=13, Remote Navy, block teal cursor")
    func defaults() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.fontSize == 13)
        #expect(settings.themeId == "remote-navy")
        #expect(settings.cursorShape == .block)
        #expect(settings.cursorColorId == "teal")
        #expect(settings.cursorBlink)
        #expect(settings.trailOnPredict)
        #expect(settings.moshByDefault)
        #expect(settings.predictMode == .adaptive)
        #expect(settings.udpRangeStart == 60000)
        #expect(settings.udpRangeEnd == 61000)
    }

    @Test("Reference appearance migrates the old default once and preserves other themes", arguments: ["github-dark", "nord", "custom-user-theme"])
    func referenceAppearanceMigration(previous: String) {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(previous, forKey: "moshpit.settings.themeId")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.themeId == (previous == "github-dark" ? "remote-navy" : previous))
        settings.themeId = "github-dark"
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.themeId == "github-dark", "later choices must not be migrated again")
    }

    @Test("small legacy fonts upgrade once without overriding later user choices", arguments: [9.0, 22.0])
    func readableFontMigration(previous: Double) {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(previous, forKey: "moshpit.settings.fontSize")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.fontSize == max(13, previous))
        settings.fontSize = 10
        #expect(AppSettings(defaults: defaults).fontSize == 10)
    }

    @Test("Cloud voice requires explicit engine selection and stays out of synced preferences")
    @MainActor func cloudVoiceSelection() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceEngine == .apple)
        #expect(settings.dictationRequest.doubaoResourceID == DoubaoVoiceClient.defaultResourceID)
        let snapshot = CloudSyncPreferences(settings)
        settings.voiceEngine = .doubao
        settings.doubaoResourceID = "  test.resource  "
        #expect(settings.dictationRequest.engine == .doubao)
        #expect(settings.dictationRequest.doubaoResourceID == "test.resource")
        #expect(AppSettings(defaults: defaults).voiceEngine == .doubao)
        snapshot.apply(to: settings)
        #expect(settings.voiceEngine == .doubao)
        let encoded = try JSONEncoder().encode(CloudSyncPreferences(settings))
        let value = String(decoding: encoded, as: UTF8.self)
        #expect(!value.contains("doubao") && !value.contains("test.resource"))
    }

    @Test("set then get returns the written value on the same instance")
    func setAndGet() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        settings.fontSize = 18
        settings.themeId = "solarized-dark"
        #expect(settings.fontSize == 18)
        #expect(settings.themeId == "solarized-dark")
    }

    @Test("Voice vocabulary starts empty, persists locally and snapshots into local requests")
    @MainActor func voiceVocabularyPersistenceAndSnapshot() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceVocabulary.isEmpty)
        #expect(settings.dictationRequest.contextualStrings.isEmpty)
        settings.voiceVocabulary = " Hermit \nDocker\nhermit\n"
        #expect(settings.voiceVocabulary == "Hermit\nDocker")
        let firstRequest = settings.dictationRequest
        #expect(firstRequest.contextualStrings == ["Hermit", "Docker"])
        settings.voiceVocabulary = "Cloudflare"
        #expect(firstRequest.contextualStrings == ["Hermit", "Docker"])
        #expect(AppSettings(defaults: defaults).voiceContextualStrings == ["Cloudflare"])

        settings.voiceEngine = .whisper
        #expect(settings.dictationRequest.contextualStrings == ["Cloudflare"])
        settings.voiceEngine = .doubao
        #expect(settings.dictationRequest.contextualStrings.isEmpty)
        #expect(settings.voiceVocabulary == "Cloudflare")
        let synced = String(decoding: try JSONEncoder().encode(CloudSyncPreferences(settings)), as: UTF8.self)
        #expect(!synced.contains("Cloudflare") && !synced.contains("voiceVocabulary"))
    }

    @Test("Invalid vocabulary edits preserve the last valid value and clearing is explicit")
    func voiceVocabularyInvalidEdit() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceVocabulary = "Hermit"
        settings.voiceVocabulary = "Hermit\n" + String(repeating: "x", count: 65)
        #expect(settings.voiceVocabulary == "Hermit")
        settings.voiceVocabulary = String(repeating: "x", count: 4_097)
        #expect(settings.voiceVocabulary == "Hermit")
        settings.voiceVocabulary = "\n  \n"
        #expect(settings.voiceVocabulary.isEmpty)
        #expect(AppSettings(defaults: defaults).dictationRequest.contextualStrings.isEmpty)
    }

    @Test("Corrupt persisted vocabulary remains editable but does not reach a recognizer")
    func voiceVocabularyCorruptStoredValue() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let badValue = String(repeating: "x", count: 65)
        defaults.set(badValue, forKey: "hermit.settings.voiceVocabulary")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceVocabulary == badValue)
        #expect(settings.voiceContextualStrings.isEmpty)
    }

    @Test("values persist across separate AppSettings instances backed by the same defaults")
    func persistenceAcrossInstances() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let writer = AppSettings(defaults: defaults)
        writer.fontSize = 22
        writer.themeId = "monokai"

        let reader = AppSettings(defaults: defaults)
        #expect(reader.fontSize == 22)
        #expect(reader.themeId == "monokai")
    }

    @Test("themeId round-trips a non-default value")
    func themeIdRoundTrip() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        settings.themeId = "nord"
        #expect(settings.themeId == "nord")

        // Confirm the new value survives a fresh instance too.
        let reread = AppSettings(defaults: defaults)
        #expect(reread.themeId == "nord")
    }
}
