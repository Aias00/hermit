import Foundation

/// Deliberately separate from free-form OSLog. Only typed operational facts
/// enter automatic reporting; terminal text and arbitrary Error descriptions
/// have no field here.
struct DiagnosticRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case ssh, health, lifecycle, network, tailscale }
    let id: UUID
    let at: Date
    let kind: Kind
    let connection: UUID?
    let attempt: UUID?
    let route: String?
    let phase: String?
    let outcome: String?
    let code: String?
    let value: Int?

    init(kind: Kind, connection: UUID? = nil, attempt: UUID? = nil,
         route: ConnectionTransport? = nil, phase: SSHConnectionDiagnostic.Phase? = nil,
         outcome: SSHConnectionDiagnostic.Outcome? = nil, code: String? = nil, value: Int? = nil) {
        id = UUID(); at = Date(); self.kind = kind; self.connection = connection
        self.attempt = attempt; self.route = route?.rawValue; self.phase = phase?.rawValue
        self.outcome = outcome?.rawValue
        // Call sites supply fixed classifiers, never messages or addresses.
        self.code = code.flatMap { $0.range(of: "^[a-z][a-z0-9.-]{0,79}$", options: .regularExpression) != nil ? $0 : nil }
        self.value = value.map { min(max($0, 0), 7 * 24 * 3600) }
    }

    static func ssh(_ event: SSHConnectionDiagnostic) -> Self {
        Self(kind: .ssh, connection: event.connectionID, attempt: event.attemptID,
             route: event.route, phase: event.phase, outcome: event.outcome, code: event.errorClass)
    }
}

struct DiagnosticBatch: Codable, Sendable {
    let schema: Int
    let batchID: UUID
    let installationID: UUID
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let events: [DiagnosticRecord]
}

/// All disk work is confined to this actor. The ring is capped at 3 MB / seven
/// days, excluded from backup, and contains no host names or credential data.
actor DiagnosticJournal {
    static let shared = DiagnosticJournal(root: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                         in: .userDomainMask)[0]
        .appendingPathComponent("HermitDiagnostics", isDirectory: true))
    let root: URL
    private let maxBytes: Int
    private let retention: TimeInterval
    private var records: [DiagnosticRecord] = []
    private var loaded = false
    private var isRecording = false

    init(root: URL, maxBytes: Int = 3 * 1024 * 1024, retention: TimeInterval = 7 * 86400) {
        self.root = root; self.maxBytes = maxBytes; self.retention = retention
    }

    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .custom { date, encoder in
            var field = encoder.singleValueContainer()
            try field.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return value
    }

    static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let field = try decoder.singleValueContainer()
            let text = try field.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: field, debugDescription: "Invalid diagnostic timestamp")
        }
        return value
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        guard !loaded else { return }
        if let data = try? Data(contentsOf: root.appendingPathComponent("current.json")), data.count <= 128 * 1024 {
            records = (try? Self.decoder().decode([DiagnosticRecord].self, from: data)) ?? []
        }
        records.removeAll { $0.at < Date().addingTimeInterval(-retention) }
        loaded = true
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func setRecording(_ enabled: Bool) { isRecording = enabled }

    func append(_ record: DiagnosticRecord) {
        guard isRecording else { return }
        do {
            try prepare()
            records.append(record)
            if records.count >= 128 { _ = try seal() }
            else { try protectedWrite(Self.encoder().encode(records), to: root.appendingPathComponent("current.json")) }
            try trim()
        } catch {
            // Diagnostics cannot fail the SSH operation being diagnosed.
            records = Array(records.suffix(128))
        }
    }

    @discardableResult private func seal() throws -> URL? {
        records.removeAll { $0.at < Date().addingTimeInterval(-retention) }
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("current.json"))
            return nil
        }
        let identityURL = root.appendingPathComponent("installation-id")
        let identity: UUID
        if let data = try? Data(contentsOf: identityURL), let text = String(data: data, encoding: .utf8), let saved = UUID(uuidString: text) {
            identity = saved
        } else {
            identity = UUID(); try protectedWrite(Data(identity.uuidString.utf8), to: identityURL)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let batch = DiagnosticBatch(schema: 1, batchID: UUID(), installationID: identity, createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            events: Array(records.suffix(128)))
        let file = root.appendingPathComponent(batch.batchID.uuidString.lowercased() + ".batch.json")
        try protectedWrite(Self.encoder().encode(batch), to: file)
        records.removeAll(keepingCapacity: true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("current.json"))
        return file
    }

    func pending(sealCurrent: Bool = true) throws -> [URL] {
        try prepare()
        if sealCurrent { _ = try seal() }
        try trim()
        return try batchFiles().sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    func acknowledge(_ file: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              file.lastPathComponent.hasSuffix(".batch.json") else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func stageUpload(_ file: URL, configurationID: UUID) throws -> URL {
        guard file.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              file.lastPathComponent.hasSuffix(".batch.json") else { throw DiagnosticReportingError.invalidConfiguration }
        let stage = uploadCopy(file.lastPathComponent, configurationID: configurationID)
        try protectedWrite(Data(contentsOf: file), to: stage)
        return stage
    }

    /// Return the immutable upload's size so only acknowledged bytes are charged.
    @discardableResult func discardUpload(_ filename: String, configurationID: UUID) -> Int {
        guard UUID(uuidString: String(filename.dropLast(".batch.json".count))) != nil,
              filename.hasSuffix(".batch.json") else { return 0 }
        let file = uploadCopy(filename, configurationID: configurationID)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try? FileManager.default.removeItem(at: file)
        return size
    }

    private func uploadCopy(_ filename: String, configurationID: UUID) -> URL {
        root.appendingPathComponent("upload-" + configurationID.uuidString + "-" + filename)
    }

    func clear() throws {
        records.removeAll(); loaded = false
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        // The receiver binds its device credential to this installation identity.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent != "installation-id" {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func batchFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.lastPathComponent.hasSuffix(".batch.json") && !$0.lastPathComponent.hasPrefix("upload-") }
    }

    private func trim() throws {
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            where file.lastPathComponent.hasPrefix("upload-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < Date().addingTimeInterval(-86400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        var files: [(URL, Int, Date)] = []
        for file in try batchFiles() {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values.contentModificationDate ?? .distantPast
            if modified < Date().addingTimeInterval(-retention) { try? FileManager.default.removeItem(at: file) }
            else { files.append((file, values.fileSize ?? 0, modified)) }
        }
        var total = files.reduce(0) { $0 + $1.1 }
        for (file, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
            try? FileManager.default.removeItem(at: file); total -= size
        }
    }
}
