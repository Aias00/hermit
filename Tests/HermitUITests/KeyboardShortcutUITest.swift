import UIKit
import XCTest

/// Hardware-keyboard shortcuts (iPad with a keyboard, Mac). `typeKey` puts
/// the chord on the device the way a keyboard would — the Simulator app's
/// own menu shortcuts (⌘K, ⌘W, ⌘1…) never see it, which is why this cannot
/// be driven from the Mac side and lives here.
///
/// Run on the iPad simulator. The iPhone 17 Pro simulator on this machine
/// stopped delivering `typeKey` chords to the app mid-session (the same
/// build kept passing on the iPad), so a red here on an iPhone destination
/// is the device, not the feature — the feature is an iPad one anyway.
final class KeyboardShortcutUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // The class comment is the rule: this suite runs on the iPad
        // simulator. On an iPhone destination the chords stop reaching the
        // app, so a red there says nothing about the feature; skip instead.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "hardware-keyboard shortcuts are exercised on the iPad simulator")
    }

    @MainActor
    func testHomeShortcutsOpenSettingsAndAddConnection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["SSH 主机"].waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                      "⌘, opens Settings")
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 3))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 3),
                      "⌘N opens Add Connection")
        app.navigationBars["新建 Host"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForNonExistence(timeout: 3))
    }

    /// Needs a live host: run with
    /// `TEST_RUNNER_MOSHPIT_SEED_USER=<user> TEST_RUNNER_MOSHPIT_SEED_KEY_B64=<pem b64>`
    /// (and optionally `TEST_RUNNER_MOSHPIT_SEED_TMUX_BIN`) against a tmux
    /// server with at least two windows. Skips otherwise.
    @MainActor
    func testTerminalShortcutsSwitchWindowsAndLeave() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["MOSHPIT_SEED_USER"], let key = env["MOSHPIT_SEED_KEY_B64"] else {
            throw XCTSkip("no MOSHPIT_SEED_USER / MOSHPIT_SEED_KEY_B64 in the test runner's environment")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key
        app.launchArguments += [
            "-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "1", "-MOSHPIT_SEED_HOME", "1",
            "-MOSHPIT_SEED_USER", user,
            "-MOSHPIT_SEED_HOST", env["MOSHPIT_SEED_HOST"] ?? "127.0.0.1",
            "-MOSHPIT_SEED_PORT", env["MOSHPIT_SEED_PORT"] ?? "22",
            "-MOSHPIT_SEED_NAME", "local-mac", "-MOSHPIT_SEED_TMUX", "1", "-MOSHPIT_SEED_QUIET", "1",
        ]
        if let fingerprint = env["MOSHPIT_SEED_TRUST_FP"] {
            app.launchArguments += ["-MOSHPIT_SEED_TRUST_FP", fingerprint]
        }
        if let tmux = env["MOSHPIT_SEED_TMUX_BIN"] {
            app.launchArguments += ["-MOSHPIT_SEED_TMUX_BIN", tmux]
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        defer { app.terminate() }
        let card = app.buttons["connection-card-local-mac"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        if env["MOSHPIT_SEED_TRUST_FP"] == nil {
            let trust = app.buttons["Trust"]
            if trust.waitForExistence(timeout: 8) { trust.tap() }
        }
        // A saved host now opens the terminal directly. Readiness comes from
        // the live multiplexer controls, not the removed home session tree.
        let title = app.staticTexts["terminal-host-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "local-mac")
        let sidebar = app.buttons["conversation-sidebar"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: sidebar)
        waitForExpectations(timeout: 25)

        let firstName = env["MOSHPIT_SEED_FIRST_WINDOW"] ?? "1: shell"
        let secondName = env["MOSHPIT_SEED_SECOND_WINDOW"] ?? "2: logs"
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", firstName + ",")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", secondName + ",")).firstMatch
        let windows = app.navigationBars["Windows"]

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(windows.waitForExistence(timeout: 5), "⌘K opens Windows")
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(windows.waitForNonExistence(timeout: 5))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(windows.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: second)
        waitForExpectations(timeout: 5)
        second.tap() // Close the picker without changing its selected window.
        XCTAssertTrue(windows.waitForNonExistence(timeout: 5))

        // With a text input focused, the responder chain must still deliver
        // the window shortcut instead of inserting the chord into the draft.
        app.buttons["conversation-keyboard-toggle"].tap()
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(windows.waitForExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        first.tap()
        XCTAssertTrue(windows.waitForNonExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "⌘W closes the terminal screen")
        XCTAssertTrue(app.navigationBars["SSH 主机"].waitForExistence(timeout: 5))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts["已连接"].exists,
                      "The saved host stays connected after leaving its terminal")
    }
}
