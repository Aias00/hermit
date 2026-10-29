import XCTest

/// A real Herdr connection publishes its own ActivityKit content. This uses
/// only terminal-session-fixture.py's private loopback SSH/Herdr lab. An explicit
/// native agent report models a blocked task; no Codex process or user task is
/// running, and no ActivityKit payload or app connection state is injected.
final class HerdrConnectionLiveActivityUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRealHerdrActivityShowsWorkspaceAndReturnsToSameShell() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This fixture resets saved hosts; use a dedicated simulator only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard let key = env["MOSHPIT_SEED_KEY_B64"], !key.isEmpty,
              let directory = env["MOSHPIT_SWITCH_FIXTURE_DIR"],
              directory.hasPrefix("/private/tmp/moshpit-ui-lab") || directory.hasPrefix("/tmp/moshpit-ui-lab"),
              let herdr = env["MOSHPIT_SEED_HERDR_BIN"],
              URL(fileURLWithPath: herdr).deletingLastPathComponent().standardizedFileURL
                == URL(fileURLWithPath: directory).standardizedFileURL else {
            throw XCTSkip("Requires the isolated terminal-session-fixture.py runner")
        }
        let app = XCUIApplication()
        let id = "6ECBFE35-07F6-4189-BABC-C5CA903DC9D9"
        let alias = "Herdr Activity Lab"
        let reportSource = "moshpit-ui-activity-\(UUID().uuidString)"
        let receipt = URL(fileURLWithPath: directory)
            .appendingPathComponent("activity-shell-\(UUID().uuidString).txt")
        let agentReceipt = receipt.appendingPathExtension("agent")
        app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "1",
            "-MOSHPIT_SEED_USER", try XCTUnwrap(env["MOSHPIT_SEED_USER"]),
            "-MOSHPIT_SEED_HOST", "127.0.0.1",
            "-MOSHPIT_SEED_PORT", try XCTUnwrap(env["MOSHPIT_SEED_PORT"]),
            "-MOSHPIT_SEED_TRUST_FP", try XCTUnwrap(env["MOSHPIT_SEED_TRUST_FP"]),
            "-MOSHPIT_SEED_NAME", alias, "-MOSHPIT_SEED_ID", id,
            "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_SEED_QUIET", "1",
            "-MOSHPIT_SEED_MUX", "herdr", "-MOSHPIT_SEED_HERDR_BIN", herdr,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { @MainActor in
            defer {
                app.terminate()
                try? FileManager.default.removeItem(at: receipt)
                try? FileManager.default.removeItem(at: agentReceipt)
            }
            // Retry cleanup through the same fixture connection if a later UI
            // assertion failed before the normal release. The receipt is unique
            // to this run and is written before reporting the native state.
            guard let paneID = try? String(contentsOf: agentReceipt, encoding: .utf8)
                .split(separator: "\n").first.map(String.init), !paneID.isEmpty else { return }
            app.activate()
            let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
            if field.waitForExistence(timeout: 10) {
                try? await self.submit(self.releaseCommand(herdr: herdr, paneID: paneID, source: reportSource), in: app)
            }
        }

        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        app.buttons["home-settings"].tap()
        for identifier in ["settings-live-activity", "settings-live-activity-host-names"] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(app.reveal(toggle))
            if toggle.value as? String == "0" { toggle.tap() }
        }
        let done = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let host = app.buttons["connection-card-\(alias)"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        XCTAssertTrue(app.buttons["conversation-menu"].waitForExistence(timeout: 30))
        let controlReady = expectation(for: NSPredicate(format: "enabled == true"),
                                       evaluatedWith: app.buttons["conversation-sidebar"])
        await fulfillment(of: [controlReady], timeout: 30)

        let location = app.descendants(matching: .any).matching(identifier: "terminal-location").firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10))
        let workspaceReady = expectation(for: NSPredicate(format: "label CONTAINS %@", "ui-lab"),
                                        evaluatedWith: location)
        await fulfillment(of: [workspaceReady], timeout: 15)
        let originalLocation = location.label
        try await submit("printf 'before:%s\\n' \"$$\" >> \(quote(receipt.path))", in: app)
        try await waitForReceipt(receipt, containing: "before:")
        let paneQuery = "import json,sys; print(json.load(sys.stdin)['result']['snapshot']['focused_pane_id'])"
        let report = "moshpit_activity_pane=\"$(\(quote(herdr)) api snapshot | /usr/bin/python3 -c \(quote(paneQuery)))\"; "
            + "test -n \"$moshpit_activity_pane\" && "
            + "printf '%s\\n' \"$moshpit_activity_pane\" > \(quote(agentReceipt.path)) && "
            + "\(quote(herdr)) pane report-agent \"$moshpit_activity_pane\" "
            + "--source \(quote(reportSource)) --agent codex --state blocked --seq 1 && "
            + "printf 'reported\\n' >> \(quote(agentReceipt.path))"
        try await submit(report, in: app)
        try await waitForReceipt(agentReceipt, containing: "reported\n")
        let paneID = try XCTUnwrap(String(contentsOf: agentReceipt, encoding: .utf8)
            .split(separator: "\n").first.map(String.init))
        hideKeyboard(app)
        // Let Herdr's normal snapshot cadence (up to 8 seconds at idle) and
        // ActivityKit's foreground sampler observe the native blocked report.
        try await Task.sleep(for: .seconds(12))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        openNotificationCenter(springboard)
        let card = activityCard(in: springboard)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Real Herdr must publish a system Live Activity")
        allowActivityIfOffered(in: springboard)
        let contentReady = expectation(for: NSPredicate { _, _ in
            let labels = self.labels(in: card)
            return labels.contains(alias) && labels.contains("ui-lab") && labels.contains("SSH")
                && labels.contains("Codex")
                // The system widget uses SpringBoard's language, independently
                // of the foreground app's English test launch arguments.
                && ["Waiting for you", "等待你的操作"].contains(where: labels.contains)
                && ["1 needs attention", "1 项待处理", "1 項待處理"].contains(where: labels.contains)
        }, evaluatedWith: card)
        await fulfillment(of: [contentReady], timeout: 15)
        let labels = labels(in: card)
        XCTAssertFalse(labels.contains("127.0.0.1"), "The connection address must stay off the lock screen")
        XCTAssertFalse(labels.contains(directory), "The fixture's full working path must stay off the lock screen")
        capture(springboard, name: "herdr-live-activity-background-native-attention")
        card.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let title = app.staticTexts["terminal-host-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, alias)
        XCTAssertTrue(location.waitForExistence(timeout: 10))
        let restored = expectation(for: NSPredicate(format: "label == %@", originalLocation),
                                   evaluatedWith: location)
        await fulfillment(of: [restored], timeout: 20)
        let release = releaseCommand(herdr: herdr, paneID: paneID, source: reportSource)
            + " && rm -f \(quote(agentReceipt.path))"
            + " && printf 'returned:%s\\n' \"$$\" >> \(quote(receipt.path))"
        try await submit(release, in: app)
        try await waitForReceipt(receipt, containing: "returned:")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentReceipt.path),
                       "The native fixture agent report must be released before continuing")
        let lines = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Each submitted command must run exactly once")
        XCTAssertEqual(lines.first?.split(separator: ":").last,
                       lines.last?.split(separator: ":").last,
                       "Tapping the card must return to the same persistent Herdr shell")
        hideKeyboard(app)
        capture(app, name: "herdr-live-activity-returned-to-same-shell")

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
                      "Disconnecting the fixture must end its activity")
        app.activate()
        #endif
    }

    @MainActor
    private func submit(_ command: String, in app: XCUIApplication) async throws {
        let field = app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(command)
        XCTAssertEqual(field.value as? String, command)
        let send = app.buttons["conversation-send"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        await fulfillment(of: [enabled], timeout: 30)
        send.tap()
        let cleared = expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true },
                                  evaluatedWith: field)
        await fulfillment(of: [cleared], timeout: 15)
    }

    @MainActor
    private func waitForReceipt(_ url: URL, containing text: String) async throws {
        let received = expectation(for: NSPredicate { _, _ in
            (try? String(contentsOf: url, encoding: .utf8).contains(text)) == true
        }, evaluatedWith: nil)
        await fulfillment(of: [received], timeout: 20)
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            app.buttons["conversation-keyboard-toggle"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func openNotificationCenter(_ springboard: XCUIApplication) {
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
    private func labels(in element: XCUIElement) -> String {
        ([element.label] + element.descendants(matching: .any).allElementsBoundByIndex.map(\.label))
            .joined(separator: " ")
    }

    @MainActor
    private func allowActivityIfOffered(in springboard: XCUIApplication) {
        for title in ["Always Allow", "始终允许", "一律允許", "Allow", "允许", "允許"] {
            let allow = springboard.buttons[title].firstMatch
            if allow.exists && allow.isHittable { allow.tap(); return }
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func releaseCommand(herdr: String, paneID: String, source: String) -> String {
        "\(quote(herdr)) pane release-agent \(quote(paneID)) "
            + "--source \(quote(source)) --agent codex --seq 2"
    }
}
