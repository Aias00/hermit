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
    @Test("opening and cancelling send no command; normal SSH leaves double-tap selection intact")
    func gestureRoutesWithoutTypingOrSelecting() throws {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = SwiftTerminalView.Coordinator()
        TerminalScrollGesture.attach(to: terminal, coordinator: coordinator)
        let point = CGPoint(x: 120, y: 150)
        #expect(terminal.onDoubleTap?(point) == false)
        var requests: [CGPoint] = []
        var input: [Data] = []
        coordinator.onInput = { input.append($0) }
        coordinator.onContextMenu = { _, p in requests.append(p); return true }
        #expect(terminal.onDoubleTap?(point) == true)
        #expect(requests == [point] && input.isEmpty && !terminal.isFirstResponder)
        let pointer = try #require(terminal.gestureRecognizers?.first { $0.name == "terminal-secondary-menu" })
        #expect((pointer as? UITapGestureRecognizer)?.buttonMaskRequired == .secondary)
        coordinator.onContextMenu = nil
        #expect(terminal.onDoubleTap?(point) == false)
        #expect(pointer.delegate?.gestureRecognizerShouldBegin?(pointer) == false)
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
