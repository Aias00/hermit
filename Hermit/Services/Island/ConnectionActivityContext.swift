import Foundation
import MoshpitKit

/// A small, deliberately limited view of the selected remote pane. Task state
/// comes only from explicit stamps; terminal titles and command arguments are
/// never copied into the activity. The caller controls workspace-name privacy.
struct ConnectionActivityContext: Equatable, Sendable {
    var workspaceName: String?
    var windowIndex: Int?
    var programName: String?
    var taskState: String?
    var paneID: String?

    static func make(snapshot: TmuxSnapshot, hooks: [String: AgentHook],
                     hooksLoaded: Bool) -> Self {
        let knownHooks = hooksLoaded ? hooks : [:]
        let attentionPane = knownHooks.keys.sorted().first { paneID in
            snapshot.panes[paneID] != nil
                && reportedState(knownHooks[paneID]) == "attention"
        }
        let activePane = snapshot.activePaneId.flatMap { snapshot.panes[$0] }
            ?? snapshot.activePanes.first(where: \.isActive)
        guard let paneID = attentionPane ?? activePane?.id,
              let pane = snapshot.panes[paneID] else {
            return Self()
        }

        let hook = knownHooks[paneID]
        let window = snapshot.windows[pane.windowId]
        let workspace = window.flatMap { snapshot.sessions[$0.sessionId]?.name }
        let program: String?
        if let command = hook?.command, invalidatesAgent(command) {
            // Fresh shell/process information wins over an old agent stamp and
            // an older discovery snapshot, including when that stamp says done.
            program = displayProgram(command)
        } else if hook?.agent == PushRemoteNotification.selfTestAgent {
            program = displayProgram(hook?.command) ?? displayProgram(pane.command)
        } else {
            program = displayProgram(hook?.agent)
                ?? displayProgram(hook?.command)
                ?? displayProgram(pane.command)
        }
        return Self(workspaceName: workspace.flatMap { $0.isEmpty ? nil : $0 },
                    windowIndex: window?.index,
                    programName: program,
                    taskState: reportedState(hook),
                    paneID: paneID)
    }

    static func reportedState(_ hook: AgentHook?) -> String? {
        guard let hook, hook.agent != PushRemoteNotification.selfTestAgent,
              !(hook.command.map(invalidatesAgent) ?? false) else { return nil }
        switch hook.state {
        case "working", "attention", "done": return hook.state
        default: return nil
        }
    }

    private static func invalidatesAgent(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let name = programKey(trimmed) else { return false }
        return shells.contains(name) || name == "login" || name == "tmux"
    }

    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "ash", "csh", "tcsh",
        "pwsh", "powershell", "nu",
    ]

    private static func displayProgram(_ raw: String?) -> String? {
        guard let raw, let key = programKey(raw) else { return nil }
        if shells.contains(key) || key == "login" { return "Shell" }
        switch key {
        case "codex", "codex cli": return "Codex"
        case "claude", "claude code": return "Claude Code"
        case "gemini", "gemini cli": return "Gemini"
        case "opencode", "open code": return "OpenCode"
        case "vim": return "Vim"
        case "nvim", "neovim": return "Neovim"
        case "nano": return "Nano"
        case "emacs": return "Emacs"
        case "less": return "less"
        case "top": return "top"
        case "htop": return "htop"
        case "tmux": return "tmux"
        case "screen": return "screen"
        default: return nil
        }
    }

    /// Accept a known display name or a single executable path, never a shell
    /// command line. Returning only keys from displayProgram's fixed mapping
    /// prevents an arbitrary title, path or argument from entering the payload.
    private static func programKey(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["codex cli", "claude code", "gemini cli", "open code"].contains(value) {
            return value
        }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              let basename = value.split(separator: "/", omittingEmptySubsequences: false).last,
              !basename.isEmpty else { return nil }
        // Login shells expose a leading dash in their process name.
        return basename.hasPrefix("-") ? String(basename.dropFirst()) : String(basename)
    }
}
