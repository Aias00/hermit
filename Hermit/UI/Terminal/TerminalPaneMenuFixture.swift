#if DEBUG
import SwiftUI
import SwiftTerm
import UIKit

/// Simulator-only gesture rig. It never connects to a host or executes actions.
struct TerminalPaneMenuFixture: UIViewControllerRepresentable {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-HERMIT_PANE_MENU_FIXTURE")
        #else
        false
        #endif
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) { }

    @MainActor final class Controller: UIViewController {
        let terminal = TerminalView(frame: .zero)
        let draft = UITextField()
        let result = UILabel()
        let coordinator = SwiftTerminalView.Coordinator()
        let menu = TerminalPaneMenuPresenter()
        var selections = 0
        static let snapshot = """
        {"result":{"snapshot":{
          "workspaces":[{"workspace_id":"w1","label":"Project","focused":true},{"workspace_id":"w2","label":"Empty workspace"}],
          "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Agent","number":1,"focused":true,"pane_count":2},
                  {"tab_id":"w1:t2","workspace_id":"w1","label":"Other tab","number":2,"pane_count":1}],
          "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"terminal-1"},
                   {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"terminal-2","focused":true},
                   {"pane_id":"w1:p3","tab_id":"w1:t2","workspace_id":"w1","terminal_id":"terminal-3"}],
          "layouts":[],"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p2"}}}
        """
        final class Runner: HerdrCommandRunner, @unchecked Sendable {
            func run(_ command: String) async throws -> String { Controller.snapshot }
        }
        let control = HerdrControlClient(runner: Runner())
        override func viewDidLoad() {
            super.viewDidLoad()
            // Accessibility automation otherwise waits on the fixture's caret
            // animation before every action. Production animations are intact.
            UIView.setAnimationsEnabled(false)
            view.backgroundColor = .systemBackground
            draft.borderStyle = .roundedRect
            draft.accessibilityIdentifier = "pane-menu-fixture-draft"
            draft.text = "keep draft"
            draft.autocorrectionType = .no
            terminal.accessibilityIdentifier = "pane-menu-fixture-terminal"
            terminal.focusOnTap = false
            terminal.allowMouseReporting = false
            terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            terminal.getTerminal().setCursorStyle(.steadyBlock)
            terminal.feed(text: "\u{1b}[2J\u{1b}[HHERDR terminal\r\nDouble tap selects words\r\nList opens actions\r\n")
            result.accessibilityIdentifier = "pane-menu-fixture-result"
            result.text = "No actions executed"
            coordinator.attach(to: terminal)
            if !ProcessInfo.processInfo.arguments.contains("-HERMIT_PANE_MENU_PLAIN") {
                coordinator.onContextMenu = { [weak self] source, point in
                    self?.showMenu(for: nil, from: source, at: point) ?? false
                }
            }
            Task { await control.pollNowForTesting() }
            let rows = UIHostingController(rootView: Rows(select: { [weak self] id in
                guard let self else { return }; selections += 1; result.text = "selected \(id) count=\(selections)"
            }, show: { [weak self] resource, source, point in
                self?.showMenu(for: resource, from: source, at: point) ?? false
            }))
            addChild(rows); rows.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(rows.view); rows.didMove(toParent: self)
            [terminal, draft, result].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
            NSLayoutConstraint.activate([
                rows.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                rows.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                rows.view.widthAnchor.constraint(equalToConstant: 170),
                rows.view.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
                terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                terminal.leadingAnchor.constraint(equalTo: rows.view.trailingAnchor, constant: 12),
                terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                terminal.bottomAnchor.constraint(equalTo: result.topAnchor, constant: -10),
                result.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                result.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
                result.heightAnchor.constraint(equalToConstant: 34),
                result.bottomAnchor.constraint(equalTo: draft.topAnchor, constant: -8),
                draft.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                draft.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
                draft.heightAnchor.constraint(equalToConstant: 44),
                draft.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
            ])
        }
        private func showMenu(for resource: HerdrMenuResource?, from source: UIView, at point: CGPoint) -> Bool {
            guard let target = control.paneMenuTarget(for: resource) else { return false }
            return menu.present(from: source, at: point, target: target,
                workspaces: [.init(id: "w1", name: "Project"), .init(id: "w2", name: "Empty workspace")],
                perform: { [weak self] action in self?.result.text = action.command(target: target) })
        }
    }

    private struct Rows: View {
        let select: (String) -> Void
        let show: (HerdrMenuResource, UIView, CGPoint) -> Bool
        var body: some View {
            VStack(spacing: 8) {
                Text("HERDR 列表").font(.headline)
                row("Empty workspace", id: "workspace-w2", resource: .workspace("w2"))
                row("Other tab", id: "tab-w1:t2", resource: .tab("w1:t2"))
                row("Pane 1", id: "pane-w1:p1", resource: .pane("w1:p1"))
                row("Pane 2", id: "pane-w1:p2", resource: .pane("w1:p2"))
                Spacer(minLength: 0)
            }
        }
        private func row(_ title: String, id: String, resource: HerdrMenuResource) -> some View {
            ContextListButton(menu: { source, point in show(resource, source, point) }, action: { select(id) }) {
                Text(title).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).accessibilityIdentifier("menu-fixture-\(id)")
        }
    }
}
#endif
