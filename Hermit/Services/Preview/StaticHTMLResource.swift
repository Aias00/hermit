import Foundation

enum StaticHTMLResource {
    static let documentLimit = 512 * 1024
    static let resourceLimit = 2 * 1024 * 1024
    static let totalLimit = 10 * 1024 * 1024
    static let mimeTypes = ["html": "text/html", "htm": "text/html", "css": "text/css",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf"]
    static let csp = "sandbox; default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; style-src 'unsafe-inline' hermit-report:; img-src hermit-report: data:; font-src hermit-report: data:; base-uri 'none'; form-action 'none'"
    static func isHTML(_ path: String) -> Bool { ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) }
    static func relativePath(_ url: URL, host: String) throws -> String {
        guard url.scheme == "hermit-report", url.host == host, url.user == nil, url.password == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decoded = encoded.removingPercentEncoding else { throw WorkspaceReviewError.invalidPath }
        let path = String(decoded.drop(while: { $0 == "/" }))
        guard WorkspaceGit.safeRelativePath(path), !path.contains("\\") else { throw WorkspaceReviewError.invalidPath }
        return path
    }
    static func command(root: String, relativePath: String, limit: Int) -> String {
        let q = WorkspaceInspection.quote
        let directory = (relativePath as NSString).deletingLastPathComponent
        let name = (relativePath as NSString).lastPathComponent
        // Resolve every parent physically and reject final symlinks. No asset
        // may reach outside the selected report directory through ../ or links.
        return "root=$(CDPATH= cd -P \(q(root)) && pwd -P) || exit 1; "
            + "parent=$(CDPATH= cd -P \"$root\"/\(q(directory.isEmpty ? "." : directory)) && pwd -P) || exit 1; "
            + "case \"$parent/\" in \"$root/\"*) ;; *) exit 1 ;; esac; "
            + "file=\"$parent\"/\(q(name)); [ ! -L \"$file\" ] && [ -f \"$file\" ] && [ -r \"$file\" ] || exit 1; "
            + "printf 'HERMIT_FILE\\n'; head -c \(limit + 1) \"$file\" && printf '\\nHERMIT_END'"
    }
    static func decode(_ data: Data, limit: Int, allowTruncation: Bool = false) throws -> Data {
        let start = Data("HERMIT_FILE\n".utf8), end = Data("\nHERMIT_END".utf8)
        guard data.starts(with: start), data.suffix(end.count) == end,
              data.count >= start.count + end.count else { throw WorkspaceReviewError.unavailable }
        let body = Data(data.dropFirst(start.count).dropLast(end.count))
        guard body.count <= limit || (allowTruncation && body.count == limit + 1) else { throw WorkspaceReviewError.tooLarge }
        return body
    }
}

/// Serial resource reads bound SSH load and the complete report's byte budget.
actor StaticHTMLResources {
    let root: String
    let document: String
    let run: WorkspaceInspection.Run
    private var tail: Task<Data, Error>?
    private var count = 0
    private var bytes = 0
    init(path: String, run: @escaping WorkspaceInspection.Run) {
        root = (path as NSString).deletingLastPathComponent
        document = (path as NSString).lastPathComponent
        self.run = run
    }
    func read(_ path: String) async throws -> Data {
        guard count < 64, WorkspaceGit.safeRelativePath(path) else { throw WorkspaceReviewError.tooLarge }
        count += 1
        let previous = tail
        let task = Task { [self] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await perform(path)
        }
        tail = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func perform(_ path: String) async throws -> Data {
        let limit = min(path == document ? StaticHTMLResource.documentLimit : StaticHTMLResource.resourceLimit,
                        StaticHTMLResource.totalLimit - bytes)
        guard limit > 0 else { throw WorkspaceReviewError.tooLarge }
        let output = try await run(StaticHTMLResource.command(root: root, relativePath: path, limit: limit))
        try Task.checkCancellation()
        let body = try StaticHTMLResource.decode(output, limit: limit)
        bytes += body.count
        return body
    }
}
