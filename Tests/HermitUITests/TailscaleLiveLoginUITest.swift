import XCTest

/// Explicitly enabled only for an attended login. The login URL is copied on
/// request to the simulator clipboard, never printed or placed in an AX dump.
final class TailscaleLiveLoginUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["MOSHPIT_TAILSCALE_LIVE_LOGIN"] == "1" else {
            throw XCTSkip("Set MOSHPIT_TAILSCALE_LIVE_LOGIN=1 for an attended real account login.")
        }
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let form = app.collectionViews.firstMatch
        var towardTop = false
        for attempt in 0..<20 {
            if element.exists, element.isHittable { return true }
            if element.exists, !element.frame.isEmpty { towardTop = element.frame.midY < form.frame.midY }
            else if attempt == 10 { towardTop.toggle() }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardTop ? 0.28 : 0.8))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardTop ? 0.8 : 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists && element.isHittable
    }

    @MainActor private func connected(_ app: XCUIApplication) -> Bool {
        let status = app.descendants(matching: .any)["tailscale-account-status"].firstMatch
        guard status.exists else { return false }
        return (status.label + " " + (status.value as? String ?? "")).contains("Connected")
            || app.staticTexts["Connected"].firstMatch.exists
    }

    @MainActor private func waitUntilConnected(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in connected(app) }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func testAttendedLoginKeepsTheAppAliveForRemoteBrowserAuthentication() throws {
        executionTimeAllowance = 780
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 10))
        app.buttons["home-add"].tap()
        let transport = app.buttons["connection-transport-picker"].firstMatch
        XCTAssertTrue(reveal(transport, in: app))
        transport.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let choice = app.buttons["Tailscale (Experimental)"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
        let manage = app.buttons["tailscale-manage-account"].firstMatch
        XCTAssertTrue(reveal(manage, in: app))
        manage.tap()
        XCTAssertTrue(app.navigationBars["Tailscale"].waitForExistence(timeout: 5))
        if !waitUntilConnected(app, timeout: 8) {
            // An existing unfinished login may already have a valid URL. Both
            // paths require this explicit test action to show the browser.
            let signIn = app.buttons["tailscale-login"].firstMatch
            let openLogin = app.buttons["tailscale-open-login"].firstMatch
            if signIn.exists {
                XCTAssertTrue(reveal(signIn, in: app))
                signIn.tap()
            } else {
                XCTAssertTrue(reveal(openLogin, in: app))
                openLogin.tap()
            }
            let browser = app.descendants(matching: .any)["tailscale-login-browser"].firstMatch
            XCTAssertTrue(browser.waitForExistence(timeout: 45), "The explicitly requested login should open the system browser")
            if let directory = ProcessInfo.processInfo.environment["MOSHPIT_TAILSCALE_CAPTURE_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let path = destination.appendingPathComponent("browser.png")
                try app.screenshot().pngRepresentation.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            // Safari's remote view uses the simulator's system language,
            // independently of the host app's AppleLanguages launch argument.
            let doneButtons = app.buttons.matching(NSPredicate(format: "label IN {'Done', '完成', 'Close', '关闭'}"))
            let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            let safariDone = safari.buttons.matching(NSPredicate(format: "label IN {'Done', '完成', 'Close', '关闭'}"))
            let visibleDone: () -> XCUIElement? = {
                doneButtons.allElementsBoundByIndex.first(where: { $0.isHittable })
                    ?? safariDone.allElementsBoundByIndex.first(where: { $0.isHittable })
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visibleDone() != nil }, object: nil)
            if XCTWaiter.wait(for: [ready], timeout: 5) == .completed, let done = visibleDone() {
                done.tap()
            } else {
                // The presentation is a normal dismissible sheet. New OS
                // versions can expose its close control through a remote
                // accessibility process, so use the standard pull-down gesture.
                browser.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).press(
                    forDuration: 0.1,
                    thenDragTo: browser.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            }
            XCTAssertTrue(app.navigationBars["Tailscale"].waitForExistence(timeout: 5))
            if !connected(app) {
                let copy = app.buttons["tailscale-copy-login"].firstMatch
                XCTAssertTrue(reveal(copy, in: app))
                copy.tap()
                // The coordinator can read simctl pbpaste and provide the
                // one-time URL privately while this process keeps polling.
                let deadline = Date().addingTimeInterval(600)
                while !connected(app), Date() < deadline {
                    if waitUntilConnected(app, timeout: max(0.1, min(10, deadline.timeIntervalSinceNow))) { break }
                }
            }
        }
        XCTAssertTrue(connected(app), "Complete the attended login in a browser within ten minutes")
        let refresh = app.buttons["tailscale-settings-refresh-peers"].firstMatch
        XCTAssertTrue(reveal(refresh, in: app), "Connected accounts expose the visible-device section")
        let peer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tailscale-visible-peer-'" )).firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 5), "This live fixture expects at least one visible tailnet device")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "tailscale-live-account-connected"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Deliberately keep the authenticated node and saved account. No
        // logout, test reset, temporary key, or credential bypass is involved.
    }
}
