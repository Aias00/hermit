import XCTest

final class LaunchpadFlowUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDisconnectKeepsSavedHost() throws {
        let app = XCUIApplication()
        let id = "997E4C45-F739-4C0A-995C-C1677AEB8075"
        app.launchEnvironment["MOSHPIT_SEED_PASSWORD"] = "ui-test-placeholder"
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
            "-MOSHPIT_SEED_USER", "tester", "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", "1", "-MOSHPIT_SEED_NAME", "Disconnect Test",
            "-MOSHPIT_SEED_ID", id, "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_SEED_QUIET", "1",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let host = app.buttons["connection-card-Disconnect Test"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        // An unavailable loopback port gives us a registered session without
        // requiring credentials or modifying a real remote server.
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 20))
        app.buttons["OK"].tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        let disconnect = app.buttons["disconnect-host-\(id)"]
        pressForMenu(host, until: disconnect)
        disconnect.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5), "Disconnect must keep the saved host")
        pressForMenu(host, until: app.buttons["编辑主机"])
        XCTAssertFalse(disconnect.exists, "The disconnected host must not retain a live session")
        app.terminate()
    }

    @MainActor
    func testNavigationAndHostForm() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        XCTAssertTrue(app.buttons["home-add-empty"].waitForExistence(timeout: 10))
        assertHostsOnly(app)
        capture(app, name: "home-empty")
        app.buttons["home-add"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["discover-local-hosts"].exists)
        XCTAssertFalse(app.buttons["save-connection"].isEnabled)
        enter("UI Test Host", into: app.textFields["Name"])
        enter("example.invalid", into: app.textFields["Host"])
        enter("test", into: app.textFields["Username"])
        app.buttons["save-connection"].tap()
        let host = app.buttons["connection-card-UI Test Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-add-empty"].exists)
        assertHostsOnly(app)
        capture(app, name: "home-hosts-portrait")

        // Host management remains available directly from the host card.
        pressForMenu(host, until: app.buttons["编辑主机"])
        app.buttons["编辑主机"].tap()
        XCTAssertTrue(app.navigationBars["编辑 Host"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Host"].value as? String, "example.invalid")
        XCTAssertEqual(app.textFields["Username"].value as? String, "test")
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
        app.buttons["home-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        assertHostsOnly(app)
        capture(app, name: "home-hosts-landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(host.waitForExistence(timeout: 10), "Saved hosts survive the simplified home and app restart")
        assertHostsOnly(app)
    }

    @MainActor
    private func assertHostsOnly(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["SSH 主机"].exists)
        XCTAssertTrue(app.buttons["home-add"].isHittable)
        XCTAssertTrue(app.buttons["home-settings"].isHittable)
        for text in ["Actions", "Projects", "打开 Codex", "你的远程工作台"] {
            XCTAssertFalse(app.staticTexts[text].exists)
        }
        XCTAssertFalse(app.buttons["主机与设置"].exists)
    }

    @MainActor
    private func enter(_ value: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        field.typeText(value)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
