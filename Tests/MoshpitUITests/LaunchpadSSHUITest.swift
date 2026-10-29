import XCTest

/// Saved-host navigation against an isolated SSH input receiver. The fixture
/// records PTY bytes without executing any received text as a shell command.
final class LaunchpadSSHUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("SSH fixtures reset app data; run on a dedicated simulator only")
        #endif
    }

    @MainActor
    func testSavedHostConnectsReopensAndDisconnects() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["MOSHPIT_SEED_KEY_B64"], !key.isEmpty,
              let receiptAddress = environment["MOSHPIT_INPUT_RECEIPT_URL"],
              let receiptURL = URL(string: receiptAddress), receiptURL.host == "127.0.0.1" else {
            throw XCTSkip("Requires scripts/verify/terminal-input-fixture.py run")
        }
        let username = try XCTUnwrap(environment["MOSHPIT_SEED_USER"])
        let port = try XCTUnwrap(environment["MOSHPIT_SEED_PORT"])
        let fingerprint = try XCTUnwrap(environment["MOSHPIT_SEED_TRUST_FP"])
        let id = "D039F5EE-EF75-4B68-9AAA-50D2DBFBD281"
        let app = XCUIApplication()
        app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
            "-MOSHPIT_SEED_USER", username, "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", port, "-MOSHPIT_SEED_NAME", "Review SSH",
            "-MOSHPIT_SEED_ID", id, "-MOSHPIT_SEED_TRUST_FP", fingerprint,
            "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_SEED_QUIET", "1", "-MOSHPIT_SEED_MUX", "none",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let host = app.buttons["connection-card-Review SSH"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        try await resetReceipt(receiptURL)
        host.tap()
        let title = app.staticTexts["terminal-host-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Review SSH")
        submit("first input", in: app)
        let firstInput = framedInput("first input")
        try await assertReceipt(receiptURL, equals: firstInput)
        XCTAssertFalse(app.staticTexts["Connection Error"].exists)
        hideKeyboard(app)
        capture(app, name: "ssh-saved-host-connected")

        showHome(app, host: host)
        XCTAssertTrue(host.isHittable)
        XCTAssertTrue(host.staticTexts["Connected"].exists)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("not-a-saved-host")
        XCTAssertTrue(app.buttons["home-clear-search"].waitForExistence(timeout: 5))
        XCTAssertFalse(host.exists)
        app.buttons["home-clear-search"].tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertTrue(host.staticTexts["Connected"].exists, "Filtering must not disconnect a hidden session")
        search.tap()
        search.typeText("review")
        host.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Review SSH")
        submit("second input", in: app)
        try await assertReceipt(receiptURL, equals: firstInput + framedInput("second input"))
        hideKeyboard(app)
        capture(app, name: "ssh-saved-host-reopened")

        showHome(app, host: host)
        XCTAssertEqual(search.value as? String, "review", "Returning from a terminal keeps the host search")
        let disconnect = app.buttons["disconnect-host-\(id)"]
        pressForMenu(host, until: disconnect)
        disconnect.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5), "Disconnect must preserve the saved host")
        let settled = expectation(for: NSPredicate { _, _ in
            host.isEnabled && !host.staticTexts["Connected"].exists
        }, evaluatedWith: nil)
        await fulfillment(of: [settled], timeout: 10)
        capture(app, name: "ssh-saved-host-disconnected")
        pressForMenu(host, until: app.buttons["编辑主机"])
        XCTAssertFalse(disconnect.exists, "Disconnect must release the host's live session")
        XCTAssertTrue(app.buttons["删除主机"].exists)
    }

    @MainActor
    private func submit(_ draft: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        let send = app.buttons["conversation-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        send.tap()
    }

    private func framedInput(_ draft: String) -> [Int] {
        Array(("\u{1b}[200~" + draft + "\u{1b}[201~\r").utf8).map(Int.init)
    }

    private func resetReceipt(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func assertReceipt(_ url: URL, equals expected: [Int]) async throws {
        var received: [Int] = []
        for _ in 0..<100 {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            received = try XCTUnwrap(receipt["bytes"] as? [Int])
            if received.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(received, expected, "Navigation must preserve input delivery without replaying prior text")
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            app.buttons["conversation-keyboard-toggle"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func showHome(_ app: XCUIApplication, host: XCUIElement) {
        if app.buttons["terminal-back"].exists {
            app.buttons["terminal-back"].tap()
        } else if !host.isHittable {
            app.buttons["terminal-sidebar"].tap()
        }
        // A retained native search replaces the navigation toolbar while it is
        // active. The host list and its search field identify this destination.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(host.waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
