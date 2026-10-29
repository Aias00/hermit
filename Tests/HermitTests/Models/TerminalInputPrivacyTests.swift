import Foundation
import Testing
@testable import Moshpit

@Suite("Terminal input privacy")
struct TerminalInputPrivacyTests {
    @Test("Legacy input history is purged without touching saved hosts or preferences")
    func clearsLegacyHistory() throws {
        let suite = "test.terminal.privacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["example-sensitive-input"]), forKey: "moshpit.composer.history.v1")
        defaults.set(17.0, forKey: "moshpit.settings.fontSize")
        TerminalInputPrivacy.removeLegacyHistory(defaults: defaults, readiness: .always)
        #expect(defaults.object(forKey: "moshpit.composer.history.v1") == nil)
        #expect(defaults.double(forKey: "moshpit.settings.fontSize") == 17)
    }

    @Test("A sealed preferences file is retried after unlock")
    func waitsForReadablePreferences() throws {
        let suite = "test.terminal.privacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1]), forKey: "moshpit.composer.history.v1")
        TerminalInputPrivacy.removeLegacyHistory(defaults: defaults, readiness: DefaultsReadiness { false })
        #expect(defaults.data(forKey: "moshpit.composer.history.v1") != nil)
        TerminalInputPrivacy.removeLegacyHistory(defaults: defaults, readiness: .always)
        #expect(defaults.object(forKey: "moshpit.composer.history.v1") == nil)
    }
}
