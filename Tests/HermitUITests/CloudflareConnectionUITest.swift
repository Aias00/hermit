import XCTest

/// The same saved-connection workflow runs on phone and iPad. This test never
/// taps Login or Connect: reserved .invalid hosts and an empty credential store
/// keep it independent of an Access account, a real Tunnel, or a running sshd.
final class CloudflareConnectionUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private var capturesDisabled: Bool {
        ProcessInfo.processInfo.environment["MOSHPIT_CF_LIVE_CAPTURE_DISABLED"] == "1"
    }

    @MainActor
    private func transportPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["connection-transport-picker"].firstMatch
    }

    /// A sheet's usable form area ends ABOVE the software keyboard/accessory.
    /// Whole-app swipes jumped over the picker, then kept scrolling in the
    /// wrong direction once it was below the keyboard. Small drags use the
    /// target's current frame and stay inside the form on phone and iPad.
    @MainActor
    private func revealInForm(_ element: XCUIElement, in app: XCUIApplication,
                              initiallyTowardTop: Bool = false) -> Bool {
        var towardTop = initiallyTowardTop
        // Check once more after the final drag before reporting a failure.
        for attempt in 0...24 {
            let navigation = app.navigationBars["新建 Host"].exists
                ? app.navigationBars["新建 Host"] : app.navigationBars["编辑 Host"]
            let form = app.collectionViews.firstMatch
            var area = (form.exists ? form.frame : app.frame).intersection(app.frame)
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
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty, area.contains(CGPoint(x: frame.midX, y: frame.midY)),
                   element.isHittable || !element.isEnabled { return true }
                towardTop = frame.midY < area.midY
                distance = min(distance, max(60, abs(frame.midY - area.midY)))
            } else if attempt == 8 || attempt == 16 {
                towardTop.toggle() // Lazy rows may not have frames until approached.
            }
            if attempt == 24 { break }
            let x = area.minX + area.width * 0.7
            let startY = towardTop ? area.minY + area.height * 0.25 : area.minY + area.height * 0.75
            let endY = startY + (towardTop ? distance : -distance)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x, dy: startY)).press(
                forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)))
        }
        recordFailureEvidence(app, name: "cloudflare-form-lookup-failure")
        return false
    }

    @MainActor
    private func choose(_ label: String, using picker: XCUIElement, in app: XCUIApplication,
                        initiallyTowardTop: Bool = false) {
        XCTAssertTrue(revealInForm(picker, in: app, initiallyTowardTop: initiallyTowardTop))
        picker.tap()
        let choice = app.buttons[label].firstMatch
        if choice.waitForExistence(timeout: 2) {
            choice.tap()
        } else {
            let text = app.staticTexts[label].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 2))
            text.tap()
        }
    }

    @MainActor
    private func chooseTransport(_ label: String, in app: XCUIApplication) {
        choose(label, using: transportPicker(app), in: app, initiallyTowardTop: true)
    }

    @MainActor
    private func fill(_ identifier: String, with value: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        guard tapField(field, in: app) else { return }
        field.typeText(value)
        assertField(identifier, equals: value, in: app)
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, matching predicate: NSPredicate,
                         timeout: TimeInterval = 3) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                       timeout: timeout) == .completed
    }

    @MainActor
    private func tapField(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        guard revealInForm(field, in: app) else {
            XCTFail("Missing text field: \(field.identifier)")
            return false
        }
        // Hit the editable area directly. XCUIElement.debugDescription does
        // not reliably expose keyboard focus; the exact post-input value is
        // the assertion that verifies input reached this field.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        return true
    }

    @MainActor
    private func assertField(_ identifier: String, equals expected: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(revealInForm(field, in: app))
        let matches = waitFor(field, matching: NSPredicate(format: "value == %@", expected))
        if !matches { recordFailureEvidence(app, name: "cloudflare-field-value-failure") }
        XCTAssertTrue(matches, "\(identifier): expected \(expected), got \(field.value as? String ?? "nil")")
    }

    @MainActor
    private func assertEmptyField(_ identifier: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(revealInForm(field, in: app))
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue,
                      "An automatic connection must not persist an explicit hostname override")
    }

    @MainActor
    private func expandCloudflareAdvanced(in app: XCUIApplication) {
        // A DisclosureGroup-level identifier overrides its child controls on
        // iOS. Match the disclosure's own button label; fields keep their IDs.
        let advanced = app.buttons.matching(NSPredicate(
            format: "label == %@", "高级 Cloudflare 配置")).firstMatch
        XCTAssertTrue(revealInForm(advanced, in: app))
        if !app.textFields["cloudflare-hostname"].firstMatch.exists {
            advanced.tap()
        }
        XCTAssertTrue(app.textFields["cloudflare-hostname"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    @MainActor
    private func saveAndWaitForDismissal(_ app: XCUIApplication, name: String) {
        let navigation = app.navigationBars["新建 Host"].exists
            ? app.navigationBars["新建 Host"] : app.navigationBars["编辑 Host"]
        XCTAssertTrue(navigation.exists)
        let save = app.buttons["save-connection"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        // On iPad the existing Home card remains in the AX tree behind the
        // editor. It cannot prove that this save completed before termination.
        let dismissed = waitFor(navigation, matching: NSPredicate(format: "exists == false"), timeout: 5)
        if !dismissed { recordFailureEvidence(app, name: "cloudflare-save-dismissal-failure") }
        XCTAssertTrue(dismissed, "Saving must finish and dismiss the editor before relaunch")
        XCTAssertTrue(app.buttons["connection-card-\(name)"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func enableManualAccess(in app: XCUIApplication) {
        let manual = app.switches["cloudflare-manual-access-toggle"].firstMatch
        XCTAssertTrue(revealInForm(manual, in: app))
        XCTAssertEqual(manual.value as? String, "0")
        // SwiftUI may expose the complete labelled row as the Switch frame;
        // hit the trailing native switch instead of the row's label/center.
        manual.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let enabled = waitFor(manual, matching: NSPredicate(format: "value == %@", "1"))
        if !enabled { recordFailureEvidence(app, name: "cloudflare-manual-toggle-failure") }
        XCTAssertTrue(enabled, "The manual Access switch must actually become enabled")
        let save = app.buttons["save-connection"].firstMatch
        let invalid = waitFor(save, matching: NSPredicate(format: "enabled == false"))
        if !invalid { recordFailureEvidence(app, name: "cloudflare-manual-validation-failure") }
        XCTAssertTrue(invalid, "Explicit manual configuration requires both team and audience")
    }

    @MainActor
    private func openEditor(for name: String, in app: XCUIApplication) {
        let host = app.buttons["connection-card-\(name)"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertTrue(app.reveal(host))
        let edit = app.buttons["编辑主机"].firstMatch
        pressForMenu(host, until: edit)
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑 Host"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        guard !capturesDisabled else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func recordFailureEvidence(_ app: XCUIApplication, name: String) {
        // This suite uses synthetic .invalid hosts, resets credentials, and
        // never logs in. Keep its AX evidence even when screenshots are off.
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        attach(app, name: name)
    }

    @MainActor
    func testHostnameOnlyConfigurationPersistsAndFollowsEditedHost() throws {
        let name = "CF Auto \(UUID().uuidString.prefix(6))"
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        app.buttons["home-add"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 3))
        fill("Name", with: name, in: app)
        fill("Host", with: "ssh.first.invalid", in: app)
        chooseTransport("Cloudflare SSH (Experimental)", in: app)

        let login = app.buttons["cloudflare-access-login"].firstMatch
        XCTAssertTrue(revealInForm(login, in: app))
        XCTAssertTrue(login.isEnabled, "A hostname alone enables explicit Access login")
        XCTAssertFalse(app.textFields["cloudflare-hostname"].exists)
        XCTAssertFalse(app.textFields["cloudflare-team-domain"].exists)
        XCTAssertFalse(app.textFields["cloudflare-audience"].exists)
        XCTAssertFalse(app.buttons["cloudflare-access-sign-out"].exists)
        XCTAssertFalse(app.staticTexts["cloudflare-access-error"].exists)
        XCTAssertTrue(app.staticTexts["cloudflare-experimental-notice"].exists)
        XCTAssertTrue(app.buttons["save-connection"].isEnabled,
                      "Saving an automatic connection must not require discovery or login")
        XCTAssertEqual(app.webViews.count, 0)
        attach(app, name: "cloudflare-hostname-only-without-login")
        saveAndWaitForDismissal(app, name: name)
        relaunch(app)

        openEditor(for: name, in: app)
        assertField("Host", equals: "ssh.first.invalid", in: app)
        XCTAssertFalse(app.textFields["cloudflare-hostname"].exists,
                       "Automatic configuration should reopen with advanced settings collapsed")
        let host = app.textFields["Host"].firstMatch
        // These short fixture hosts fit in the field. Tap after the existing
        // text so deletion starts at its end, without keyboard menu assumptions.
        guard tapField(host, in: app) else { return }
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "ssh.first.invalid".count)
                      + "ssh.second.invalid")
        assertField("Host", equals: "ssh.second.invalid", in: app)
        XCTAssertTrue(app.buttons["save-connection"].isEnabled)
        saveAndWaitForDismissal(app, name: name)
        relaunch(app)

        openEditor(for: name, in: app)
        assertField("Host", equals: "ssh.second.invalid", in: app)
        expandCloudflareAdvanced(in: app)
        assertEmptyField("cloudflare-hostname", in: app)
        let manual = app.switches["cloudflare-manual-access-toggle"].firstMatch
        XCTAssertTrue(revealInForm(manual, in: app))
        XCTAssertEqual(manual.value as? String, "0")
        XCTAssertFalse(app.textFields["cloudflare-team-domain"].exists)
        XCTAssertFalse(app.textFields["cloudflare-audience"].exists)
        XCTAssertTrue(revealInForm(login, in: app))
        XCTAssertTrue(login.isEnabled)
        XCTAssertFalse(app.buttons["cloudflare-access-sign-out"].exists)
        XCTAssertFalse(app.staticTexts["cloudflare-access-error"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        attach(app, name: "cloudflare-automatic-host-edit-restored")
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
    }

    @MainActor
    func testCloudflareConfigurationPersistsAndDirectNeedsNoLogin() throws {
        let name = "CF Config \(UUID().uuidString.prefix(6))"
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        app.buttons["home-add"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 3))
        fill("Name", with: name, in: app)
        fill("Host", with: "logical-host.invalid", in: app)
        fill("Username", with: "fixture-user", in: app)

        // The primary protocol picker uses the same binding as the advanced
        // Mosh switch, without the DisclosureGroup's inherited identifier.
        let protocolPicker = app.buttons["connection-protocol-picker"].firstMatch
        choose("Mosh", using: protocolPicker, in: app)
        XCTAssertTrue(protocolPicker.isEnabled)
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("Mosh"))

        chooseTransport("Cloudflare SSH (Experimental)", in: app)
        XCTAssertTrue(app.buttons["save-connection"].isEnabled)
        expandCloudflareAdvanced(in: app)
        fill("cloudflare-hostname", with: "ssh.fixture.invalid", in: app)
        let manual = app.switches["cloudflare-manual-access-toggle"].firstMatch
        enableManualAccess(in: app)
        fill("cloudflare-team-domain", with: "ui-fixture-team.cloudflareaccess.com", in: app)
        fill("cloudflare-audience", with: "fixture-aud_123", in: app)
        let login = app.buttons["cloudflare-access-login"].firstMatch
        XCTAssertTrue(revealInForm(login, in: app))
        XCTAssertTrue(login.isEnabled, "Login becomes available only once the application fields validate")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cloudflare-access-account").firstMatch.exists)
        XCTAssertTrue(app.staticTexts["cloudflare-experimental-notice"].exists)
        XCTAssertTrue(app.buttons["save-connection"].isEnabled, "Saving configuration must not initiate or require browser login")
        attach(app, name: "cloudflare-configured-without-login")
        XCTAssertTrue(revealInForm(protocolPicker, in: app, initiallyTowardTop: true))
        XCTAssertFalse(protocolPicker.isEnabled)
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("SSH"))
        saveAndWaitForDismissal(app, name: name)
        relaunch(app)

        openEditor(for: name, in: app)
        assertField("Host", equals: "logical-host.invalid", in: app)
        assertField("cloudflare-hostname", equals: "ssh.fixture.invalid", in: app)
        assertField("cloudflare-team-domain", equals: "ui-fixture-team.cloudflareaccess.com", in: app)
        assertField("cloudflare-audience", equals: "fixture-aud_123", in: app)
        XCTAssertTrue(revealInForm(manual, in: app, initiallyTowardTop: true))
        XCTAssertEqual(manual.value as? String, "1", "Saved manual configuration must reopen expanded")
        XCTAssertTrue(revealInForm(login, in: app))
        XCTAssertTrue(login.isEnabled)
        XCTAssertEqual(app.webViews.count, 0, "Opening a saved Cloudflare connection's settings must not open a login page")
        attach(app, name: "cloudflare-config-restored")

        chooseTransport("Direct", in: app)
        XCTAssertFalse(login.exists)
        XCTAssertFalse(app.textFields["cloudflare-hostname"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.navigationBars["编辑 Host"].exists)
        XCTAssertTrue(revealInForm(protocolPicker, in: app, initiallyTowardTop: true))
        XCTAssertTrue(protocolPicker.isEnabled, "Direct restores the user's ability to choose Mosh")
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("SSH"),
                      "Switching transport does not silently re-enable Mosh")
        choose("Mosh", using: protocolPicker, in: app)
        XCTAssertTrue((protocolPicker.label + " " + (protocolPicker.value as? String ?? "")).contains("Mosh"))
        saveAndWaitForDismissal(app, name: name)

        // Relaunch without RESET to verify disk persistence, not only sheet
        // state, and reopen by Edit so no SSH connection is attempted.
        relaunch(app)
        openEditor(for: name, in: app)
        let picker = transportPicker(app)
        XCTAssertTrue(revealInForm(picker, in: app))
        let displayed = picker.label + " " + (picker.value as? String ?? "")
        XCTAssertTrue(displayed.contains("Direct"), "The saved transport should remain Direct: \(displayed)")
        XCTAssertFalse(login.exists)
        XCTAssertEqual(app.webViews.count, 0)
        attach(app, name: "direct-restored-without-login")
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
    }
}
