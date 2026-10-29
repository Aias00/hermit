import Foundation

enum TerminalInputPrivacy {
    /// A terminal draft may be a password even when the remote disables echo.
    /// Older versions persisted every submission; erase that history once the
    /// preferences file is accessible, including after a locked cold launch.
    static func removeLegacyHistory(defaults: UserDefaults = .standard,
                                    readiness: DefaultsReadiness = .system) {
        guard readiness.isReadable(defaults) else { return }
        defaults.removeObject(forKey: "moshpit.composer.history.v1")
    }
}
