import XCTest

/// Exercises the new entry points without registering a node or changing a
/// real account. Account status may already be connected from a live test.
final class TailscaleConnectionUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let form = app.collectionViews.firstMatch
        var upward = false
        for attempt in 0...18 {
            if element.exists, element.isHittable { return true }
            if element.exists, !element.isEnabled, !element.frame.isEmpty,
               app.frame.intersection(form.frame).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return true }
            if attempt == 18 { break }
            if element.exists, !element.frame.isEmpty {
                upward = element.frame.midY < form.frame.midY
            } else if attempt == 9 {
                upward.toggle()
            }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: upward ? 0.3 : 0.78))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: upward ? 0.78 : 0.3))
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
