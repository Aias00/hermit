import XCTest

/// Real transport and pane switching against terminal-session-fixture.py.
/// All remote writes and generated sessions belong to the disposable lab.
final class TerminalSessionSwitchingUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(multiplexer: String, name: String) throws -> (XCUIApplication, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["MOSHPIT_SEED_KEY_B64"], !key.isEmpty,
              let directory = env["MOSHPIT_SWITCH_FIXTURE_DIR"],
              directory.hasPrefix("/private/tmp/moshpit-ui-lab") || directory.hasPrefix("/tmp/moshpit-ui-lab"),
              let herdr = env["MOSHPIT_SEED_HERDR_BIN"],
              let mosh = env["MOSHPIT_SEED_MOSH_BIN"] else {
            throw XCTSkip("Requires the isolated real terminal-session-fixture.py runner")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "1",
            "-MOSHPIT_SEED_USER", try XCTUnwrap(env["MOSHPIT_SEED_USER"]),
            "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", try XCTUnwrap(env["MOSHPIT_SEED_PORT"]),
            "-MOSHPIT_SEED_TRUST_FP", try XCTUnwrap(env["MOSHPIT_SEED_TRUST_FP"]),
            "-MOSHPIT_SEED_NAME", name, "-MOSHPIT_SEED_QUIET", "1",
            "-MOSHPIT_SEED_MUX", multiplexer,
            "-MOSHPIT_SEED_HERDR_BIN", herdr, "-MOSHPIT_SEED_MOSH_BIN", mosh,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation-menu"].waitForExistence(timeout: 30))
        return (app, URL(fileURLWithPath: directory))
    }

    @MainActor
    func testSSHToMoshAndBackDeliversInput() throws {
        let (app, directory) = try launch(multiplexer: "none", name: "Protocol Switch Lab")
        let receipt = directory.appendingPathComponent("protocol-switch-\(UUID().uuidString).txt")
        defer { app.terminate(); try? FileManager.default.removeItem(at: receipt) }
        XCTAssertTrue(app.staticTexts["SSH"].firstMatch.waitForExistence(timeout: 10))
        submit("printf 'ssh-before\\n' >> \(quote(receipt.path))", in: app)
        waitForReceipt(receipt, containing: "ssh-before\n")

        var expected = "ssh-before\n"
        // Replaced screens must keep working after more than one reconnect.
        for round in 1...2 {
            switchProtocol(in: app, expected: "Mosh")
            submit("printf 'mosh-live-\(round)\\n' >> \(quote(receipt.path))", in: app)
            expected += "mosh-live-\(round)\n"
            waitForReceipt(receipt, containing: expected)
            capture("protocol-mosh-live-\(round)")

            switchProtocol(in: app, expected: "SSH")
            submit("printf 'ssh-after-\(round)\\n' >> \(quote(receipt.path))", in: app)
            expected += "ssh-after-\(round)\n"
            waitForReceipt(receipt, containing: expected)
        }
        XCTAssertEqual(try String(contentsOf: receipt, encoding: .utf8), expected,
                       "Each transport must deliver its input exactly once")
        capture("protocol-returned-to-ssh")
    }

    @MainActor
    func testTerminalMenuOpensWorkspaceAndPanePickers() throws {
        let (app, _) = try launch(multiplexer: "herdr", name: "Herdr Menu Lab")
        defer { app.terminate() }
        let ready = expectation(for: NSPredicate(format: "enabled == true"),
                                evaluatedWith: app.buttons["conversation-sidebar"])
        wait(for: [ready], timeout: 25)
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        field.tap()
        field.typeText("draft across menu pickers")

        app.buttons["conversation-menu"].tap()
        app.buttons["选择会话"].tap()
        let workspaces = app.navigationBars["工作区"]
        XCTAssertTrue(workspaces.waitForExistence(timeout: 10))
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ui-lab")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        XCTAssertTrue(workspaces.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "draft across menu pickers")

        app.buttons["conversation-menu"].tap()
        app.buttons["选择窗格"].tap()
        let panes = app.navigationBars["选择窗格"]
        XCTAssertTrue(panes.waitForExistence(timeout: 10))
        let pane = app.collectionViews.cells.firstMatch.buttons.firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        XCTAssertTrue(panes.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "draft across menu pickers")
        capture("terminal-menu-workspace-pane-round-trips")
    }

    @MainActor
    func testHerdrNewTabSwitchesToIndependentShellAndBack() throws {
        let (app, directory) = try launch(multiplexer: "herdr", name: "Herdr Switch Lab")
        let receipt = directory.appendingPathComponent("tab-switch-\(UUID().uuidString).txt")
        defer { app.terminate(); try? FileManager.default.removeItem(at: receipt) }
        let tabs = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier != %@ AND identifier != %@",
            "herdr-tab-", "herdr-tab-add", "herdr-tab-manager"))
        let ready = expectation(for: NSPredicate { _, _ in tabs.count >= 2 }, evaluatedWith: nil)
        wait(for: [ready], timeout: 30)
        let first = tabs.element(boundBy: 0)
        let firstID = first.identifier
        first.tap()
        waitForSelected(first)
        let location = app.descendants(matching: .any).matching(identifier: "terminal-location").firstMatch
        XCTAssertTrue(location.exists)
        let firstLocation = location.label
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        field.tap()
        field.typeText("kept draft")
        let second = tabs.element(boundBy: 1)
        second.tap()
        waitForSelected(second)
        XCTAssertNotEqual(location.label, firstLocation, "the header must identify the newly selected tab")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        // No field tap: switching tabs must preserve the existing draft focus.
        app.typeText(" after switch")
        XCTAssertEqual(field.value as? String, "kept draft after switch")
        XCTAssertFalse(app.buttons["conversation-direct-input"].isSelected)
        first.tap()
        waitForSelected(first)
        XCTAssertEqual(location.label, firstLocation)
        XCTAssertEqual(field.value as? String, "kept draft after switch")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "kept draft after switch".count))
        XCTAssertEqual(field.value as? String, "")
        submit("printf 'first:%s\\n' \"$$\" >> \(quote(receipt.path))", in: app)
        waitForReceipt(receipt, containing: "first:")
        hideKeyboard(app)

        let previousCount = tabs.count
        app.buttons["herdr-tab-add"].tap()
        let added = expectation(for: NSPredicate { _, _ in tabs.count == previousCount + 1 }, evaluatedWith: nil)
        wait(for: [added], timeout: 15)
        let selected = tabs.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        let newID = selected.identifier
        XCTAssertNotEqual(newID, firstID)
        submit("printf 'new:%s\\n' \"$$\" >> \(quote(receipt.path))", in: app)
        waitForReceipt(receipt, containing: "new:")
        hideKeyboard(app)
        capture("herdr-created-tab")

        let originalTab = app.buttons[firstID]
        if !originalTab.isHittable { app.scrollViews.containing(.button, identifier: firstID).firstMatch.swipeRight() }
        originalTab.tap()
        waitForSelected(originalTab)
        submit("printf 'returned:%s\\n' \"$$\" >> \(quote(receipt.path))", in: app)
        waitForReceipt(receipt, containing: "returned:")
        let lines = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let initialPID = lines[0].split(separator: ":").last
        let newPID = lines[1].split(separator: ":").last
        let returnedPID = lines[2].split(separator: ":").last
        XCTAssertNotEqual(initialPID, newPID, "New tab must execute in its own remote shell")
        XCTAssertEqual(initialPID, returnedPID, "Returning must preserve the original shell")
        hideKeyboard(app)
        capture("herdr-returned-to-original-tab")
    }

    @MainActor
    private func switchProtocol(in app: XCUIApplication, expected: String) {
        hideKeyboard(app)
        app.buttons["conversation-menu"].tap()
        app.buttons["切换 SSH / Mosh"].tap()
        let confirm = app.buttons["切换"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts[expected].firstMatch.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "enabled == true"),
                                evaluatedWith: app.buttons["conversation-enter"])
        wait(for: [ready], timeout: 30)
        XCTAssertFalse(app.staticTexts["Connection Error"].exists)
    }

    @MainActor
    private func submit(_ command: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(command)
        XCTAssertEqual(field.value as? String, command)
        let send = app.buttons["conversation-send"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 30)
        send.tap()
        let clear = expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
        wait(for: [clear], timeout: 15)
    }

    @MainActor
    private func waitForSelected(_ button: XCUIElement) {
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: button)
        wait(for: [selected], timeout: 15)
    }

    private func waitForReceipt(_ url: URL, containing value: String) {
        let received = expectation(for: NSPredicate { _, _ in
            (try? String(contentsOf: url, encoding: .utf8).contains(value)) == true
        }, evaluatedWith: nil)
        wait(for: [received], timeout: 20)
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            app.buttons["conversation-keyboard-toggle"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
