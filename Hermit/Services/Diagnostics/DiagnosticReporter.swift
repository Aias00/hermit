import Foundation
import Observation
import Security
import UIKit

struct DiagnosticReceiverConfiguration: Codable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    var id = UUID()
    let endpoint: URL
    let token: String
    var description: String { "DiagnosticReceiverConfiguration(<private>)" }
    var debugDescription: String { description }

    init(endpoint: URL, token: String) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              (32...128).contains(token.utf8.count),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw DiagnosticReportingError.invalidConfiguration
        }
        self.endpoint = endpoint; self.token = token
    }

    static func from(_ url: URL) -> Self? {
        guard ["hermit-diagnostics", "hermit", "moshpit"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "diagnostics", url.path == "/configure",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 2, Set(items.map(\.name)) == Set(["endpoint", "token"]),
              let address = items.first(where: { $0.name == "endpoint" })?.value,
              let endpoint = URL(string: address), let token = items.first(where: { $0.name == "token" })?.value else { return nil }
        return try? Self(endpoint: endpoint, token: token)
    }
}

enum DiagnosticReportingError: Error { case invalidConfiguration, storageUnavailable }

/// Separate from SSH/iCloud secrets. Background uploads need AfterFirstUnlock
/// accessibility, and this device-specific credential must never sync.
enum DiagnosticReceiverCredentials {
    private static let service = "com.aias.hermit.diagnostic-receiver"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "receiver", kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> DiagnosticReceiverConfiguration? {
        #if targetEnvironment(simulator)
        let backend = FileVaultKeychainBackend(filename: "hermit-diagnostic-credentials.json")
        guard backend.exists(account: "receiver") else { return nil }
        let saved = try JSONDecoder().decode(DiagnosticReceiverConfiguration.self, from: backend.load(account: "receiver", prompt: ""))
        #else
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DiagnosticReportingError.storageUnavailable }
        let saved = try JSONDecoder().decode(DiagnosticReceiverConfiguration.self, from: data)
        #endif
        var validated = try DiagnosticReceiverConfiguration(endpoint: saved.endpoint, token: saved.token)
        validated.id = saved.id
        return validated
    }
    static func save(_ value: DiagnosticReceiverConfiguration) throws {
        let data = try JSONEncoder().encode(value)
        #if targetEnvironment(simulator)
        try FileVaultKeychainBackend(filename: "hermit-diagnostic-credentials.json").save(secret: data, account: "receiver", requireBiometry: false)
        #else
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw DiagnosticReportingError.storageUnavailable }
        } else if status != errSecSuccess { throw DiagnosticReportingError.storageUnavailable }
        #endif
    }
    static func delete() {
        #if targetEnvironment(simulator)
        try? FileVaultKeychainBackend(filename: "hermit-diagnostic-credentials.json").delete(account: "receiver")
        #else
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

/// Response bodies are bounded and never logged. A 2xx Access login page is
/// not an acknowledgement; it must echo this exact batch UUID as JSON.
final class DiagnosticUploadResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Data] = [:]
    func append(_ data: Data, task: Int) {
        lock.lock(); defer { lock.unlock() }
        if (values[task]?.count ?? 0) + data.count <= 8192 { values[task, default: Data()].append(data) }
    }
    func take(_ task: Int) -> Data { lock.lock(); defer { lock.unlock() }; return values.removeValue(forKey: task) ?? Data() }
    static func accepted(_ data: Data, status: Int, batchID: String) -> Bool {
        guard [200, 202].contains(status), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return value["acceptedBatchID"]?.lowercased() == batchID.lowercased()
    }
    static func sameEndpoint(request: URL?, response: URL?) -> Bool {
        guard let request, let response,
              let expected = URLComponents(url: request, resolvingAgainstBaseURL: false),
              let actual = URLComponents(url: response, resolvingAgainstBaseURL: false),
              expected.scheme == "https", actual.scheme == "https",
              expected.host?.lowercased() == actual.host?.lowercased(),
              (expected.port ?? 443) == (actual.port ?? 443),
              actual.user == nil, actual.password == nil, actual.query == nil, actual.fragment == nil else { return false }
        return (expected.percentEncodedPath.isEmpty ? "/" : expected.percentEncodedPath)
            == (actual.percentEncodedPath.isEmpty ? "/" : actual.percentEncodedPath)
    }
}

@MainActor @Observable
final class DiagnosticReporter: NSObject, URLSessionDataDelegate {
    static let shared = DiagnosticReporter()
    static var sessionIdentifier: String { (Bundle.main.bundleIdentifier ?? "hermit") + ".diagnostic-uploads.v1" }
    var proposedConfiguration: DiagnosticReceiverConfiguration?
    private(set) var configuration: DiagnosticReceiverConfiguration?
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: "hermit.diagnostics.enabled")
    private(set) var isUploading = false
    private(set) var pendingCount = 0
    private(set) var statusMessage: String?
    private(set) var lastSuccess = UserDefaults.standard.object(forKey: "hermit.diagnostics.lastSuccess") as? Date
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored nonisolated private let responses = DiagnosticUploadResponses()

    private override init() {
        super.init()
        configuration = try? DiagnosticReceiverCredentials.load()
        let settings = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        settings.sessionSendsLaunchEvents = true
        settings.isDiscretionary = false
        settings.waitsForConnectivity = true
        settings.timeoutIntervalForRequest = 60
        settings.timeoutIntervalForResource = 15 * 60
        settings.httpMaximumConnectionsPerHost = 1
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
    }

    func offer(_ url: URL) -> Bool {
        guard let configuration = DiagnosticReceiverConfiguration.from(url) else { return false }
        proposedConfiguration = configuration
        return true
    }

    func enable(_ value: DiagnosticReceiverConfiguration) async {
        do {
            try DiagnosticReceiverCredentials.save(value)
            for task in await session.allTasks { task.cancel() }
            configuration = value; isEnabled = true; isUploading = false; retryAt = .distantPast; failureCount = 0
            UserDefaults.standard.set(true, forKey: "hermit.diagnostics.enabled")
            await DiagnosticJournal.shared.append(DiagnosticRecord(kind: .lifecycle, code: "reporting-enabled"))
            startTimerIfNeeded()
            await flush(force: true)
        } catch { statusMessage = "无法保存设备上报凭据，请解锁设备后重试。" }
    }

    func disable() async {
        isEnabled = false; timer?.cancel(); timer = nil
        UserDefaults.standard.set(false, forKey: "hermit.diagnostics.enabled")
        for task in await session.allTasks { task.cancel() }
        isUploading = false
        statusMessage = "自动上报已关闭。本地仅保留有限的结构化诊断记录。"
    }

    func forget() async {
        await disable(); DiagnosticReceiverCredentials.delete(); configuration = nil
        try? await DiagnosticJournal.shared.clear(); pendingCount = 0
        lastSuccess = nil; UserDefaults.standard.removeObject(forKey: "hermit.diagnostics.lastSuccess")
        statusMessage = "本地诊断记录和接收端绑定已清除。"
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active {
            if configuration == nil { configuration = try? DiagnosticReceiverCredentials.load() }
            startTimerIfNeeded()
        } else { timer?.cancel(); timer = nil }
        Task {
            await DiagnosticJournal.shared.append(DiagnosticRecord(kind: .lifecycle, code: active ? "foreground" : "background"))
            await flush()
        }
    }

    private func startTimerIfNeeded() {
        guard foreground, isEnabled, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self else { return }
                await self.flush()
            }
        }
    }

    func flush(force: Bool = false) async {
        guard isEnabled, let configuration, !isUploading, !preparing, force || Date() >= retryAt else { return }
        preparing = true
        defer { preparing = false }
        do {
            // Reconcile system-owned tasks after a cold/background relaunch.
            let tasks = await session.allTasks
            if tasks.contains(where: { $0.state == .running || $0.state == .suspended }) { isUploading = true; return }
            let files = try await DiagnosticJournal.shared.pending()
            pendingCount = files.count
            guard let file = files.first else { return }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let today = Int(Date().timeIntervalSince1970 / 86400)
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "hermit.diagnostics.uploadDay") != today {
                defaults.set(today, forKey: "hermit.diagnostics.uploadDay"); defaults.set(0, forKey: "hermit.diagnostics.uploadBytes")
            }
            let used = defaults.integer(forKey: "hermit.diagnostics.uploadBytes")
            guard used + size <= 1024 * 1024 else { statusMessage = "已达到每日 1 MB 上报上限，之后自动补传。"; return }
            let uploadCopy = try await DiagnosticJournal.shared.stageUpload(file, configurationID: configuration.id)
            // No suspension after this check before handing the file to iOS.
            guard isEnabled, self.configuration?.id == configuration.id else {
                await DiagnosticJournal.shared.discardUpload(file.lastPathComponent, configurationID: configuration.id)
                return
            }
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
            let task = session.uploadTask(with: request, fromFile: uploadCopy)
            task.taskDescription = configuration.id.uuidString + ":" + file.lastPathComponent
            defaults.set(used + size, forKey: "hermit.diagnostics.uploadBytes")
            isUploading = true; statusMessage = "正在上报诊断记录…"
            task.resume()
        } catch { statusMessage = "暂时无法读取本地诊断，之后会自动重试。" }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) { backgroundCompletion = completion }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responses.append(data, task: dataTask.taskIdentifier)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responses.take(task.taskIdentifier)
        let description = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // Background sessions follow redirects without invoking the redirect
        // delegate. Our receiver never redirects: any changed final endpoint
        // must preserve the local batch, even if a response looks like an ACK.
        let succeeded = error == nil && DiagnosticUploadResponses.sameEndpoint(request: task.originalRequest?.url, response: task.response?.url)
        Task { @MainActor [weak self] in await self?.completed(description: description, status: status, data: data, succeeded: succeeded) }
    }
    private func completed(description: String?, status: Int, data: Data, succeeded: Bool) async {
        guard let description else { return }
        let components = description.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2, let configurationID = UUID(uuidString: components[0]),
              components[1].hasSuffix(".batch.json"),
              let batch = UUID(uuidString: String(components[1].dropLast(".batch.json".count))) else { return }
        await DiagnosticJournal.shared.discardUpload(components[1], configurationID: configurationID)
        guard let configuration, configurationID == configuration.id else { return }
        isUploading = false
        guard isEnabled else { return }
        if succeeded, DiagnosticUploadResponses.accepted(data, status: status, batchID: batch.uuidString) {
            let root = await DiagnosticJournal.shared.root
            try? await DiagnosticJournal.shared.acknowledge(root.appendingPathComponent(components[1]))
            lastSuccess = Date(); UserDefaults.standard.set(lastSuccess, forKey: "hermit.diagnostics.lastSuccess")
            statusMessage = "诊断记录已上报。"; failureCount = 0; retryAt = .distantPast
            pendingCount = max(0, pendingCount - 1)
            // Drain while foregrounded; do not build a chain of separate
            // background wakes that iOS progressively delays and throttles.
            if isEnabled, foreground { await flush() }
        } else {
            failureCount = min(failureCount + 1, 6)
            retryAt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(failureCount - 1))))
            statusMessage = [401, 403].contains(status)
                ? "设备上报凭据失效或接收端需要登录，请重新配置。"
                : "本次上报未确认，记录已保留，之后自动补传。"
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let completion = self?.backgroundCompletion; self?.backgroundCompletion = nil; completion?()
        }
    }
}
