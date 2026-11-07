import CryptoKit
import Foundation
import Observation

/// Local reading preferences. Hosts are separate; queries, fragments, cookies
/// and document contents never enter the persisted library.
@Observable @MainActor
final class PreviewPreferences {
    static let shared = PreviewPreferences(defaults: .standard)
    struct WebEntry: Codable, Equatable, Identifiable {
        var id: UUID
        let scope: String
        let address: String
        var favorite: Bool
        var usedAt: Date
    }
    struct ReadingPosition: Codable, Equatable {
        let block: String
        let index: Int
        let offset: Double
        let ratio: Double
        var isValid: Bool {
            !block.isEmpty && block.count <= 32 && (0...200_000).contains(index)
                && offset.isFinite && ratio.isFinite && (0...1).contains(offset) && (0...1).contains(ratio)
        }
        init?(message: [String: Any]) {
            guard let block = message["block"] as? String, let index = message["index"] as? Int,
                  let offset = message["offset"] as? Double, let ratio = message["ratio"] as? Double else { return nil }
            self.block = block; self.index = index; self.offset = offset; self.ratio = ratio
            guard isValid else { return nil }
        }
        var arguments: [String: Any] { ["block": block, "index": index, "offset": offset, "ratio": ratio] }
    }
    private struct SavedPosition: Codable { let position: ReadingPosition; let savedAt: Date }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    private(set) var webEntries: [WebEntry]
    @ObservationIgnored private var positions: [String: SavedPosition]
    @ObservationIgnored private var leases: [String: UUID] = [:]

    init(defaults: UserDefaults, key: String = "Hermit.preview.v1") {
        self.defaults = defaults; self.key = key
        let entries = defaults.data(forKey: key + ".web").flatMap { try? JSONDecoder().decode([WebEntry].self, from: $0) } ?? []
        webEntries = entries.filter { !$0.scope.isEmpty && Self.savedAddress($0.address) == $0.address }
        positions = defaults.data(forKey: key + ".reading").flatMap { try? JSONDecoder().decode([String: SavedPosition].self, from: $0) } ?? [:]
        positions = positions.filter { $0.value.position.isValid }
        trimWeb()
        trimReading()
    }
    static func savedAddress(_ input: String) -> String? {
        guard input.utf8.count <= 2048, let address = try? RemoteWebAddress(input),
              var url = URLComponents(url: address.url, resolvingAgainstBaseURL: false) else { return nil }
        url.host = "localhost"; url.scheme = "http"; url.port = address.port
        url.query = nil; url.fragment = nil
        return url.url?.absoluteString
    }
    func favorites(scope: String) -> [WebEntry] {
        webEntries.filter { $0.scope == scope && $0.favorite }.sorted { $0.usedAt > $1.usedAt }
    }
    func recent(scope: String) -> [WebEntry] {
        Array(webEntries.filter { $0.scope == scope && !$0.favorite }.sorted { $0.usedAt > $1.usedAt }.prefix(12))
    }
    func isFavorite(scope: String, address: String) -> Bool {
        guard let address = Self.savedAddress(address) else { return false }
        return webEntries.contains { $0.scope == scope && $0.address == address && $0.favorite }
    }
    func record(scope: String, address: String) {
        guard !scope.isEmpty, let address = Self.savedAddress(address) else { return }
        if let index = webEntries.firstIndex(where: { $0.scope == scope && $0.address == address }) {
            webEntries[index].usedAt = .now
        } else {
            webEntries.append(WebEntry(id: UUID(), scope: scope, address: address, favorite: false, usedAt: .now))
        }
        saveWeb()
    }
    @discardableResult func toggleFavorite(scope: String, address: String) -> Bool {
        guard !scope.isEmpty, let address = Self.savedAddress(address) else { return false }
        let index = webEntries.firstIndex { $0.scope == scope && $0.address == address }
        let removing = index.map { webEntries[$0].favorite } ?? false
        guard removing || webEntries.filter(\.favorite).count < 64 else { return false }
        if let index { webEntries[index].favorite.toggle(); webEntries[index].usedAt = .now }
        else { webEntries.append(WebEntry(id: UUID(), scope: scope, address: address, favorite: true, usedAt: .now)) }
        saveWeb(); return true
    }
    func clearRecent(scope: String) { webEntries.removeAll { $0.scope == scope && !$0.favorite }; saveWeb() }
    private func trimWeb() {
        let favorites = Array(webEntries.filter(\.favorite).sorted { $0.usedAt > $1.usedAt }.prefix(64))
        var counts: [String: Int] = [:]
        let recent = webEntries.filter { !$0.favorite }.sorted { $0.usedAt > $1.usedAt }.filter {
            counts[$0.scope, default: 0] += 1
            return counts[$0.scope, default: 0] <= 12
        }
        webEntries = favorites + recent.prefix(128)
    }
    private func saveWeb() {
        trimWeb()
        if let data = try? JSONEncoder().encode(webEntries) { defaults.set(data, forKey: key + ".web") }
    }
    static func readingKey(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func beginReading(_ identity: String) -> UUID {
        let digest = Self.readingKey(identity), lease = UUID()
        if leases.count > 256 { leases.removeAll() }
        leases[digest] = lease
        return lease
    }
    func readingPosition(_ identity: String) -> ReadingPosition? { positions[Self.readingKey(identity)]?.position }
    func recordReading(_ position: ReadingPosition, identity: String, lease: UUID) {
        let digest = Self.readingKey(identity)
        guard leases[digest] == lease, position.isValid else { return }
        positions[digest] = SavedPosition(position: position, savedAt: .now)
        trimReading()
    }
    func flushReading() {
        if let data = try? JSONEncoder().encode(positions) { defaults.set(data, forKey: key + ".reading") }
    }
    private func trimReading() {
        positions = Dictionary(uniqueKeysWithValues: positions.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(256).map { ($0.key, $0.value) })
    }
}
