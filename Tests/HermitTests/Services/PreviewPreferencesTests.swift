import Foundation
import Testing
@testable import Moshpit

@Suite("Host-bound preview preferences") @MainActor
struct PreviewPreferencesTests {
    private func withStore(_ body: (PreviewPreferences, UserDefaults) throws -> Void) throws {
        let suite = "Hermit.preview-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PreviewPreferences(defaults: defaults), defaults)
    }
    @Test("Recent addresses and favorites survive reopening, stay host-bound and omit tokens")
    func hostIsolationAndPrivacy() throws {
        try withStore { store, defaults in
            store.record(scope: "host-a", address: "http://127.0.0.1:5173/demo?token=PRIVATE#secret")
            store.record(scope: "host-b", address: "localhost:3000")
            #expect(store.recent(scope: "host-a").map(\.address) == ["http://localhost:5173/demo"])
            #expect(store.recent(scope: "host-b").count == 1)
            #expect(store.toggleFavorite(scope: "host-a", address: "localhost:5173/demo?q=x"))
            #expect(store.isFavorite(scope: "host-a", address: "localhost:5173/demo"))
            #expect(!store.isFavorite(scope: "host-b", address: "localhost:5173/demo"))
            store.record(scope: "host-a", address: "http://user:password@localhost:3000")
            let reopened = PreviewPreferences(defaults: defaults)
            #expect(reopened.favorites(scope: "host-a").count == 1)
            #expect(reopened.recent(scope: "host-a").isEmpty)
            let data = try #require(defaults.data(forKey: "Hermit.preview.v1.web"))
            let json = String(decoding: data, as: UTF8.self)
            #expect(!json.contains("PRIVATE") && !json.contains("secret") && !json.contains("password"))
            reopened.clearRecent(scope: "host-b")
            #expect(reopened.recent(scope: "host-b").isEmpty)
            #expect(reopened.favorites(scope: "host-a").count == 1)
        }
    }
    @Test("Recents are bounded and clearing them keeps favorites")
    func boundedHistory() throws {
        try withStore { store, _ in
            _ = store.toggleFavorite(scope: "host-a", address: "localhost:8080")
            for port in 3000..<3040 { store.record(scope: "host-a", address: "localhost:\(port)") }
            #expect(store.recent(scope: "host-a").count == 12)
            store.clearRecent(scope: "host-a")
            #expect(store.recent(scope: "host-a").isEmpty)
            #expect(store.favorites(scope: "host-a").count == 1)
            #expect(store.toggleFavorite(scope: "host-a", address: "localhost:8080"))
            #expect(store.favorites(scope: "host-a").isEmpty)
        }
    }
    @Test("Late reader callbacks cannot overwrite the current reader and disk stores no document text")
    func readingLeases() throws {
        try withStore { store, defaults in
            let identity = "remote:host-a:/private/project/README.md"
            let a = try #require(PreviewPreferences.ReadingPosition(message: ["block":"abc", "index":5, "offset":0.2, "ratio":0.4]))
            let b = try #require(PreviewPreferences.ReadingPosition(message: ["block":"def", "index":7, "offset":0.4, "ratio":0.8]))
            let old = store.beginReading(identity), current = store.beginReading(identity)
            store.recordReading(b, identity: identity, lease: current)
            store.recordReading(a, identity: identity, lease: old)
            store.flushReading()
            #expect(store.readingPosition(identity) == b)
            let reopened = PreviewPreferences(defaults: defaults)
            #expect(reopened.readingPosition(identity) == b)
            #expect(reopened.readingPosition("remote:host-b:/private/project/README.md") == nil)
            let json = String(decoding: try #require(defaults.data(forKey: "Hermit.preview.v1.reading")), as: UTF8.self)
            #expect(!json.contains("README") && !json.contains("project"))
            #expect(PreviewPreferences.ReadingPosition(message: ["block":"abc", "index":0, "offset":Double.nan, "ratio":0.5]) == nil)
        }
    }
}
