import XCTest

/// The real app connects to the disposable loopback sshd; no activity payload
/// or connection state is injected. Notification Center hosts the same card as
/// the Lock Screen. XCUIDevice has no public simulator lock-button API.
/// Phone runs use an island-equipped simulator; tablet runs verify the card.
final class ConnectionLiveActivityUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRealSSHActivityReturnsToSessionAndEndsOnDisconnect() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test resets saved hosts; run only in a dedicated simulator")
        #else
        let env = ProcessInfo.processInfo.environment
        guard let key = env["MOSHPIT_SEED_KEY_B64"], !key.isEmpty,
              let receiptAddress = env["MOSHPIT_INPUT_RECEIPT_URL"],
              let receiptURL = URL(string: receiptAddress), receiptURL.host == "127.0.0.1" else {
            throw XCTSkip("Requires scripts/verify/terminal-input-fixture.py run")
        }
        let app = XCUIApplication()
        let id = "19963BB1-E4DD-46A7-951A-87F2B84C05B4"
        app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
            "-MOSHPIT_SEED_USER", try XCTUnwrap(env["MOSHPIT_SEED_USER"]),
            "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", try XCTUnwrap(env["MOSHPIT_SEED_PORT"]),
            "-MOSHPIT_SEED_TRUST_FP", try XCTUnwrap(env["MOSHPIT_SEED_TRUST_FP"]),
            "-MOSHPIT_SEED_NAME", "Activity Lab", "-MOSHPIT_SEED_ID", id,
            "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_SEED_QUIET", "1", "-MOSHPIT_SEED_MUX", "none",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        app.buttons["home-settings"].tap()
        let toggle = app.switches["settings-live-activity"]
        XCTAssertTrue(app.reveal(toggle))
        if toggle.value as? String == "0" { toggle.tap() }
        let names = app.switches["settings-live-activity-host-names"]
        XCTAssertTrue(app.reveal(names))
        if names.value as? String == "0" { names.tap() }
        let done = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        let host = app.buttons["connection-card-Activity Lab"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        XCTAssertTrue(app.staticTexts["terminal-host-title"].waitForExistence(timeout: 15))
        try await sendAndVerify("activity-live", in: app, receiptURL: receiptURL)
        if app.keyboards.firstMatch.exists { app.buttons["conversation-keyboard-toggle"].tap() }
        // Allow the real connection-state observer to publish; no fixture
        // substitutes for the ActivityKit request.
        try await Task.sleep(for: .seconds(3))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        capture(springboard, name: "connection-live-activity-compact-island")
        openNotificationCenter(springboard)
        let card = activityCard(in: springboard)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The real SSH session must create a system Live Activity")
        allowActivityIfOffered(in: springboard)
        capture(springboard, name: "connection-live-activity-background-card")
        let cardLabels = card.descendants(matching: .any).allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertFalse(cardLabels.contains("127.0.0.1"), "The card must not expose an SSH address")
        XCTAssertTrue(cardLabels.contains("Activity Lab"), "The host alias must remain visible in the background")
        XCTAssertTrue(cardLabels.contains("SSH"), "A plain SSH connection must have useful context even without task hooks")
        card.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.staticTexts["terminal-host-title"].waitForExistence(timeout: 10))
        try await sendAndVerify("activity-returned", in: app, receiptURL: receiptURL)

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCUIDevice.shared.press(.home)
            try await Task.sleep(for: .seconds(1))
            capture(springboard, name: "connection-live-activity-compact-island-allowed")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
                .press(forDuration: 1.3)
            let expanded = springboard.descendants(matching: .any)
                .matching(identifier: "connection-live-activity-expanded").firstMatch
            XCTAssertTrue(expanded.waitForExistence(timeout: 10),
                          "Run the phone test on a simulator with Dynamic Island")
            capture(springboard, name: "connection-live-activity-expanded-island")
            expanded.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(app.staticTexts["terminal-host-title"].waitForExistence(timeout: 10))
        }

        if app.keyboards.firstMatch.exists { app.buttons["conversation-keyboard-toggle"].tap() }
        if app.buttons["terminal-back"].exists { app.buttons["terminal-back"].tap() }
        else { app.buttons["terminal-sidebar"].tap() }
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        let disconnect = app.buttons["disconnect-host-\(id)"]
        pressForMenu(host, until: disconnect)
        disconnect.tap()
        try await Task.sleep(for: .seconds(3))
        XCUIDevice.shared.press(.home)
        openNotificationCenter(springboard)
        XCTAssertTrue(activityCard(in: springboard).waitForNonExistence(timeout: 10),
                      "Disconnecting the last host must end its system Live Activity")
        capture(springboard, name: "connection-live-activity-ended")
        app.activate()
        #endif
    }

    @MainActor
    private func allowActivityIfOffered(in springboard: XCUIApplication) {
        // Only called after our fixture's card exists, on a simulator. iOS may
        // ask once below the card whether this app may keep Live Activities.
        for title in ["Always Allow", "始终允许", "一律允許", "Allow", "允许", "允許"] {
            let allow = springboard.buttons[title].firstMatch
            if allow.exists && allow.isHittable { allow.tap(); return }
        }
    }

    @MainActor
    private func openNotificationCenter(_ springboard: XCUIApplication) {
        // Left of the camera island and right of the upper-left hot corner.
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.01))
        let finish = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75))
        start.press(forDuration: 0.1, thenDragTo: finish)
    }

    @MainActor
    private func activityCard(in springboard: XCUIApplication) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(identifier: "connection-live-activity-card").firstMatch
    }

    @MainActor
    private func sendAndVerify(_ text: String, in app: XCUIApplication, receiptURL: URL) async throws {
        var reset = URLRequest(url: receiptURL)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let send = app.buttons["conversation-send"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        await fulfillment(of: [enabled], timeout: 20)
        send.tap()
        let expected = Array(("\u{1b}[200~" + text + "\u{1b}[201~\r").utf8).map(Int.init)
        var received: [Int] = []
        for _ in 0..<50 {
            var request = URLRequest(url: receiptURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            received = try XCTUnwrap(receipt["bytes"] as? [Int])
            if received == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(received, expected)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
