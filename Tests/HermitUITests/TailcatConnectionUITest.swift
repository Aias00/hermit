import XCTest

/// Entirely offline: this synthetic capability has a discarded server key and
/// an unreachable loopback relay. The test never taps Connect or starts a server.
final class TailcatConnectionUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let address = "tcpGFwWCDb2nZDdfCyf-JoBWk82g6ELtHcp4a8_rZAacgp_8UefWFrWCBKln9Xcu7pwVJ7nT3KimlFQdaNljoeWM9eavhBDR54QmFxWCDiHKAksV18j2Xd_FQ4q04MU1BsjiSIswRigQEQdxtGDGFygaFhToGlYWhpMTI3LjAuMC4xYTRpMTI3LjAuMC4xYXMgYWQJYXj1"

    @MainActor
    private func revealInForm(_ element: XCUIElement, in app: XCUIApplication,
                              initiallyTowardTop: Bool = false) -> Bool {
        var towardTop = initiallyTowardTop
        // Check once more after the final drag before reporting a failure.
        for attempt in 0...24 {
            let navigation = app.navigationBars["新建 Host"].exists
                ? app.navigationBars["新建 Host"] : app.navigationBars["编辑 Host"]
            let form = app.collectionViews.firstMatch
            guard form.exists else { return false }
            let formFrame = form.frame
            var area = formFrame.intersection(app.frame)
            if navigation.exists {
                let top = max(area.minY, navigation.frame.maxY + 10)
                area = CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
            }
            if app.keyboards.firstMatch.exists {
                // The input accessory is above the Keyboard AX element.
                let bottom = min(area.maxY, app.keyboards.firstMatch.frame.minY - 54)
                area.size.height = max(0, bottom - area.minY)
            }
            area = area.insetBy(dx: 12, dy: 10)
            guard area.height > 80, area.width > 80 else { break }
            var distance = min(area.height * 0.4, 180)
            // Existing lazy rows may have zero bounds; their midY cannot tell
            // us whether to scroll upward or downward.
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty {
                if area.contains(CGPoint(x: frame.midX, y: frame.midY)),
                   element.isHittable || !element.isEnabled { return true }
                towardTop = frame.midY < area.midY
                distance = min(distance, max(60, abs(frame.midY - area.midY)))
            } else if attempt == 8 || attempt == 16 {
                // Reverse only after searching a full stretch without bounds.
                towardTop.toggle()
            }
            if attempt == 24 { break }
            let x = area.minX + area.width * 0.7
            let startY = towardTop ? area.minY + area.height * 0.25 : area.minY + area.height * 0.75
            let endY = startY + (towardTop ? distance : -distance)
            // Target the form itself rather than the app's background/sidebar
            // beneath an iPad sheet. Offsets are local to its current frame.
            let origin = form.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x - formFrame.minX, dy: startY - formFrame.minY)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x - formFrame.minX, dy: endY - formFrame.minY)))
        }
        return false
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)],
                       timeout: timeout) == .completed
    }

    @MainActor
    private func choose(_ label: String, picker identifier: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier].firstMatch
        let choice = app.buttons[label].firstMatch
        let text = app.staticTexts[label].firstMatch
        for _ in 0..<2 {
            guard revealInForm(picker, in: app, initiallyTowardTop: true) else {
                XCTFail("Picker is not visible: \(identifier)")
                return
            }
            // SwiftUI reports the whole labelled row as the button's frame.
            // On iPad its empty center does not open the menu: hit the actual
            // trailing value / chevron, then verify a menu choice appeared.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            if waitFor(choice, "exists == true AND hittable == true", timeout: 2) {
                choice.tap()
                return
            }
            if waitFor(text, "exists == true AND hittable == true", timeout: 1) {
                text.tap()
                return
            }
        }
        XCTFail("Picker \(identifier) did not open its \(label) menu choice after two taps")
    }

    @MainActor
    private func fill(_ field: XCUIElement, _ value: String, in app: XCUIApplication) {
        XCTAssertTrue(revealInForm(field, in: app))
        // On iPad an empty SwiftUI field reports the entire row as its AX
        // frame, but the trailing blank area may leave the previous field
        // focused. Tap the visible placeholder and confirm focus before typing.
        for _ in 0..<2 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            if waitFor(field, "hasKeyboardFocus == true", timeout: 2) { break }
        }
        XCTAssertTrue(waitFor(field, "hasKeyboardFocus == true", timeout: 2))
        field.typeText(value)
    }

    @MainActor
    private func openEditor(_ name: String, in app: XCUIApplication) {
        let card = app.buttons["connection-card-\(name)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.reveal(card))
        let edit = app.buttons["编辑主机"].firstMatch
        pressForMenu(card, until: edit)
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑 Host"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func save(_ app: XCUIApplication, name: String) {
        let navigation = app.navigationBars["新建 Host"].exists
            ? app.navigationBars["新建 Host"] : app.navigationBars["编辑 Host"]
        let button = app.buttons["save-connection"].firstMatch
        XCTAssertTrue(waitFor(button, "enabled == true"))
        button.tap()
        XCTAssertTrue(waitFor(navigation, "exists == false", timeout: 10))
        XCTAssertTrue(app.buttons["connection-card-\(name)"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func clientPublicKey(in app: XCUIApplication) -> String {
        let key = app.staticTexts["tailcat-client-public-key"].firstMatch
        XCTAssertTrue(revealInForm(key, in: app))
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertTrue(key.label.hasPrefix("nodekey:"))
        return key.label
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        // This suite uses a disposable offline capability and fixture SSH
        // password only; no real server credentials or account data appear.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testInvalidAddressCannotBeSavedAndCancellationReturnsHome() throws {
        let app = XCUIApplication()
        let name = "Tailcat Offline " + UUID().uuidString.prefix(6)
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        app.buttons["home-add"].tap()
        fill(app.textFields["Name"].firstMatch, name, in: app)
        choose("Mosh", picker: "connection-protocol-picker", in: app)
        choose("Tailcat (Experimental)", picker: "connection-transport-picker", in: app)
        let protocolPicker = app.buttons["connection-protocol-picker"].firstMatch
        XCTAssertTrue(revealInForm(protocolPicker, in: app, initiallyTowardTop: true))
        XCTAssertFalse(protocolPicker.isEnabled)
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("SSH"))
        XCTAssertFalse(app.buttons["cloudflare-access-login"].exists)
        XCTAssertFalse(app.buttons["save-connection"].isEnabled)
        fill(app.secureTextFields["tailcat-address"].firstMatch, "tcINVALID_FIXTURE", in: app)
        XCTAssertFalse(app.buttons["save-connection"].isEnabled)
        let addressError = app.staticTexts["connection-transport-error"].firstMatch
        XCTAssertTrue(revealInForm(addressError, in: app))
        XCTAssertTrue(waitFor(addressError, "exists == true AND hittable == true"))
        app.navigationBars["新建 Host"].buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connection-card-\(name)"].exists)
    }

    @MainActor
    func testIndependentTransportPersistsSecretAndClientIdentity() throws {
        let app = XCUIApplication()
        let name = "Tailcat Offline " + UUID().uuidString.prefix(6)
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        // Validate persistence independently from the rejected-address flow.
        // Both paths still type through the real secure field and assert its
        // outcome; no seeded credential substitutes for user input.
        app.buttons["home-add"].tap()
        fill(app.textFields["Name"].firstMatch, name, in: app)
        fill(app.textFields["Username"].firstMatch, "fixture-user", in: app)
        choose("Tailcat (Experimental)", picker: "connection-transport-picker", in: app)
        let alias = app.textFields["tailcat-host-alias"].firstMatch
        XCTAssertTrue(revealInForm(alias, in: app, initiallyTowardTop: true))
        XCTAssertTrue((alias.value as? String ?? "").isEmpty || alias.value as? String == alias.placeholderValue)
        fill(app.secureTextFields["tailcat-address"].firstMatch, address, in: app)
        let originalPublicKey = clientPublicKey(in: app)
        let copy = app.buttons["tailcat-copy-client-key"].firstMatch
        XCTAssertTrue(revealInForm(copy, in: app))
        XCTAssertTrue(copy.isEnabled)
        fill(app.secureTextFields["Password"].firstMatch, "offline-ui-fixture-password", in: app)
        let experimentalNotice = app.staticTexts["tailcat-experimental-notice"].firstMatch
        XCTAssertTrue(revealInForm(experimentalNotice, in: app))
        XCTAssertTrue(waitFor(experimentalNotice, "exists == true AND hittable == true"))
        XCTAssertTrue(revealInForm(app.secureTextFields["tailcat-address"].firstMatch, in: app, initiallyTowardTop: true))
        XCTAssertTrue(waitFor(app.buttons["save-connection"].firstMatch, "enabled == true"))
        attach(app, name: "tailcat-config")
        save(app, name: name)

        app.terminate()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openEditor(name, in: app)
        let restoredAlias = app.textFields["tailcat-host-alias"].firstMatch
        XCTAssertTrue(revealInForm(restoredAlias, in: app, initiallyTowardTop: true))
        XCTAssertTrue((restoredAlias.value as? String ?? "").hasPrefix("tailcat-"))
        let secretField = app.secureTextFields["tailcat-address"].firstMatch
        XCTAssertTrue(revealInForm(secretField, in: app))
        let storedValue = secretField.value as? String ?? ""
        XCTAssertTrue(storedValue.isEmpty || storedValue == secretField.placeholderValue,
                      "An edited connection must not put the secret address back into the field")
        XCTAssertEqual(clientPublicKey(in: app), originalPublicKey)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(revealInForm(secretField, in: app, initiallyTowardTop: true))
        attach(app, name: "tailcat-edit")
        save(app, name: name) // Empty secret field preserves the existing identity.

        app.terminate()
        app.launch()
        openEditor(name, in: app)
        XCTAssertEqual(clientPublicKey(in: app), originalPublicKey)
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
        let card = app.buttons["connection-card-\(name)"].firstMatch
        let delete = app.buttons["删除主机"].firstMatch
        pressForMenu(card, until: delete)
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(waitFor(card, "exists == false", timeout: 10))
    }
}
