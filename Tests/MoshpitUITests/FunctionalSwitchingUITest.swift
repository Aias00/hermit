import XCTest
import UIKit

/// Cross-feature navigation against the disposable SSH fixture. These tests
/// exercise UI lifetime and input focus; seeded voice never uses a microphone.
final class FunctionalSwitchingUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIApplication().terminate()
    }

    @MainActor
    private func openTerminal() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let key = env["MOSHPIT_SEED_KEY_B64"] ?? ""
        let password = env["MOSHPIT_SEED_PASSWORD"] ?? ""
        guard !key.isEmpty || !password.isEmpty else {
            throw XCTSkip("Requires the disposable terminal SSH fixture")
        }
        let app = XCUIApplication()
        if !key.isEmpty { app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key }
        else { app.launchEnvironment["MOSHPIT_SEED_PASSWORD"] = password }
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
            "-MOSHPIT_SEED_USER", try XCTUnwrap(env["MOSHPIT_SEED_USER"]),
            "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", try XCTUnwrap(env["MOSHPIT_SEED_PORT"]),
            "-MOSHPIT_SEED_TRUST_FP", try XCTUnwrap(env["MOSHPIT_SEED_TRUST_FP"]),
            "-MOSHPIT_SEED_NAME", "Isolated-UI-Lab", "-MOSHPIT_SEED_MUX", "none",
            "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_SEED_QUIET", "1", "-MOSHPIT_SEED_VOICE_DRAFT",
            "-moshpit.settings.voiceInput", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let host = app.buttons["connection-card-Isolated-UI-Lab"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        let ready = app.buttons["conversation-attachments"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 20)
        return app
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
    }

    @MainActor
    func testRendererFontProtocolAndForegroundKeepInputUsable() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("kept through switches")
        let draft = "kept through switches"
        let menu = app.buttons["conversation-menu"]
        let originalFont = fontSize(menu)
        XCTAssertGreaterThan(originalFont, 0)
        let increaseFirst = originalFont < 32

        // Toggle both ways so the user's renderer preference is restored.
        for _ in 0..<2 {
            menu.tap()
            let renderer = app.descendants(matching: .any).matching(identifier: "terminal-metal-renderer").firstMatch
            XCTAssertTrue(renderer.waitForExistence(timeout: 3))
            renderer.tap()
            if app.buttons["重新连接"].exists {
                menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertEqual(field.value as? String, draft)
            XCTAssertTrue(app.buttons["conversation-send"].isEnabled)
        }
        menu.tap()
        app.buttons[increaseFirst ? "放大字体" : "缩小字体"].tap()
        expectation(for: NSPredicate { _, _ in self.fontSize(menu) != originalFont }, evaluatedWith: menu)
        waitForExpectations(timeout: 5)
        menu.tap()
        app.buttons[increaseFirst ? "缩小字体" : "放大字体"].tap()
        XCTAssertEqual(fontSize(menu), originalFont, accuracy: 0.1)
        XCTAssertEqual(field.value as? String, draft)

        menu.tap()
        app.buttons["切换 SSH / Mosh"].tap()
        let confirm = app.buttons["切换"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // iOS may anchor this as a popover, which omits role.cancel.
            // Its position changes with the presenting view and keyboard.
            // Pick outside the actual sheet rather than a fixed screen point
            // that can land inside the confirmation or on its Switch action.
            let popover = app.sheets.containing(.button, identifier: "切换").firstMatch
            XCTAssertTrue(popover.waitForExistence(timeout: 3))
            let frame = app.frame
            let candidates = [CGPoint(x: 0.08, y: 0.22), CGPoint(x: 0.92, y: 0.22),
                              CGPoint(x: 0.08, y: 0.75), CGPoint(x: 0.92, y: 0.75)]
                .map { CGPoint(x: frame.minX + frame.width * $0.x, y: frame.minY + frame.height * $0.y) }
            let outside = try XCTUnwrap(candidates.first { !popover.frame.insetBy(dx: -12, dy: -12).contains($0) },
                                       "The confirmation popover must have a visible outside dismissal area")
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: outside.x - frame.minX, dy: outside.y - frame.minY)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertTrue(app.buttons["conversation-send"].isEnabled)

        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(field.value as? String, draft)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(" after resume")
        XCTAssertEqual(field.value as? String, draft + " after resume")
        XCTAssertTrue(app.buttons["conversation-send"].isEnabled)
        capture("renderer-font-and-foreground-switching")
    }

    @MainActor
    func testPhotoAndVoiceCancellationPreserveDraftAndFocus() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("draft before modals")
        app.buttons["conversation-attachments"].tap()
        app.buttons["照片图库"].tap()
        let cancelPhoto = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
        XCTAssertTrue(cancelPhoto.waitForExistence(timeout: 10))
        cancelPhoto.tap()
        XCTAssertTrue(cancelPhoto.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(" after photos")
        let draft = "draft before modals after photos"
        XCTAssertEqual(field.value as? String, draft)

        app.buttons["语音输入"].tap()
        XCTAssertTrue(app.buttons["Add to Draft"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Add to Draft"].exists)
        XCTAssertEqual(field.value as? String, draft)
        app.typeText(" after voice")
        XCTAssertEqual(field.value as? String, draft + " after voice")
        XCTAssertTrue(app.buttons["conversation-send"].isEnabled)
        capture("photo-and-voice-cancel-restores-draft")
    }

    @MainActor
    func testRemoteFoldersAndHomeSettingsRoundTrips() throws {
        let env = ProcessInfo.processInfo.environment
        let fixture = try XCTUnwrap(env["MOSHPIT_SWITCH_FIXTURE_DIR"], "Requires the SFTP-enabled isolated fixture")
        let rootName = URL(fileURLWithPath: fixture).lastPathComponent
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("kept around folders")
        app.buttons["conversation-files"].tap()
        XCTAssertTrue(app.navigationBars[rootName].waitForExistence(timeout: 20))
        let nested = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "nested")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 10))
        nested.tap()
        XCTAssertTrue(app.navigationBars["nested"].waitForExistence(timeout: 5))
        let subfolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "subfolder")).firstMatch
        XCTAssertTrue(subfolder.waitForExistence(timeout: 10))
        app.navigationBars["nested"].buttons.element(boundBy: 0).tap()
        let bar = app.navigationBars[rootName]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        dismissFolder(app, navigationBar: bar)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(" after folders")
        XCTAssertEqual(field.value as? String, "kept around folders after folders")

        // Hide the keyboard, reopen the folder, and ensure dismissal keeps it hidden.
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["conversation-attachments"].tap()
        app.buttons["服务器文件"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        dismissFolder(app, navigationBar: bar)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(field.value as? String, "kept around folders after folders")
        capture("remote-folder-focus-and-hidden-keyboard")

        // Returning to a live connection must preserve unsent user input,
        // including when the phone destroys and recreates the terminal screen.
        var pendingDraft = "kept around folders after folders"
        for _ in 0..<2 {
            showHome(app)
            let host = app.buttons["connection-card-Isolated-UI-Lab"]
            XCTAssertTrue(host.staticTexts["Connected"].exists)
            app.buttons["home-settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.navigationBars["Settings"].buttons["Done"].tap()
            XCTAssertTrue(host.waitForExistence(timeout: 5))
            host.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            XCTAssertEqual(field.value as? String, pendingDraft,
                           "Home/Settings navigation must preserve the connection's unsent draft")
            field.tap()
            field.typeText(" editable")
            let edited = try XCTUnwrap(field.value as? String)
            // Tapping an existing multiline editor can place the caret in its
            // middle. Verify insertion without assuming it moved to the end.
            let before = Array(pendingDraft)
            let after = Array(edited)
            let insertion = Array(" editable")
            XCTAssertTrue((0...before.count).contains { position in
                Array(before.prefix(position)) + insertion + Array(before.dropFirst(position)) == after
            }, "Editing must insert the new text without losing or changing the restored draft")
            pendingDraft = edited
            XCTAssertTrue(app.buttons["conversation-send"].isEnabled)
            app.buttons["conversation-keyboard-toggle"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        capture("home-settings-terminal-round-trips")
    }

    @MainActor
    func testIPadSystemKeyboardDismissalSurvivesTerminalRedraw() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "The system keyboard hide key is an iPad control")
        let app = try openTerminal()
        let field = composer(app)
        let draft = "kept after system keyboard dismissal"
        field.tap()
        field.typeText(draft)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, draft)

        let before = XCTAttachment(string: app.debugDescription)
        before.name = "ipad-system-keyboard-before-dismiss-ax"
        before.lifetime = .keepAlways
        add(before)
        capture("ipad-system-keyboard-before-dismiss")
        // Exercise UIKit's own hide key, never the app's keyboard-toggle.
        let hide = app.buttons.matching(NSPredicate(format:
            "identifier != %@ AND (label CONTAINS[c] 'hide' OR label CONTAINS[c] 'dismiss' OR label CONTAINS '隐藏' OR label CONTAINS '收起') AND (label CONTAINS[c] 'keyboard' OR label CONTAINS '键盘')",
            "conversation-keyboard-toggle")).firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "The native iPad keyboard hide control must be present")
        XCTAssertTrue(hide.isHittable)
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "A user dismissal through the system keyboard must hide it")
        XCTAssertEqual(field.value as? String, draft)
        capture("ipad-system-keyboard-dismissed")

        let menu = app.buttons["conversation-menu"]
        let originalFont = fontSize(menu)
        XCTAssertGreaterThan(originalFont, 0)
        let increaseFirst = originalFont < 32
        menu.tap()
        app.buttons[increaseFirst ? "放大字体" : "缩小字体"].tap()
        expectation(for: NSPredicate { _, _ in self.fontSize(menu) != originalFont }, evaluatedWith: menu)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "A terminal redraw must not reverse an explicit system keyboard dismissal")
        XCTAssertEqual(field.value as? String, draft)
        menu.tap()
        app.buttons[increaseFirst ? "缩小字体" : "放大字体"].tap()
        XCTAssertEqual(fontSize(menu), originalFont, accuracy: 0.1)
        // Watch for deferred focus restoration after UIKit's menu closes too.
        let unsolicited = expectation(for: NSPredicate { _, _ in app.keyboards.firstMatch.exists }, evaluatedWith: app)
        unsolicited.isInverted = true
        wait(for: [unsolicited], timeout: 2)
        XCTAssertEqual(field.value as? String, draft)
        let after = XCTAttachment(string: app.debugDescription)
        after.name = "ipad-system-keyboard-after-redraw-ax"
        after.lifetime = .keepAlways
        add(after)
        capture("ipad-system-keyboard-remains-hidden-after-redraw")
    }

    @MainActor
    private func dismissFolder(_ app: XCUIApplication, navigationBar: XCUIElement) {
        let start = navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(navigationBar.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func showHome(_ app: XCUIApplication) {
        if app.buttons["terminal-back"].exists { app.buttons["terminal-back"].tap() }
        else { app.buttons["terminal-sidebar"].tap() }
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func fontSize(_ menu: XCUIElement) -> Double {
        Double(String(describing: menu.value ?? "").components(separatedBy: " ").first ?? "") ?? 0
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
