import XCTest

final class LaunchpadFlowUITest: XCTestCase {
    @MainActor
    func testNavigationAndHostForm() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hosts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["打开 Codex"].exists)
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-1"].tap()
        XCTAssertTrue(app.navigationBars["Host 终端"].waitForExistence(timeout: 3))
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-2"].tap()
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 3))
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-0"].tap()
        app.buttons["home-add"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["discover-local-hosts"].exists)
        XCTAssertFalse(app.buttons["save-connection"].isEnabled)
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("UI Test Host")
        app.textFields["Host"].tap(); app.textFields["Host"].typeText("example.invalid")
        app.textFields["Username"].tap(); app.textFields["Username"].typeText("test")
        app.buttons["save-connection"].tap()
        XCTAssertTrue(app.staticTexts["UI Test Host"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "launchpad-hosts"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-1"].tap()
        XCTAssertTrue(app.staticTexts["UI Test Host"].waitForExistence(timeout: 3))
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-0"].tap()
        app.buttons["add-Actions"].tap()
        let actionName = "Action " + UUID().uuidString.prefix(6)
        app.textFields["launch-item-name"].tap(); app.textFields["launch-item-name"].typeText(actionName)
        app.buttons["launch-item-host"].tap()
        app.buttons["UI Test Host"].tap()
        app.textFields["launch-item-command"].tap(); app.textFields["launch-item-command"].typeText("date")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.reveal(app.staticTexts[actionName]))
        app.staticTexts[actionName].tap()
        XCTAssertTrue(app.buttons["在 UI Test Host 上运行"].waitForExistence(timeout: 3))
        app.terminate()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.reveal(app.staticTexts[actionName]))
    }
}
