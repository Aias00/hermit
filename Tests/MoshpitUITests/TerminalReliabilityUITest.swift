import XCTest
import UIKit

/// Real SSH against an isolated terminal owned by the simulator test harness.
final class TerminalReliabilityUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIApplication().terminate()
    }

    @MainActor
    private func openTerminal(multiplexer: String = "herdr", seedImage: Bool = false) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["MOSHPIT_SEED_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("requires the isolated SSH test host and MOSHPIT_SEED_PASSWORD environment variable")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOSHPIT_SEED_PASSWORD"] = password
        app.launchArguments += ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "1",
            "-MOSHPIT_SEED_USER", "aias", "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_NAME", "Isolated-UI-Lab", "-MOSHPIT_SEED_QUIET", "1",
            "-MOSHPIT_SEED_MUX", multiplexer,
            "-MOSHPIT_SEED_HERDR_BIN", "/tmp/moshpit-ui-lab/herdr",
            "-MOSHPIT_SEED_TRUST_FP", "SHA256:iKK6EXDfFALcYCaggiqUfP0PcryrRX4KtJgLoam+npA",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if seedImage { app.launchArguments.append("-MOSHPIT_SEED_IMAGE_DRAFT") }
        app.launch()
        XCTAssertTrue(app.buttons["conversation-keyboard-toggle"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
    }

    @MainActor
    private func submit(_ command: String, in app: XCUIApplication) {
        let field = composer(app)
        field.tap()
        field.typeText(command)
        XCTAssertEqual(field.value as? String, command, "complete input must remain in the composer before sending")
        let send = app.buttons["conversation-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let cleared = NSPredicate { element, _ in
            !String(describing: (element as? XCUIElement)?.value ?? "").contains(command)
        }
        expectation(for: cleared, evaluatedWith: field)
        waitForExpectations(timeout: 15)
    }

    @MainActor
    func testHerdrKeyboardCtrlAndDraftPreservation() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("kept draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let ctrl = app.buttons["conversation-ctrl"]
        ctrl.tap()
        XCTAssertTrue(ctrl.isSelected)
        app.typeText("c")
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: ctrl)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(String(describing: field.value ?? "").contains("kept draft"))
        field.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "herdr-keyboard-ctrl-submit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNativeFontSidebarRotationAndForeground() throws {
        let app = try openTerminal()
        let menu = app.buttons["conversation-menu"]
        menu.tap()
        app.buttons["自动适配字号"].tap()
        let before = Double(String(describing: menu.value ?? "").components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(before, 0)
        menu.tap()
        app.buttons["放大字体"].tap()
        let enlarged = NSPredicate { _, _ in
            let value = Double(String(describing: menu.value ?? "").components(separatedBy: " ").first ?? "") ?? 0
            return value > before
        }
        expectation(for: enlarged, evaluatedWith: menu)
        waitForExpectations(timeout: 5)
        let sidebar = app.buttons["conversation-sidebar"]
        let tabs = app.descendants(matching: .any).matching(identifier: "herdr-tabs").firstMatch
        XCTAssertTrue(tabs.exists)
        let fullWidth = tabs.frame.width
        sidebar.tap()
        XCTAssertTrue(sidebar.isSelected)
        XCTAssertLessThan(tabs.frame.width, fullWidth, "sidebar must reserve its own width")
        app.buttons["conversation-sidebar-collapse"].tap()
        XCTAssertEqual(tabs.frame.width, fullWidth, accuracy: 1, "hiding sidebar returns width to terminal")
        XCTAssertTrue(app.buttons["herdr-tab-add"].isHittable)
        XCTAssertFalse(sidebar.isSelected)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        // A query can finish during rotation. Tapping waits for animations to
        // settle, then verifies the actual controls in the new geometry.
        menu.tap()
        app.buttons["自动适配字号"].tap()
        XCTAssertTrue(app.buttons["conversation-keyboard-toggle"].isHittable)
        XCTAssertTrue(app.buttons["conversation-arrow-right"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["conversation-send"].waitForExistence(timeout: 10))
        submit("printf 'HERDR_RESUME_OK\\n' >> /tmp/moshpit-ui-lab/received.log", in: app)
    }

    @MainActor
    func testRejectedHerdrSubmissionRetainsDraft() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("__MOSHPIT_REJECT_DRAFT__")
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__")
        let send = app.buttons["conversation-send"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '草稿已保留'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(String(describing: field.value ?? "").contains("__MOSHPIT_REJECT_DRAFT__"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "failed-submission-retains-draft"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testReturnAddsNewlineThenPlaneSendsForHerdrAndSSH() throws {
        for mux in ["herdr", "none"] {
            let app = try openTerminal(multiplexer: mux)
            let field = composer(app)
            field.tap()
            let command = "printf 'PLANE_AFTER_NEWLINE_" + mux.uppercased() + "_OK\\n' >> /tmp/moshpit-ui-lab/received.log"
            field.typeText(command)
            XCTAssertEqual(field.value as? String, command)
            field.typeText("\n")
            XCTAssertEqual(field.value as? String, command + "\n")
            field.typeText("# second line")
            XCTAssertEqual(field.value as? String, command + "\n# second line")
            app.buttons["conversation-send"].tap()
            expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
            waitForExpectations(timeout: 15)
            app.terminate()
        }
    }

    @MainActor
    func testPlaneFailureRetainsMultilineDraft() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("__MOSHPIT_REJECT_DRAFT__\n")
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__\n")
        app.buttons["conversation-send"].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '草稿已保留'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__\n")
    }

    @MainActor
    func testVisualStatesAndShortcutKeys() throws {
        let app = try openTerminal()
        let menu = app.buttons["conversation-menu"]
        func capture(_ name: String) {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let name = name.replacingOccurrences(of: "ipad-", with: device + "-")
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            print("VISUAL \(name) app=\(app.frame) image=\(shot.image.size) orientation=\(shot.image.imageOrientation.rawValue)")
        }
        func verifyKeys() {
            for button in [app.buttons["conversation-attachments"], app.buttons["conversation-direct-input"],
                           app.buttons["conversation-ctrl"], app.buttons["Esc"],
                           app.buttons["更多快捷键"], app.buttons["向上"], app.buttons["向下"],
                           app.buttons["向左"], app.buttons["conversation-arrow-right"],
                           app.buttons["conversation-keyboard-toggle"]] {
                XCTAssertTrue(button.isHittable, button.identifier)
                XCTAssertTrue(app.frame.contains(button.frame), "key must be fully inside the app: \(button.identifier)")
            }
        }
        submit("python3 /tmp/moshpit-ui-lab/visual-check.py screen", in: app)
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        menu.tap()
        app.buttons["自动适配字号"].tap()
        verifyKeys()
        capture("ipad-portrait-font-colours-and-keys")
        app.buttons["conversation-sidebar"].tap()
        XCTAssertTrue(app.buttons["conversation-sidebar"].isSelected)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'spaces'")).count, 1,
            "workspace header must appear once even when several agents are present")
        XCTAssertTrue(app.buttons["conversation-sidebar-collapse"].isHittable)
        verifyKeys()
        capture("ipad-portrait-sidebar")
        app.buttons["conversation-sidebar"].tap()
        composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        verifyKeys()
        capture("ipad-portrait-software-keyboard")
        let more = app.buttons["更多快捷键"]
        let previousY = more.frame.minY
        more.tap()
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.frame.minY, previousY, accuracy: 1, "primary keys must not jump when extras open")
        XCTAssertTrue(app.buttons["conversation-extra-keys-close"].isHittable)
        capture("ipad-portrait-extra-shortcuts")
        app.buttons["conversation-extra-keys-close"].tap()
        verifyKeys()
        app.buttons["conversation-keyboard-toggle"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        menu.tap()
        app.buttons["自动适配字号"].tap()
        verifyKeys()
        capture("ipad-landscape-font-colours-and-keys")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        submit("python3 /tmp/moshpit-ui-lab/visual-check.py keys", in: app)
        for label in ["Esc", "向上", "向下", "向左"] { app.buttons[label].tap() }
        app.buttons["conversation-arrow-right"].tap()
        app.buttons["conversation-ctrl"].tap()
        app.typeText("c")
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: app.buttons["conversation-ctrl"])
        waitForExpectations(timeout: 5)
        capture("ipad-shortcut-actions-completed")
    }

    @MainActor
    func testImageUploadStagesInSharedDraftAndPlaneSends() throws {
        for mux in ["herdr", "none"] {
            let app = try openTerminal(multiplexer: mux, seedImage: true)
            let field = composer(app)
            expectation(for: NSPredicate { _, _ in
                (field.value as? String)?.contains("/IMG-") == true
            }, evaluatedWith: field)
            waitForExpectations(timeout: 30)
            let draft = try XCTUnwrap(field.value as? String)
            print("IMAGE_DRAFT_RECEIPT \(draft)")
            XCTAssertFalse(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(app.buttons["image-attach-send"].exists, "images use the same send button as text")
            XCTAssertFalse(app.buttons["image-attach-insert"].exists)
            app.buttons["conversation-send"].tap()
            expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
            waitForExpectations(timeout: 15)
            app.terminate()
        }
    }

    @MainActor
    func testPlainSSHConfirmedSubmission() throws {
        let app = try openTerminal(multiplexer: "none")
        submit("printf 'SSH_COMPOSER_OK\\n' >> /tmp/moshpit-ui-lab/received.log", in: app)
    }
}
