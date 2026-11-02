import Foundation
import Observation

/// In-memory upload history belongs to a connection's draft, not its screen.
/// Security-scoped access stays alive through retry and ends when history clears.
@Observable @MainActor
final class FileUploadQueue {
    enum State: Equatable {
        case queued, uploading(Double), uploaded(String), failed(String), cancelled

        var canRetry: Bool {
            switch self { case .failed, .cancelled: return true; default: return false }
        }
    }

    final class Source: @unchecked Sendable {
        let url: URL
        private let scoped: Bool
        init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
        deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    struct Item: Identifiable {
        let id = UUID()
        let source: Source
        let remoteName: String
        var state: State = .queued
        var name: String { source.url.lastPathComponent }
    }

    typealias Upload = @Sendable (URL, String, @escaping @Sendable (Double) -> Void) async throws -> String
    private(set) var items: [Item] = []
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var completedCount: Int { items.filter { if case .uploaded = $0.state { return true }; return false }.count }
    var hasRetryableItems: Bool { items.contains { $0.state.canRetry } }

    func enqueue(_ urls: [URL]) {
        items += urls.map { Item(source: Source($0), remoteName: UUID().uuidString + "-" + $0.lastPathComponent) }
    }

    func start(retry: Bool = false, upload: @escaping Upload,
               publish: @escaping @MainActor (String) -> Void) {
        guard !isRunning else { return }
        if retry {
            for index in items.indices where items[index].state.canRetry { items[index].state = .queued }
        }
        guard items.contains(where: { $0.state == .queued }) else { return }
        generation = UUID()
        let run = generation
        isRunning = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == run { isRunning = false; task = nil }
            }
            for index in items.indices {
                guard generation == run, !Task.isCancelled else { return }
                guard items[index].state == .queued else { continue }
                let item = items[index]
                items[index].state = .uploading(0)
                do {
                    let path = try await CancellableTransfer.run {
                        try await upload(item.source.url, item.remoteName) { [weak self] value in
                            Task { @MainActor [weak self] in
                                guard let self, generation == run, isRunning,
                                      items.indices.contains(index), items[index].id == item.id,
                                      case .uploading(let previous) = items[index].state, value.isFinite else { return }
                                items[index].state = .uploading(max(previous, min(1, max(0, value))))
                            }
                        }
                    }
                    guard generation == run, !Task.isCancelled else { return }
                    items[index].state = .uploaded(path)
                    publish(path)
                } catch {
                    guard generation == run, !Task.isCancelled else { return }
                    items[index].state = .failed(error.localizedDescription)
                    // A bad file must not prevent the rest of the batch uploading.
                }
            }
        }
    }

    func cancel() {
        generation = UUID() // reject late completion/progress before cancelling awaits
        task?.cancel()
        task = nil
        isRunning = false
        for index in items.indices {
            switch items[index].state {
            case .queued, .uploading: items[index].state = .cancelled
            default: break
            }
        }
    }

    func clear() {
        guard !isRunning else { return }
        generation = UUID()
        items.removeAll()
    }

    static func readFile(_ url: URL) async throws -> Data {
        try await Task.detached {
            try Task.checkCancellation()
            let limit = 20 * 1024 * 1024
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw FileError.notRegular
            }
            guard let size = values.fileSize, size <= limit else { throw FileError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= limit else { throw FileError.tooLarge }
            return data
        }.value
    }

    private enum FileError: LocalizedError {
        case notRegular, tooLarge
        var errorDescription: String? {
            switch self {
            case .notRegular: return String(localized: "Select a regular file. Compress folders first.")
            case .tooLarge: return String(localized: "Each file must be 20 MB or smaller.")
            }
        }
    }
}


/// One dedicated transfer connection per batch; no per-file health-probe RTT.
/// A retry gets a fresh batch so a failed/cancelled SSH channel is not reused.
actor FileUploadBatch {
    private let acquire: @Sendable () async throws -> SSHSession
    private var session: SSHSession?

    init(acquire: @escaping @Sendable () async throws -> SSHSession) { self.acquire = acquire }

    func upload(_ url: URL, named name: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let data = try await FileUploadQueue.readFile(url)
        try Task.checkCancellation()
        let ssh: SSHSession
        if let session { ssh = session }
        else { ssh = try await acquire(); session = ssh }
        try Task.checkCancellation()
        return try await ssh.uploadToUploadsDirectory(data, named: name, progress: progress)
    }
}
