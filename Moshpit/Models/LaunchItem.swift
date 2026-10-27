import Foundation

struct LaunchItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var hostID: UUID?
    var command: String
    var directory: String = ""
    var isProject = false

    var shellCommand: String {
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let prefix = directory.isEmpty ? "" : "cd -- \(quoted) && "
        return command.isEmpty ? (directory.isEmpty ? "" : "cd -- \(quoted)") : prefix + command
    }
    static let defaults = [
        LaunchItem(name: "打开 Claude", command: "claude"),
        LaunchItem(name: "打开 Codex", command: "codex"),
        LaunchItem(name: "打开 OpenCode", command: "opencode"),
        LaunchItem(name: "运行脚本", command: "date")
    ]
}
