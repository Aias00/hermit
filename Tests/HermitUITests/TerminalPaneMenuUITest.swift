import XCTest

final class TerminalPaneMenuUITest: XCTestCase {
    @MainActor private func launch(plain: Bool = false, selection: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-HERMIT_PANE_MENU_FIXTURE"] + (plain ? ["-HERMIT_PANE_MENU_PLAIN"] : [])
        if selection { app.launchArguments.append("-HERMIT_SELECTION_SCROLL_FIXTURE") }
        app.launch()
        return app
    }
    @MainActor func testSelectionDragScrollsBeyondOneScreen() throws {
        let app = launch(selection: true)
        defer { app.terminate() }
        let terminal = app.descendants(matching: .any).matching(identifier: "pane-menu-fixture-terminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let edge = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.003))
        start.press(forDuration: 1, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 3)
        let status = app.staticTexts["pane-menu-fixture-result"]
        let beyondScreen = NSPredicate { _, _ in
            let counts = status.label.split(separator: " ").compactMap { Int($0.split(separator: "=").last ?? "") }
            return counts.count == 2 && counts[0] > counts[1]
        }
        expectation(for: beyondScreen, evaluatedWith: status)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["pane-menu-dismiss"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let copy = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-selection-cross-screen"; shot.lifetime = .keepAlways; add(shot)
        copy.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'selected=0 '"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
    }
    @MainActor func testDoubleTapPreservesKeyboardDraftAndCloseRequiresConfirmation() throws {
        let app = launch()
        defer { app.terminate() }
        let draft = app.textFields["pane-menu-fixture-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap(); draft.typeText(" unchanged")
        let value = "keep draft unchanged"
        expectation(for: NSPredicate { _, _ in draft.value as? String == value }, evaluatedWith: draft)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let row = app.buttons["menu-fixture-pane-w1:p1"]
        row.doubleTap()
        let dismiss = app.buttons["pane-menu-dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Project · Agent · 1"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(draft.value as? String, value)
        app.buttons["pane-menu-close-resource"].tap()
        let confirm = app.buttons["pane-menu-confirm-close"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No actions executed"].exists)
        app.buttons["pane-menu-cancel-close"].tap()
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        draft.typeText(" kept focus")
        expectation(for: NSPredicate { _, _ in draft.value as? String == value + " kept focus" }, evaluatedWith: draft)
        waitForExpectations(timeout: 10)
        row.doubleTap()
        XCTAssertTrue(app.buttons["pane-menu-split-down"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "herdr-list-double-tap-menu-keyboard"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["pane-menu-split-down"].tap()
        XCTAssertTrue(app.staticTexts["pane split 'w1:p1' --direction down --focus"].waitForExistence(timeout: 5))
        app.buttons["menu-fixture-pane-w1:p2"].tap()
        XCTAssertTrue(app.staticTexts["selected pane-w1:p2 count=1"].waitForExistence(timeout: 5))
    }
    @MainActor func testHiddenKeyboardAndPlainSSHSelection() throws {
        let app = launch()
        defer { app.terminate() }
        let terminal = app.descendants(matching: .any).matching(identifier: "pane-menu-fixture-terminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // The fixture must wire the production secondary-click callback. A
        // finger tap must never enter that pointer-only path, anywhere on it.
        let dismiss = app.buttons["pane-menu-dismiss"]
        for point in [CGVector(dx: 0.12, dy: 0.015), CGVector(dx: 0.85, dy: 0.3), CGVector(dx: 0.5, dy: 0.7)] {
            terminal.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(dismiss.waitForNonExistence(timeout: 2), "A single finger tap must not open HERDR actions")
        }
        app.buttons["menu-fixture-pane-w1:p2"].tap()
        XCTAssertTrue(app.staticTexts["selected pane-w1:p2 count=1"].waitForExistence(timeout: 5))
        XCTAssertFalse(dismiss.exists)
        app.buttons["menu-fixture-workspace-w2"].doubleTap()
        XCTAssertTrue(app.buttons["pane-menu-dismiss"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["pane-menu-split-down"].exists)
        XCTAssertTrue(app.buttons["pane-menu-close-resource"].label.contains("工作区"))
        app.buttons["pane-menu-new-tab"].tap()
        XCTAssertTrue(app.staticTexts["tab create --workspace 'w2' --focus"].waitForExistence(timeout: 5))
        app.buttons["menu-fixture-tab-w1:t2"].doubleTap()
        XCTAssertTrue(app.buttons["pane-menu-split-down"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pane-menu-close-resource"].label.contains("标签页"))
        app.buttons["pane-menu-split-down"].tap()
        XCTAssertTrue(app.staticTexts["pane split 'w1:p3' --direction down --focus"].waitForExistence(timeout: 5))
        let copy = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.015)).press(forDuration: 1.1)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "HERDR long press must still offer text copy")
        XCTAssertFalse(app.buttons["pane-menu-dismiss"].exists)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.015)).doubleTap()
        XCTAssertFalse(app.buttons["pane-menu-dismiss"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Terminal double tap must select words instead of opening actions")
    }
}
