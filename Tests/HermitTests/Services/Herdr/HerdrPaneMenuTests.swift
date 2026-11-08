import Testing
import SwiftTerm
import UIKit
@testable import Moshpit

@Suite("HERDR contextual pane actions", .serialized) @MainActor
struct HerdrPaneMenuTests {
    static let snapshot = """
    {"result":{"snapshot":{
      "workspaces":[{"workspace_id":"w1","label":"Project","focused":true},{"workspace_id":"w2","label":"Other"}],
      "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Agent","number":1,"focused":true,"pane_count":2}],
      "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"terminal-1"},
      {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"terminal-2","focused":true}],
      "layouts":[],"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p2"}}}
    """
    @Test("terminal double tap keeps the built-in selection recognizer; only a secondary pointer opens actions")
    func gestureRoutesWithoutTypingOrSelecting() throws {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = SwiftTerminalView.Coordinator()
        TerminalScrollGesture.attach(to: terminal, coordinator: coordinator)
        var input: [Data] = []
        coordinator.onInput = { input.append($0) }
        coordinator.onContextMenu = { _, _ in true }
        let doubles = terminal.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.filter { $0.numberOfTapsRequired == 2 }
        #expect(doubles?.count == 1)
        #expect(input.isEmpty && !terminal.isFirstResponder)
        let pointer = try #require(terminal.gestureRecognizers?.first { $0.name == "terminal-secondary-menu" })
        #expect((pointer as? UITapGestureRecognizer)?.buttonMaskRequired == .secondary)
        coordinator.onContextMenu = nil
        #expect(pointer.delegate?.gestureRecognizerShouldBegin?(pointer) == false)
    }

    @Test("a nonselected empty workspace has its own actions without selecting a pane")
    func emptyWorkspaceAndScope() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        defer { control.stop() }
        await control.pollNowForTesting()
        let before = runner.commands.count
        let workspace = try #require(control.paneMenuTarget(for: .workspace("w2")))
        #expect(workspace.paneID == nil && workspace.tabID == nil && workspace.workspaceID == "w2")
        #expect(!workspace.canSplit && workspace.closeAction == .closeWorkspace)
        #expect(runner.commands.count == before && control.snapshot.activeSessionId == "w1")
        #expect(HerdrPaneMenuAction.newTab.command(target: workspace) == "tab create --workspace 'w2' --focus")
        #expect(HerdrPaneMenuAction.closeWorkspace.command(target: workspace) == "workspace close 'w2'")
        #expect(HerdrPaneMenuAction.closePane.command(target: workspace) == nil)
        #expect(HerdrPaneMenuAction.splitRight.command(target: workspace) == nil)
        runner.setResponse("__moshpit_rc=0")
        try await control.performPaneMenuAction(.renameWorkspace("renamed"), target: workspace)
        #expect(runner.commands.contains { $0.contains("workspace rename 'w2' 'renamed'") })
    }

    @Test("list panes and tabs capture the requested row, never the active pane")
    func explicitListRowTargets() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        defer { control.stop() }
        await control.pollNowForTesting()
        let pane = try #require(control.paneMenuTarget(for: .pane("w1:p1")))
        let tab = try #require(control.paneMenuTarget(for: .tab("w1:t1")))
        #expect(pane.paneID == "w1:p1" && control.snapshot.activePaneId == "w1:p2")
        #expect(HerdrPaneMenuAction.closePane.command(target: pane) == "pane close 'w1:p1'")
        #expect(tab.closeAction == .closeTab && HerdrPaneMenuAction.closeTab.command(target: tab) == "tab close 'w1:t1'")
        #expect(HerdrPaneMenuAction.closeWorkspace.command(target: tab) == nil)
        #expect(control.paneMenuTarget(for: .workspace("missing")) == nil)
    }

    @Test("a restarted server cannot reuse an old workspace menu even if its IDs return")
    func workspaceMenuExpiresAcrossServerRestart() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        defer { control.stop() }
        await control.pollNowForTesting()
        let target = try #require(control.paneMenuTarget(for: .workspace("w2")))
        runner.setResponse("{\"error\":{\"code\":\"server_not_running\"}}")
        await control.pollNowForTesting()
        runner.setResponse(Self.snapshot)
        await control.pollNowForTesting()
        #expect(!control.isValidPaneMenuTarget(target))
        let before = runner.commands.count
        await #expect(throws: HerdrPaneMenuError.self) { try await control.performPaneMenuAction(.closeWorkspace, target: target) }
        #expect(runner.commands.count == before)
    }

    @Test("new tabs and splits address the captured workspace and pane after focus changes")
    func actionsStayOnOriginalTarget() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        defer { control.stop() }
        await control.pollNowForTesting()
        let target = try #require(control.paneMenuTarget())
        #expect(target.paneID == "w1:p2" && target.terminalID == "terminal-2")
        runner.setResponse(Self.snapshot.replacingOccurrences(of: "\"focused_pane_id\":\"w1:p2\"", with: "\"focused_pane_id\":\"w1:p1\""))
        await control.pollNowForTesting()
        runner.setScript { command in
            command.contains("api snapshot") ? .reply(Self.snapshot) : .reply("__moshpit_rc=0")
        }
        try await control.performPaneMenuAction(.newTab, target: target)
        try await control.performPaneMenuAction(.splitRight, target: target)
        try await control.performPaneMenuAction(.splitDown, target: target)
        try await control.performPaneMenuAction(.renameTab("Agent 'quoted'"), target: target)
        let commands = runner.commands
        #expect(commands.contains { $0.contains("tab create --workspace 'w1' --focus") })
        #expect(commands.contains { $0.contains("pane split 'w1:p2' --direction right") })
        #expect(commands.contains { $0.contains("pane split 'w1:p2' --direction down") })
        #expect(commands.contains { $0.contains("tab rename 'w1:t1' 'Agent '\\''quoted'\\'''" ) })
    }

    @Test("retired controllers and replaced terminals reject before writing")
    func rejectsStaleTargets() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        await control.pollNowForTesting()
        let target = try #require(control.paneMenuTarget())
        runner.setResponse(Self.snapshot.replacingOccurrences(of: "terminal-2", with: "replacement-terminal"))
        await control.pollNowForTesting()
        let count = runner.commands.count
        await #expect(throws: HerdrPaneMenuError.self) { try await control.performPaneMenuAction(.closePane, target: target) }
        #expect(runner.commands.count == count)
        control.stop()
        await #expect(throws: HerdrPaneMenuError.self) { try await control.performPaneMenuAction(.newTab, target: target) }
        #expect(runner.commands.count == count)
    }

    @Test("missing acknowledgements do not succeed or replay commands")
    func unconfirmedActionsNeverRetry() async throws {
        let runner = HerdrControlClientTests.FakeRunner(response: Self.snapshot)
        let control = HerdrControlClient(runner: runner)
        defer { control.stop() }
        await control.pollNowForTesting()
        let target = try #require(control.paneMenuTarget())
        let before = runner.commands.count
        runner.setResponse("no exit trailer")
        await #expect(throws: HerdrPaneMenuError.self) { try await control.performPaneMenuAction(.splitDown, target: target) }
        #expect(runner.commands.count == before + 1)
        let count = runner.commands.count
        await #expect(throws: HerdrPaneMenuError.self) { try await control.performPaneMenuAction(.renameTab("\n"), target: target) }
        #expect(runner.commands.count == count)
    }

    @Test("anchored phone popovers preserve the draft responder and never submit input")
    func popoverPreservesFocus() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 450))
        let draft = UITextField(frame: CGRect(x: 0, y: 460, width: 300, height: 40))
        parent.view.addSubview(source); parent.view.addSubview(draft)
        draft.text = "keep this draft"; draft.becomeFirstResponder()
        let presenter = TerminalPaneMenuPresenter()
        defer { presenter.dismiss(); window.isHidden = true }
        let target = HerdrPaneMenuTarget(generation: UUID(), paneID: "w1:p1", tabID: "w1:t1", workspaceID: "w1",
            terminalID: "terminal", workspaceName: "Project", tabName: "Agent", paneIndex: 0)
        var actions = 0
        #expect(presenter.present(from: source, at: CGPoint(x: 385, y: 100), target: target, workspaces: []) { _ in actions += 1 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(parent.presentedViewController?.modalPresentationStyle == .popover)
        #expect(draft.isFirstResponder && draft.text == "keep this draft")
        #expect(actions == 0)
        presenter.dismiss()
        try await Task.sleep(for: .milliseconds(400))
        #expect(draft.isFirstResponder && actions == 0)
    }
}
