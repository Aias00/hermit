import Observation
import SwiftUI
import MoshpitKit

/// The hardware-keyboard chords of whichever screen currently owns them.
///
/// Why this exists: SwiftUI's `.keyboardShortcut` on a button inside the
/// screen is found by walking the responder chain up from the first
/// responder. With the terminal focused that walk passes the hosting view
/// and works; with the keyboard down UIKit starts at the deepest view
/// controller and never visits the hosting view, so hidden shortcut
/// buttons in `TerminalScreen` were dead exactly when nothing was focused.
/// (Vending `UIKeyCommand`s from a `UIResponder` app delegate instead broke
/// the Home toolbar's shortcuts outright.) The scene's `.commands` menu is
/// dispatched by the menu system, focused or not, so `TerminalCommands`
/// declares the chords once and the screen on duty registers what they do.
/// The empty iPad home/detail layout needs the same scene-level dispatch.
@MainActor @Observable
final class HardwareKeys {
    static let shared = HardwareKeys()

    struct Command {
        let title: String
        let key: Character
        let action: () -> Void
    }

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var actions: [Character: () -> Void] = [:]
    @ObservationIgnored private var homeOwner: UUID?
    @ObservationIgnored private var homeActions: [Character: () -> Void] = [:]
    /// Whether a screen has chords registered; the menu greys out otherwise.
    private(set) var isActive = false
    private(set) var isHomeActive = false

    /// Replaces the set. `owner` lets a screen that is being swapped for
    /// another instance of itself (iPad sidebar, `.id`) release only its own
    /// registration — SwiftUI runs the newcomer's `onAppear` before the old
    /// view's `onDisappear`.
    func install(owner: UUID, _ list: [Command]) {
        self.owner = owner
        actions = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0.action) })
        isActive = !actions.isEmpty
    }

    func uninstall(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        actions = [:]
        isActive = false
    }

    /// True when the chord was ours.
    @discardableResult
    func perform(_ key: Character) -> Bool {
        guard let action = actions[key] else { return false }
        action()
        return true
    }

    /// Home can remain mounted beside a terminal on iPad. Keep its lifecycle
    /// separate so a sidebar appearing/disappearing cannot replace terminal
    /// commands or unregister their owner.
    func installHome(owner: UUID, _ list: [Command]) {
        homeOwner = owner
        homeActions = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0.action) })
        isHomeActive = !homeActions.isEmpty
        Log.input.info("hardware home: registered")
    }

    func uninstallHome(owner: UUID) {
        guard homeOwner == owner else { return }
        homeOwner = nil
        homeActions = [:]
        isHomeActive = false
        Log.input.info("hardware home: unregistered")
    }

    @discardableResult
    func performHome(_ key: Character) -> Bool {
        guard let action = homeActions[key] else {
            Log.input.info("hardware home: no active action")
            return false
        }
        Log.input.info("hardware home: action \(String(key), privacy: .public)")
        action()
        return true
    }
}

/// Home's ⌘, / ⌘N and the terminal's ⌘K / ⌘W / ⌘1–9. Titles show in the
/// iPad ⌘-hold overlay, and each screen registers only its own actions.
struct TerminalCommands: Commands {
    private static let numbers: [Character] = Array("123456789")

    var body: some Commands {
        // These chords already belong to the system's Settings/New groups.
        // Replace those entries rather than competing from another menu. Keep
        // registration static like the terminal commands: the current owner
        // checks availability at dispatch, even before any editor has focus.
        CommandGroup(replacing: .appSettings) {
            Button("Settings") { HardwareKeys.shared.performHome(",") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Host") { HardwareKeys.shared.performHome("n") }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Terminal") {
            Button("Switch Window") { HardwareKeys.shared.perform("k") }
                .keyboardShortcut("k", modifiers: .command)
            Button("Back to Home") { HardwareKeys.shared.perform("w") }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            ForEach(Self.numbers, id: \.self) { number in
                Button("Window \(String(number))") { HardwareKeys.shared.perform(number) }
                    .keyboardShortcut(KeyEquivalent(number), modifiers: .command)
            }
        }
    }
}
