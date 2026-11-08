import Foundation

enum WorkspaceReviewError: LocalizedError {
    case unavailable, invalidPath, tooLarge, changedWorkspace
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取工作区，请确认连接正常、目录存在且已安装 Git。"
        case .invalidPath: return "预览仅允许读取当前报告目录内的普通文件。"
        case .tooLarge: return "内容超过预览限制，请下载文件查看。"
        case .changedWorkspace: return "工作区位置已变化。已有批注已保留，请先导出批注再重新打开审阅。"
        }
    }
}

/// Read-only execs use their own cancellable SSH channel, never terminal stdin.
enum WorkspaceInspection {
    typealias Run = @Sendable (String) async throws -> Data
    static func runner(_ files: RemoteFileAccess) -> Run {
        { command in
            let session = try await files.channel()
            return try await session.inspectWorkspace(command)
        }
    }
    static func quote(_ value: String) -> String { ExecUploadCommands.quote(value) }

    /// Drain the producer after the bounded prefix so pipefail preserves real
    /// Git failures without treating a large diff's SIGPIPE as a broken host.
    static func bounded(_ command: String, bytes: Int) -> String {
        "bash -c " + quote("set -o pipefail; { \(command); } | { head -c \(bytes + 1); cat >/dev/null; }")
    }
}

struct WorkspaceGitChange: Identifiable, Equatable {
    let status: String
    let path: String
    let originalPath: String?
    var id: String { path }
    var untracked: Bool { status == "??" }
}

struct WorkspaceGitSnapshot: Equatable {
    let root: String
    let changes: [WorkspaceGitChange]
}

enum WorkspaceGit {
    static let statusLimit = 256 * 1024
    static let diffLimit = 256 * 1024
    static func statusCommand(directory: String) -> String {
        let script = "root=$(git -C \(WorkspaceInspection.quote(directory)) rev-parse --show-toplevel) || exit 1; "
            + "printf '%s\\0' \"$root\"; GIT_OPTIONAL_LOCKS=0 git -C \"$root\" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all"
        return WorkspaceInspection.bounded(script, bytes: statusLimit)
    }
    static func parseStatus(_ data: Data) throws -> WorkspaceGitSnapshot {
        guard data.count <= statusLimit else { throw WorkspaceReviewError.tooLarge }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard let first = fields.first, let root = String(data: first, encoding: .utf8), root.hasPrefix("/"),
              data.last == 0 else { throw WorkspaceReviewError.unavailable }
        var changes: [WorkspaceGitChange] = [], i = 1
        while i < fields.count - 1 {
            let field = fields[i]
            guard field.count >= 4, field[field.startIndex + 2] == 32,
                  let value = String(data: field, encoding: .utf8) else { throw WorkspaceReviewError.unavailable }
            let status = String(value.prefix(2)), path = String(value.dropFirst(3))
            guard safeRelativePath(path) else { throw WorkspaceReviewError.invalidPath }
            var original: String?
            if status.contains("R") || status.contains("C") {
                i += 1
                guard i < fields.count - 1, let old = String(data: fields[i], encoding: .utf8), safeRelativePath(old)
                else { throw WorkspaceReviewError.unavailable }
                original = old
            }
            changes.append(WorkspaceGitChange(status: status, path: path, originalPath: original))
            i += 1
        }
        return WorkspaceGitSnapshot(root: root, changes: changes)
    }
    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains("..")
    }
    static func diffCommand(root: String, change: WorkspaceGitChange) -> String {
        let q = WorkspaceInspection.quote
        if change.untracked {
            return StaticHTMLResource.command(root: root, relativePath: change.path, limit: diffLimit)
        }
        let paths = ([change.originalPath].compactMap { $0 } + [change.path]).map(q).joined(separator: " ")
        let git = "GIT_OPTIONAL_LOCKS=0 git -C \(q(root)) -c core.fsmonitor=false --no-pager diff --no-ext-diff --no-textconv --no-color"
        return WorkspaceInspection.bounded("printf '%s\\n' '--- 暂存区 ---'; \(git) --cached -- \(paths) && printf '%s\\n' '--- 工作区 ---' && \(git) -- \(paths)", bytes: diffLimit)
    }
    static func diff(_ data: Data, change: WorkspaceGitChange) throws -> (text: String, truncated: Bool) {
        let bytes = change.untracked ? try StaticHTMLResource.decode(data, limit: diffLimit, allowTruncation: true) : data
        if bytes.contains(0) { return ("二进制文件，请在文件浏览器中预览或下载。", false) }
        return (String(decoding: bytes.prefix(diffLimit), as: UTF8.self), bytes.count > diffLimit)
    }
}

struct WorkspaceReviewNote: Identifiable, Equatable {
    let id: UUID
    let path: String
    let line: Int?
    let side: String
    var comment: String
    init(path: String, line: Int?, side: String = "文件", comment: String) {
        id = UUID(); self.path = path; self.line = line; self.side = side; self.comment = comment
    }
    var anchor: String { path + (line.map { ":\($0)（\(side)）" } ?? "") }
    static func draft(root: String, notes: [Self]) -> String {
        "请检查以下审阅意见（工作区：\(root)）：\n\n" + notes.enumerated().map {
            "\($0.offset + 1). \($0.element.anchor)\n\($0.element.comment)"
        }.joined(separator: "\n\n")
    }
}

struct WorkspaceDiffLine: Identifiable {
    let id: Int
    let text: String
    let line: Int?
    let side: String
    static func parse(_ source: String, untracked: Bool = false) -> [Self] {
        var old = 0, new = 0, inHunk = untracked, section = ""
        return source.components(separatedBy: "\n").enumerated().map { index, text in
            if untracked { return Self(id: index, text: text, line: index + 1, side: "新文件") }
            var number: Int?, side = "新文件"
            if text.hasPrefix("@@ "), let range = text.range(of: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#, options: .regularExpression) {
                let header = String(text[range])
                let parts = header.components(separatedBy: " ")
                old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                inHunk = true
            } else if text.hasPrefix("diff --git") || text == "--- 暂存区 ---" || text == "--- 工作区 ---" {
                inHunk = false
                if text == "--- 暂存区 ---" { section = "暂存区·" }
                if text == "--- 工作区 ---" { section = "工作区·" }
            } else if inHunk {
                if !untracked && text.hasPrefix("-") { number = old; old += 1; side = "旧文件" }
                else if untracked || text.hasPrefix("+") || text.hasPrefix(" ") {
                    if !untracked && text.hasPrefix(" ") { old += 1 }
                    if untracked && new == 0 { new = 1 }
                    number = new; new += 1
                }
            }
            return Self(id: index, text: text, line: number, side: section + side)
        }
    }
}
