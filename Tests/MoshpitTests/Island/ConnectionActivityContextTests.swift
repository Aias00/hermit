import Foundation
import MoshpitKit
import Testing
@testable import Moshpit

@Suite("Connection activity pane context")
struct ConnectionActivityContextTests {
    private func snapshot(command: String = "zsh") -> TmuxSnapshot {
        var value = TmuxSnapshot()
        value.sessions["$1"] = SessionInfo(id: "$1", name: "project")
        value.windows["@1"] = WindowInfo(id: "@1", sessionId: "$1", name: "private window title", index: 3)
        value.panes["%1"] = PaneInfo(id: "%1", windowId: "@1", command: command, isActive: true)
        value.activeSessionId = "$1"
        value.activeWindowId = "@1"
        value.activePaneId = "%1"
        value.isAttached = true
        return value
    }

    @Test("native herdr agent identity survives terminal titles and selects a blocked pane")
    func herdrNativeHooks() throws {
        let raw = """
        {"workspaces":[{"workspace_id":"w1","label":"mobile"}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"private tab title","number":2}],
         "panes":[
           {"pane_id":"w1:p1","tab_id":"w1:t1","focused":true,"agent_status":"idle"},
           {"pane_id":"w1:p2","tab_id":"w1:t1","agent_status":"working",
            "terminal_title_stripped":"private task --token secret"}],
         "agents":[{"pane_id":"w1:p2","display_agent":"Codex","agent_status":"blocked"}],
         "focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1"}
        """
        let decoded = try #require(HerdrSnapshot.decode(raw))
        let result = ConnectionActivityContext.make(snapshot: decoded.snapshot,
            hooks: decoded.agentHooks, hooksLoaded: true)
        #expect(result == ConnectionActivityContext(workspaceName: "mobile", windowIndex: 2,
            programName: "Codex", taskState: "attention", paneID: "w1:p2"))
    }

    @Test("tmux context uses the selected pane's own workspace and window")
    func tmuxAttentionLocation() {
        var value = snapshot()
        value.sessions["$2"] = SessionInfo(id: "$2", name: "backend")
        value.windows["@2"] = WindowInfo(id: "@2", sessionId: "$2", index: 7)
        value.panes["%2"] = PaneInfo(id: "%2", windowId: "@2", command: "node")
        let result = ConnectionActivityContext.make(snapshot: value,
            hooks: ["%2": AgentHook(state: "attention", agent: "claude", command: "node")],
            hooksLoaded: true)
        #expect(result == ConnectionActivityContext(workspaceName: "backend", windowIndex: 7,
            programName: "Claude Code", taskState: "attention", paneID: "%2"))
    }

    @Test("an ordinary pane without hooks can show a program without inventing a task")
    func ordinaryPane() {
        let result = ConnectionActivityContext.make(snapshot: snapshot(command: "/usr/bin/vim"),
            hooks: [:], hooksLoaded: true)
        #expect(result.programName == "Vim")
        #expect(result.taskState == nil)
        #expect(result.workspaceName == "project")
        #expect(result.windowIndex == 3 && result.paneID == "%1")
    }

    @Test("plain SSH with no multiplexer supplies no invented remote context")
    func plainSSH() {
        let result = ConnectionActivityContext.make(snapshot: TmuxSnapshot(), hooks: [:], hooksLoaded: false)
        #expect(result == ConnectionActivityContext())
    }

    @Test("private titles, full command lines and version-like names never become program labels",
          arguments: ["codex --token secret", "claude --password secret", "secret-claude-project",
                      "2.1.269", "/private/account/token", "\u{1B}[31mcodex"])
    func privateTextIsNotAProgram(command: String) {
        let result = ConnectionActivityContext.make(snapshot: snapshot(command: command),
            hooks: ["%1": AgentHook(agent: command, command: command,
                                    title: "Codex: private task --token secret")], hooksLoaded: true)
        #expect(result.programName == nil)
        #expect(result.taskState == nil)
    }

    @Test("a fresh shell suppresses the old agent identity and every old task phase",
          arguments: ["working", "attention", "done"])
    func returnedShell(state: String) {
        let result = ConnectionActivityContext.make(snapshot: snapshot(command: "codex"),
            hooks: ["%1": AgentHook(state: state, agent: "codex", command: "/bin/zsh")],
            hooksLoaded: true)
        #expect(result.programName == "Shell")
        #expect(result.taskState == nil)
    }

    @Test("stale shell, self-test and removed panes cannot steal focus")
    func ignoresInvalidAttention() {
        var value = snapshot(command: "nvim")
        value.panes["%2"] = PaneInfo(id: "%2", windowId: "@1", command: "codex")
        value.panes["%3"] = PaneInfo(id: "%3", windowId: "@1", command: "zsh")
        let hooks: [String: AgentHook] = [
            "%0": .init(state: "attention", agent: "codex"), // Removed pane.
            "%2": .init(state: "attention", agent: "codex", command: "-zsh"),
            "%3": .init(state: "attention", agent: PushRemoteNotification.selfTestAgent),
        ]
        let result = ConnectionActivityContext.make(snapshot: value, hooks: hooks, hooksLoaded: true)
        #expect(result.paneID == "%1")
        #expect(result.programName == "Neovim")
        #expect(result.taskState == nil)
    }

    @Test("unloaded hooks cannot report a task or override the active pane")
    func hooksNotLoaded() {
        var value = snapshot(command: "fish")
        value.panes["%2"] = PaneInfo(id: "%2", windowId: "@1", command: "codex")
        let result = ConnectionActivityContext.make(snapshot: value,
            hooks: ["%2": AgentHook(state: "attention", agent: "codex")], hooksLoaded: false)
        #expect(result.paneID == "%1")
        #expect(result.programName == "Shell")
        #expect(result.taskState == nil)
    }

    @Test("idle and unknown remain unknown rather than reporting completion",
          arguments: ["idle", "unknown", "failed", ""])
    func unknownStates(state: String) {
        let result = ConnectionActivityContext.make(snapshot: snapshot(command: "codex"),
            hooks: ["%1": AgentHook(state: state, agent: "codex")], hooksLoaded: true)
        #expect(result.programName == "Codex")
        #expect(result.taskState == nil)
    }

    @Test("only explicit working attention and done stamps are reported",
          arguments: ["working", "attention", "done"])
    func explicitStates(state: String) {
        let result = ConnectionActivityContext.make(snapshot: snapshot(command: "node"),
            hooks: ["%1": AgentHook(state: state, agent: "gemini", command: "node")],
            hooksLoaded: true)
        #expect(result.programName == "Gemini")
        #expect(result.taskState == state)
    }

    @Test("a missing active ID can fall back only to a focused pane in the active window")
    func focusedPaneFallback() {
        var value = snapshot(command: "opencode")
        value.activePaneId = "%gone"
        let result = ConnectionActivityContext.make(snapshot: value, hooks: [:], hooksLoaded: true)
        #expect(result.paneID == "%1")
        #expect(result.programName == "OpenCode")

        value.activeWindowId = "@gone"
        let missing = ConnectionActivityContext.make(snapshot: value, hooks: [:], hooksLoaded: true)
        #expect(missing == ConnectionActivityContext())
    }
}
