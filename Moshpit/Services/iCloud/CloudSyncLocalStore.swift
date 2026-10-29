import Foundation
import UIKit
import CryptoKit

struct CloudSyncPreferences: Codable {
    var fontSize: Double
    var fontName: String
    var themeId: String
    var appThemeId: String
    var cursorShape: String
    var cursorColor: String
    var cursorBlink: Bool
    var trailOnPredict: Bool
    var keepAlive: Bool
    var raiseKeyboard: Bool
    var voiceInput: Bool
    var voiceLocale: String
    var whisperLanguage: String

    @MainActor init(_ settings: AppSettings) {
        fontSize = settings.fontSize; fontName = settings.fontName
        themeId = settings.themeId; appThemeId = settings.appThemeId
        cursorShape = settings.cursorShape.rawValue; cursorColor = settings.cursorColorId
        cursorBlink = settings.cursorBlink; trailOnPredict = settings.trailOnPredict
        keepAlive = settings.keepConnectionsAlive; raiseKeyboard = settings.raiseKeyboardOnOpen
        voiceInput = settings.voiceInputEnabled; voiceLocale = settings.voiceInputLocaleId
        whisperLanguage = settings.whisperLanguage
    }

    func validated() throws -> Self {
        guard fontSize.isFinite, (6...72).contains(fontSize), CursorShape(rawValue: cursorShape) != nil,
              [fontName, themeId, appThemeId, cursorColor, voiceLocale, whisperLanguage]
                .allSatisfy({ $0.utf8.count <= 256 }) else { throw CloudSyncError.invalidData }
        return self
    }

    @MainActor func apply(to settings: AppSettings) {
        settings.fontSize = fontSize; settings.fontName = fontName
        settings.themeId = themeId; settings.appThemeId = appThemeId
        settings.cursorShape = CursorShape(rawValue: cursorShape) ?? .block
        settings.cursorColorId = cursorColor; settings.cursorBlink = cursorBlink
        settings.trailOnPredict = trailOnPredict; settings.keepConnectionsAlive = keepAlive
        settings.raiseKeyboardOnOpen = raiseKeyboard
        settings.voiceInputEnabled = voiceInput; settings.voiceInputLocaleId = voiceLocale
        settings.whisperLanguage = whisperLanguage
    }
}

struct CloudSyncAppTheme: Codable {
    var id: String
    var name: String
    var accent: String
}

struct CloudSyncCredential: Codable {
    var reference: String
    var bytes: Data
    var requireBiometry: Bool
}

/// Deliberately enumerates syncable domains. Neither the entire defaults
/// dictionary nor a Keychain dump is ever uploaded.
@MainActor
final class CloudSyncLocalStore {
    let defaults: UserDefaults
    let connections: ConnectionStore
    let keys: SSHKeyStore
    let themes: ThemeStore
    let appThemes: AppThemeStore
    let shortcuts: ShortcutStore
    let settings: AppSettings
    let keychain: KeychainService
    let protectedDataAvailable: @MainActor () -> Bool
    private let writer = UUID().uuidString // capture versions are filled by merge

    init(connections: ConnectionStore, keys: SSHKeyStore, themes: ThemeStore,
         appThemes: AppThemeStore, shortcuts: ShortcutStore, settings: AppSettings,
         keychain: KeychainService, protectedDataAvailable: @escaping @MainActor () -> Bool = {
             UIApplication.shared.isProtectedDataAvailable
         }) {
        self.connections = connections; self.keys = keys; self.themes = themes
        self.appThemes = appThemes; self.shortcuts = shortcuts; self.settings = settings
        self.keychain = keychain; self.defaults = settings.store
        self.protectedDataAvailable = protectedDataAvailable
    }

    func requireReadable() throws {
        guard protectedDataAvailable() else { throw CloudSyncError.locked }
        connections.reloadIfNeeded(); keys.reloadIfNeeded(); themes.reloadIfNeeded()
        appThemes.reloadIfNeeded(); shortcuts.reloadIfNeeded(); settings.reloadIfNeeded()
        guard connections.isAuthoritative, keys.isAuthoritative, themes.isAuthoritative,
              appThemes.isAuthoritative, shortcuts.isAuthoritative else { throw CloudSyncError.locked }
        // A store's display fallback [] is not proof that its persisted JSON
        // was valid. Never turn a corrupt read into a cloud deletion.
        let connectionDecoder = JSONDecoder(); connectionDecoder.dateDecodingStrategy = .iso8601
        try check([ServerConnection].self, key: "moshpit.connections", decoder: connectionDecoder)
        try check([SSHKeyRecord].self, key: "moshpit.sshkeys.v1")
        try check([TerminalTheme].self, key: "moshpit.settings.customThemes")
        try check([CloudSyncAppTheme].self, key: "moshpit.settings.customAppThemes")
        try check([TerminalShortcut].self, key: "moshpit.shortcuts.v1")
        for suffix in ["fontName", "themeId", "appThemeId", "cursorShape", "cursorColor", "voiceInputLocale", "whisperLanguage"] {
            if let value = defaults.object(forKey: "moshpit.settings." + suffix), !(value is String) {
                throw CloudSyncError.invalidData
            }
        }
        for suffix in ["cursorBlink", "trailOnPredict", "keepAlive", "raiseKeyboardOnOpen", "voiceInput"] {
            if let value = defaults.object(forKey: "moshpit.settings." + suffix), !(value is Bool) {
                throw CloudSyncError.invalidData
            }
        }
        if let value = defaults.object(forKey: "moshpit.settings.fontSize"), !(value is Double) {
            throw CloudSyncError.invalidData
        }
    }

    private func check<T: Decodable>(_ type: T.Type, key: String, decoder: JSONDecoder = JSONDecoder()) throws {
        guard let object = defaults.object(forKey: key) else { return }
        guard let data = object as? Data, (try? decoder.decode(type, from: data)) != nil else {
            throw CloudSyncError.invalidData
        }
    }

    static func isPortable(_ key: SSHKeyRecord) -> Bool {
        (key.source == .generated || key.source == .imported) &&
            key.algorithm != .seP256 && key.algorithm != .ecdsaSK
    }

    static func portableHost(_ value: ServerConnection) -> ServerConnection {
        var value = value
        value.tailcatCredentialRef = nil
        value.tailscaleAccountID = nil
        value.lastConnectedAt = nil
        // ConnectionStore's existing ISO-8601 persistence has second precision.
        value.createdAt = Date(timeIntervalSince1970: floor(value.createdAt.timeIntervalSince1970))
        if value.sshKeyAlgorithm == .seP256 || value.sshKeyAlgorithm == .ecdsaSK {
            value.keychainRef = nil; value.sshKeyId = nil
        }
        return value
    }

    func capture(includeCredentials: Bool, allowAuthentication: Bool) async throws -> CloudSyncCapture {
        try requireReadable()
        var result = CloudSyncCapture(includesCredentials: includeCredentials)
        var credentialHashKey: Data?
        func add<T: Encodable>(_ value: T, domain: CloudSyncDomain, id: String) throws {
            let identity = domain.rawValue + "/" + id
            guard result.values[identity] == nil else { throw CloudSyncError.invalidData }
            let payload = try JSONEncoder.cloudSync.encode(value)
            result.values[identity] = CloudSyncObject(id: identity, domain: domain, revision: 0,
                writer: writer, payload: payload)
            if domain == .credential {
                guard let credentialHashKey else { throw CloudSyncError.locked }
                result.hashes[identity] = Data(HMAC<SHA256>.authenticationCode(for: payload,
                    using: SymmetricKey(data: credentialHashKey))).base64EncodedString()
            } else { result.hashes[identity] = CloudSyncObject.digest(payload) }
        }
        var refs: [String: Bool] = [:]
        for value in connections.connections {
            let portable = Self.portableHost(value)
            try add(portable, domain: .host, id: value.id.uuidString)
            if let ref = portable.keychainRef, KeychainService.isPortableSSHReference(ref) {
                // A key removed from the key library still serves existing
                // hosts. Missing metadata must not downgrade its protection.
                refs[ref] = portable.authMethod == .key
            }
        }
        for value in keys.keys where Self.isPortable(value) {
            var value = value; value.lastUsedAt = nil; value.boundHosts.sort()
            try add(value, domain: .key, id: value.id.uuidString)
            if let ref = value.keychainRef, KeychainService.isPortableSSHReference(ref) { refs[ref] = value.requireBiometry }
        }
        for value in themes.customThemes { try add(value, domain: .theme, id: value.id) }
        for value in appThemes.customThemes {
            try add(CloudSyncAppTheme(id: value.id, name: value.name, accent: value.accentHex),
                    domain: .appTheme, id: value.id)
        }
        // Set properties inside shortcuts are normalized by the JSONEncoder
        // helper below so repeated captures do not create spurious revisions.
        try add(shortcuts.shortcuts.map(CloudSyncShortcut.init), domain: .shortcuts, id: "toolbar")
        try add(CloudSyncPreferences(settings).validated(), domain: .preferences, id: "appearance")
        if includeCredentials {
            var exported: [String: Data] = [:]
            for ref in refs.keys.sorted() {
                do {
                    exported[ref] = try await keychain.exportSSHSecret(ref: ref, allowAuthentication: allowAuthentication)
                } catch KeychainError.notFound {
                    result.unknownIDs.insert(CloudSyncDomain.credential.rawValue + "/" + ref)
                } catch { throw CloudSyncError.locked }
            }
            if !refs.isEmpty {
                // A restored device backup carries metadata/journal but no
                // ThisDeviceOnly keys. When ALL referenced SSH secrets are
                // absent there is no local password edit to misclassify; a new
                // digest key safely permits recovery from encrypted cloud data.
                credentialHashKey = try await credentialDigestKey(allowRestoredDevice: exported.isEmpty)
            }
            for ref in exported.keys.sorted() {
                try add(CloudSyncCredential(reference: ref, bytes: exported[ref]!, requireBiometry: refs[ref] ?? false),
                        domain: .credential, id: ref)
            }
        }
        try requireReadable()
        return result
    }

    private func credentialDigestKey(allowRestoredDevice: Bool) async throws -> Data {
        let reference = "moshpit.icloud.digest-key.v1"
        do {
            let data = try await keychain.loadSecret(forRef: reference, reason: "Read iCloud sync integrity key")
            guard data.count == 32 else { throw CloudSyncError.invalidData }
            return data
        } catch KeychainError.notFound {
            // If a device-only key was removed, the old password digests no
            // longer mean anything. Do not reinterpret that as password edits.
            if !allowRestoredDevice, let data = defaults.data(forKey: CloudSyncService.journalKey),
               let journal = try? JSONDecoder().decode(CloudSyncJournal.self, from: data),
               journal.entries.values.contains(where: { $0.domain == .credential }) {
                throw CloudSyncError.invalidData
            }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try await keychain.saveSecret(key, forRef: reference, requireBiometry: false)
            return key
        }
    }

    /// Decode every object before writing anything; restore secrets first so
    /// host metadata never advertises a successfully restored missing secret.
    func apply(_ objects: [String: CloudSyncObject], includeCredentials: Bool,
               checkCurrent: () throws -> Void = {}) async throws {
        try checkCurrent()
        try requireReadable()
        let originalMetadata = try await capture(includeCredentials: false, allowAuthentication: false)
        try checkCurrent()
        var hosts = connections.connections
        var keyRecords = keys.keys
        var terminalThemes = themes.customThemes
        var accentThemes = appThemes.customThemes.map { CloudSyncAppTheme(id: $0.id, name: $0.name, accent: $0.accentHex) }
        var toolbar: [TerminalShortcut]?
        var preferences: CloudSyncPreferences?
        var credentials: [CloudSyncCredential] = []
        let deviceKeyReferences = Set(keys.keys.filter { !Self.isPortable($0) }.compactMap(\.keychainRef))
            .union(connections.connections.filter {
                $0.sshKeyAlgorithm == .seP256 || $0.sshKeyAlgorithm == .ecdsaSK
            }.compactMap(\.keychainRef))
        func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
            do { return try JSONDecoder().decode(type, from: data) }
            catch { throw CloudSyncError.invalidData }
        }
        for object in objects.values.sorted(by: { $0.id < $1.id }) {
            _ = try object.validated()
            let identity = String(object.id.dropFirst(object.domain.rawValue.count + 1))
            switch object.domain {
            case .host:
                guard let id = UUID(uuidString: identity) else { throw CloudSyncError.invalidData }
                let old = hosts.first { $0.id == id }
                if let data = object.payload {
                    var value = try decode(ServerConnection.self, data)
                    guard value.id == id, value == Self.portableHost(value) else { throw CloudSyncError.invalidData }
                    if let old {
                        if old.tailcatServerPublicKey == value.tailcatServerPublicKey {
                            value.tailcatCredentialRef = old.tailcatCredentialRef
                        }
                        if old.host == value.host && old.tailscalePeerID == value.tailscalePeerID {
                            value.tailscaleAccountID = old.tailscaleAccountID
                        }
                        if old.sshKeyAlgorithm == value.sshKeyAlgorithm,
                           value.sshKeyAlgorithm == .seP256 || value.sshKeyAlgorithm == .ecdsaSK {
                            value.keychainRef = old.keychainRef; value.sshKeyId = old.sshKeyId
                        }
                        value.lastConnectedAt = old.lastConnectedAt
                    }
                    if let index = hosts.firstIndex(where: { $0.id == id }) { hosts[index] = value }
                    else { hosts.append(value) }
                } else { hosts.removeAll { $0.id == id } }
            case .key:
                guard let id = UUID(uuidString: identity) else { throw CloudSyncError.invalidData }
                if let data = object.payload {
                    var value = try decode(SSHKeyRecord.self, data)
                    guard value.id == id, Self.isPortable(value) else { throw CloudSyncError.invalidData }
                    if let index = keyRecords.firstIndex(where: { $0.id == id }) {
                        guard Self.isPortable(keyRecords[index]) else { throw CloudSyncError.invalidData }
                        value.lastUsedAt = keyRecords[index].lastUsedAt; keyRecords[index] = value
                    } else { keyRecords.append(value) }
                } else { keyRecords.removeAll { $0.id == id && Self.isPortable($0) } }
            case .theme:
                if let data = object.payload {
                    var value = try decode(TerminalTheme.self, data)
                    guard value.id == identity, !TerminalTheme.builtIns.contains(where: { $0.id == identity }) else {
                        throw CloudSyncError.invalidData
                    }
                    value.isBuiltIn = false
                    if let index = terminalThemes.firstIndex(where: { $0.id == identity }) { terminalThemes[index] = value }
                    else { terminalThemes.append(value) }
                } else { terminalThemes.removeAll { $0.id == identity } }
            case .appTheme:
                if let data = object.payload {
                    let value = try decode(CloudSyncAppTheme.self, data)
                    guard value.id == identity, !AppThemeCatalog.builtIns.contains(where: { $0.id == identity }) else {
                        throw CloudSyncError.invalidData
                    }
                    if let index = accentThemes.firstIndex(where: { $0.id == identity }) { accentThemes[index] = value }
                    else { accentThemes.append(value) }
                } else { accentThemes.removeAll { $0.id == identity } }
            case .shortcuts:
                guard identity == "toolbar", let data = object.payload else { throw CloudSyncError.invalidData }
                toolbar = try decode([CloudSyncShortcut].self, data).map(\.value)
                guard let toolbar, !toolbar.isEmpty, Set(toolbar.map(\.id)).count == toolbar.count else {
                    throw CloudSyncError.invalidData
                }
            case .preferences:
                guard identity == "appearance", let data = object.payload else { throw CloudSyncError.invalidData }
                preferences = try decode(CloudSyncPreferences.self, data).validated()
            case .credential:
                guard includeCredentials, let data = object.payload else { continue }
                let value = try decode(CloudSyncCredential.self, data)
                guard value.reference == identity, KeychainService.isPortableSSHReference(identity),
                      !deviceKeyReferences.contains(identity),
                      !value.bytes.isEmpty, value.bytes.count < 500_000 else { throw CloudSyncError.invalidData }
                credentials.append(value)
            }
        }
        for credential in credentials {
            try checkCurrent()
            try requireReadable()
            try await keychain.restoreSSHSecret(credential.bytes, ref: credential.reference,
                                                requireBiometry: credential.requireBiometry)
            try checkCurrent()
        }
        try requireReadable()
        let currentMetadata = try await capture(includeCredentials: false, allowAuthentication: false)
        try checkCurrent()
        guard originalMetadata == currentMetadata else { throw CloudSyncError.localChanged }
        let connectionEncoder = JSONEncoder(); connectionEncoder.dateEncodingStrategy = .iso8601
        let hostData = try connectionEncoder.encode(hosts)
        let keyData = try JSONEncoder().encode(keyRecords)
        let themeData = try JSONEncoder().encode(terminalThemes)
        let accentData = try JSONEncoder().encode(accentThemes)
        let toolbarData = try toolbar.map { try JSONEncoder().encode($0) }
        defaults.set(hostData, forKey: "moshpit.connections")
        defaults.set(keyData, forKey: "moshpit.sshkeys.v1")
        defaults.set(themeData, forKey: "moshpit.settings.customThemes")
        defaults.set(accentData, forKey: "moshpit.settings.customAppThemes")
        if let toolbarData { defaults.set(toolbarData, forKey: "moshpit.shortcuts.v1") }
        connections.load(); keys.reloadAfterCloudSync(); themes.reloadAfterCloudSync()
        appThemes.reloadAfterCloudSync(); shortcuts.reloadAfterCloudSync()
        preferences?.apply(to: settings)
    }
}

/// Codable Set iteration is not a stable hash input. A canonical wrapper
/// keeps toolbar order while sorting only its unordered modifier/scope sets.
struct CloudSyncShortcut: Codable {
    var value: TerminalShortcut
    var modifiers: [ShortcutModifier]
    var scopeHosts: [String]
    init(_ value: TerminalShortcut) {
        self.value = value; modifiers = value.modifiers.sorted(); scopeHosts = value.scopeHosts.sorted()
        self.value.modifiers = []; self.value.scopeHosts = []
    }
    enum CodingKeys: String, CodingKey { case value, modifiers, scopeHosts }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(TerminalShortcut.self, forKey: .value)
        modifiers = try container.decode([ShortcutModifier].self, forKey: .modifiers)
        scopeHosts = try container.decode([String].self, forKey: .scopeHosts)
        value.modifiers = Set(modifiers); value.scopeHosts = Set(scopeHosts)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var stripped = value; stripped.modifiers = []; stripped.scopeHosts = []
        try container.encode(stripped, forKey: .value)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(scopeHosts, forKey: .scopeHosts)
    }
}
