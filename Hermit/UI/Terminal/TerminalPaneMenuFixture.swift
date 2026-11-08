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
            terminal.feed(text: "\u{1b}[2J\u{1b}[HHERDR Project / Agent\r\nDouble tap for pane actions\r\nLong press still selects words\r\n")
            result.accessibilityIdentifier = "pane-menu-fixture-result"
            result.text = "No actions executed"
            coordinator.attach(to: terminal)
            if !ProcessInfo.processInfo.arguments.contains("-HERMIT_PANE_MENU_PLAIN") {
                coordinator.onContextMenu = { [weak self] source, point in
                    guard let self else { return false }
                    let target = HerdrPaneMenuTarget(generation: UUID(), paneID: "w1:p2", tabID: "w1:t1", workspaceID: "w1",
                        terminalID: "terminal-2", workspaceName: "Project", tabName: "Agent", paneIndex: 1)
                    return menu.present(from: source, at: point, target: target,
                        workspaces: [.init(id: "w1", name: "Project"), .init(id: "w2", name: "Other")],
                        perform: { [weak self] action in self?.result.text = action.command(target: target) })
                }
            }
            [terminal, draft, result].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                terminal.bottomAnchor.constraint(equalTo: result.topAnchor, constant: -10),
                result.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
                result.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
                result.heightAnchor.constraint(equalToConstant: 34),
                result.bottomAnchor.constraint(equalTo: draft.topAnchor, constant: -8),
                draft.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
                draft.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
                draft.heightAnchor.constraint(equalToConstant: 44),
                draft.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
            ])
        }
    }
}
#endif
