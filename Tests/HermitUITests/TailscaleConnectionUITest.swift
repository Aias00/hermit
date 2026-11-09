import XCTest

/// Exercises the new entry points without registering a node or changing a
/// real account. Account status may already be connected from a live test.
final class TailscaleConnectionUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLocalAddressesCanBeConfiguredWithoutStartingLogin() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["home-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        choose("Tailscale (Experimental)", picker: "connection-transport-picker", in: app)
        let toggle = app.switches["connection-auto-local-toggle"].firstMatch
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        attach(app, name: "local-routing-enabled")
        let localHosts = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection-local-host-"))
        if !reveal(localHosts.firstMatch, in: app) {
            attach(app, name: "missing-local-address-field")
            XCTFail("local field is missing: \(app.debugDescription)")
            return
        }
        localHosts.firstMatch.tap()
        localHosts.firstMatch.typeText("192.168.1.10")
        let extra = app.buttons["connection-local-add"].firstMatch
        XCTAssertTrue(reveal(extra, in: app))
        extra.tap()
        XCTAssertEqual(localHosts.count, 2)
        attach(app, name: "automatic-lan-tailscale-addresses")
        XCTAssertFalse(app.webViews.firstMatch.exists, "editing local endpoints must not open login")
        XCTAssertTrue(reveal(toggle, in: app))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("0", of: toggle))
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: extra)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed,
                       "disabling the feature must hide automatic route controls")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("1", of: toggle))
        XCTAssertTrue(reveal(extra, in: app))
        XCTAssertEqual(localHosts.firstMatch.value as? String, "192.168.1.10", "temporarily disabling must retain the draft")
        let removeSecond = app.buttons.matching(NSPredicate(format: "label == %@", "移除此地址")).element(boundBy: 1)
        XCTAssertTrue(reveal(removeSecond, in: app))
        removeSecond.tap()
        XCTAssertEqual(localHosts.count, 1)
        XCTAssertEqual(localHosts.firstMatch.value as? String, "192.168.1.10", "removing another endpoint must retain the first address")
    }

    @MainActor private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let form = app.collectionViews.firstMatch
        var upward = false
        for attempt in 0...18 {
            var viewport = app.frame.intersection(form.frame)
            let navigationBar = app.navigationBars.firstMatch
            if navigationBar.exists {
                let top = max(viewport.minY, navigationBar.frame.maxY + 4)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(120, viewport.maxY - top))
            }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { viewport.size.height = max(120, min(viewport.height, keyboard.frame.minY - viewport.minY)) }
            if element.exists, element.isHittable,
               viewport.insetBy(dx: 0, dy: 5).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return true }
            if element.exists, !element.isEnabled, !element.frame.isEmpty,
               viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return true }
            if attempt == 18 { break }
            if element.exists, !element.frame.isEmpty {
                upward = element.frame.midY < viewport.midY
            } else if attempt == 9 {
                upward.toggle()
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + 12, dy: viewport.minY + viewport.height * (upward ? 0.3 : 0.78)))
            let end = origin.withOffset(CGVector(dx: viewport.minX + 12, dy: viewport.minY + viewport.height * (upward ? 0.78 : 0.3)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return false
    }

    @MainActor private func choose(_ value: String, picker identifier: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier].firstMatch
        XCTAssertTrue(reveal(picker, in: app))
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let choice = app.buttons[value].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testTailscaleTransportAndAccountManagementEntryPoints() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["home-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        choose("Mosh", picker: "connection-protocol-picker", in: app)
        choose("Tailscale (Experimental)", picker: "connection-transport-picker", in: app)
        let protocolPicker = app.buttons["connection-protocol-picker"].firstMatch
        XCTAssertTrue(reveal(protocolPicker, in: app))
        XCTAssertFalse(protocolPicker.isEnabled)
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("SSH"))
        let manage = app.buttons["tailscale-manage-account"].firstMatch
        XCTAssertTrue(reveal(manage, in: app))
        XCTAssertFalse(app.buttons["cloudflare-access-login"].exists)
        XCTAssertFalse(app.secureTextFields["tailcat-address"].exists)
        attach(app, name: "tailscale-connection-form")
        manage.tap()
        XCTAssertTrue(app.navigationBars["Tailscale"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tailscale-account-status"].firstMatch.exists)
        attach(app, name: "tailscale-account-management")
        app.navigationBars["Tailscale"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 5))
        app.navigationBars["新建 Host"].buttons["Cancel"].tap()

        app.buttons["home-settings"].tap()
        let settingsEntry = app.buttons["settings-tailscale"].firstMatch
        XCTAssertTrue(reveal(settingsEntry, in: app))
        settingsEntry.tap()
        XCTAssertTrue(app.navigationBars["Tailscale"].waitForExistence(timeout: 5))
        app.navigationBars["Tailscale"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}
