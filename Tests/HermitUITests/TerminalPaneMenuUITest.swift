import XCTest

final class TerminalPaneMenuUITest: XCTestCase {
    @MainActor private func launch(plain: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-HERMIT_PANE_MENU_FIXTURE"] + (plain ? ["-HERMIT_PANE_MENU_PLAIN"] : [])
        app.launch()
        return app
    }
    @MainActor func testDoubleTapPreservesKeyboardDraftAndCloseRequiresConfirmation() throws {
        let app = launch()
        defer { app.terminate() }
        let draft = app.textFields["pane-menu-fixture-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap(); draft.typeText(" unchanged")
        let value = draft.value as? String
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "pane-menu-fixture-terminal").firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)).doubleTap()
        let dismiss = app.buttons["pane-menu-dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(draft.value as? String, value)
        app.buttons["pane-menu-close-pane"].tap()
        let confirm = app.buttons["pane-menu-confirm-close"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No actions executed"].exists)
        app.buttons["pane-menu-cancel-close"].tap()
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        draft.typeText(" kept focus")
        XCTAssertEqual(draft.value as? String, (value ?? "") + " kept focus")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).doubleTap()
        XCTAssertTrue(app.buttons["pane-menu-split-down"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "herdr-double-tap-menu-keyboard"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["pane-menu-split-down"].tap()
        XCTAssertTrue(app.staticTexts["pane split 'w1:p2' --direction down --focus"].waitForExistence(timeout: 5))
    }
    @MainActor func testHiddenKeyboardAndPlainSSHSelection() throws {
        let app = launch()
        defer { app.terminate() }
        let terminal = app.descendants(matching: .any).matching(identifier: "pane-menu-fixture-terminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).doubleTap()
        XCTAssertTrue(app.buttons["pane-menu-dismiss"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["pane-menu-dismiss"].tap()
        let copy = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.015)).press(forDuration: 1.1)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "HERDR long press must still offer text copy")
        XCTAssertFalse(app.buttons["pane-menu-dismiss"].exists)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.terminate()
        app.launchArguments = ["-HERMIT_PANE_MENU_FIXTURE", "-HERMIT_PANE_MENU_PLAIN"]
        app.launch()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.015)).doubleTap()
        XCTAssertFalse(app.buttons["pane-menu-dismiss"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Plain SSH double tap must still offer text copy")
    }
}
