import XCTest

/// Offline traversal of settings and host forms. No feedback, voice recording,
/// model download or remote connection is submitted by these tests.
final class SettingsSwitchingUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws { XCUIApplication().terminate() }

    @MainActor
    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("-MOSHPIT_RESET") }
        app.launch()
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["home-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDisplayCursorAndBehaviorPersistAcrossRelaunch() throws {
        var app = launch()
        openSettings(app)
        let fontMenu = app.buttons["settings-font-menu"]
        tap(fontMenu, in: app)
        app.buttons["JetBrains Mono"].tap()
        XCTAssertTrue(fontMenu.label.contains("JetBrains Mono"))
        let size = app.sliders.firstMatch
        XCTAssertTrue(reveal(size, in: app))
        size.adjust(toNormalizedSliderPosition: 0.6)
        let sizeValue = size.value as? String
        tap(app.buttons["Bar"], in: app)
        XCTAssertTrue(app.buttons["Bar"].isSelected)
        tap(app.buttons["Underline"], in: app)
        XCTAssertTrue(app.buttons["Underline"].isSelected)

        let names = ["Blink", "Keep Connections Alive", "Remote Clipboard Read"]
        var original: [String: String] = [:]
        var changed: [String: String] = [:]
        for name in names {
            let toggle = app.switches[name]
            XCTAssertTrue(reveal(toggle, in: app))
            original[name] = toggle.value as? String
            toggle.tap()
            changed[name] = toggle.value as? String
            XCTAssertNotEqual(changed[name], original[name])
        }
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.terminate()
        app = launch(reset: false)
        openSettings(app)
        let persistedFontMenu = app.buttons["settings-font-menu"]
        XCTAssertTrue(reveal(persistedFontMenu, in: app))
        XCTAssertTrue(persistedFontMenu.label.contains("JetBrains Mono"))
        XCTAssertTrue(reveal(app.sliders.firstMatch, in: app))
        XCTAssertEqual(app.sliders.firstMatch.value as? String, sizeValue)
        XCTAssertTrue(reveal(app.buttons["Underline"], in: app))
        XCTAssertTrue(app.buttons["Underline"].isSelected)
        for name in names {
            let toggle = app.switches[name]
            XCTAssertTrue(reveal(toggle, in: app))
            XCTAssertEqual(toggle.value as? String, changed[name], "\(name) must survive app restart")
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, original[name])
        }
        capture("settings-display-cursor-behavior-persisted")
    }

    @MainActor
    func testVoiceChoicesAndMoshEditorsCanBeEnteredAndCancelled() throws {
        let app = launch()
        openSettings(app)
        let voice = app.switches["Enable Voice Input"]
        XCTAssertTrue(reveal(voice, in: app))
        if voice.value as? String == "0" { voice.tap() }
        tap(app.staticTexts["Recognition"], in: app)
        let whisper = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Whisper (local model)")).firstMatch
        XCTAssertTrue(whisper.waitForExistence(timeout: 5))
        whisper.tap()
        XCTAssertTrue(whisper.isSelected)
        back(from: "Recognition", in: app)
        tap(app.staticTexts["Language"], in: app)
        let english = app.buttons["English"].firstMatch
        XCTAssertTrue(reveal(english, in: app))
        english.tap()
        XCTAssertTrue(english.isSelected)
        back(from: "Voice Language", in: app)
        tap(app.staticTexts["Recognition"], in: app)
        let apple = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple (built in)")).firstMatch
        apple.tap()
        XCTAssertTrue(apple.isSelected)
        back(from: "Recognition", in: app)
        tap(app.staticTexts["Language"], in: app)
        let automatic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Automatic")).firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        automatic.tap()
        XCTAssertTrue(automatic.isSelected)
        back(from: "Voice Language", in: app)
        tap(app.staticTexts["Recognition"], in: app)
        whisper.tap()
        back(from: "Recognition", in: app)
        tap(app.staticTexts["Language"], in: app)
        XCTAssertTrue(reveal(english, in: app))
        XCTAssertTrue(english.isSelected, "Whisper and Apple retain independent language selections")
        back(from: "Voice Language", in: app)
        tap(app.staticTexts["Recognition"], in: app)
        apple.tap()
        back(from: "Recognition", in: app)

        tap(app.staticTexts["Server binary"], in: app, towardTop: true)
        XCTAssertTrue(app.navigationBars["Server Binary"].waitForExistence(timeout: 5))
        let binary = app.textFields.firstMatch
        let originalBinary = binary.value as? String
        fill(binary, with: "/test-cancelled", in: app)
        app.navigationBars["Server Binary"].buttons["Cancel"].tap()
        tap(app.staticTexts["Server binary"], in: app)
        XCTAssertEqual(app.textFields.firstMatch.value as? String, originalBinary)
        app.navigationBars["Server Binary"].buttons["Cancel"].tap()

        tap(app.staticTexts["UDP port range"], in: app)
        XCTAssertTrue(app.navigationBars["UDP Port Range"].waitForExistence(timeout: 5))
        let from = app.textFields.firstMatch
        let originalPort = from.value as? String
        fill(from, with: "9", in: app)
        app.navigationBars["UDP Port Range"].buttons["Cancel"].tap()
        tap(app.staticTexts["UDP port range"], in: app)
        XCTAssertEqual(app.textFields.firstMatch.value as? String, originalPort)
        app.navigationBars["UDP Port Range"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        capture("settings-voice-and-mosh-editor-round-trips")
    }

    @MainActor
    func testDiagnosticsAndFeedbackCanBeExitedWithoutSending() throws {
        let app = launch()
        openSettings(app)
        tap(app.staticTexts["Recent Log"], in: app)
        XCTAssertTrue(app.navigationBars["Recent Log"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Recent Log"].buttons["Copy"].exists)
        back(from: "Recent Log", in: app)
        tap(app.buttons["settings-feedback"], in: app)
        XCTAssertTrue(app.navigationBars["Feedback"].waitForExistence(timeout: 5))
        let send = app.buttons["feedback-send"]
        let message = app.descendants(matching: .any).matching(identifier: "feedback-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let initialMessage = message.value as? String ?? ""
        XCTAssertTrue(initialMessage.isEmpty || initialMessage == message.placeholderValue)
        // Feedback can contain only the selected environment/log details.
        // Opening the mail composer does not require a typed message.
        XCTAssertTrue(send.isEnabled)
        fill(message, with: "Local UI verification only; do not send.", in: app)
        XCTAssertTrue(send.isEnabled)
        for id in ["feedback-environment", "feedback-log"] {
            let toggle = app.switches[id]
            XCTAssertTrue(reveal(toggle, in: app))
            let initial = toggle.value as? String
            toggle.tap()
            XCTAssertNotEqual(toggle.value as? String, initial)
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, initial)
        }
        app.navigationBars["Feedback"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 5))
        capture("settings-diagnostics-feedback-cancelled")
    }

    @MainActor
    func testSOCKSAndDirectFormSwitchesPreserveSavedEndpoint() throws {
        let app = launch()
        app.buttons["home-add"].tap()
        XCTAssertTrue(app.navigationBars["新建 Host"].waitForExistence(timeout: 5))
        fill(app.textFields["Name"], with: "Offline SOCKS Switch", in: app)
        fill(app.textFields["Host"], with: "example.invalid", in: app)
        fill(app.textFields["Username"], with: "tester", in: app)
        chooseTransport("SOCKS5", in: app)
        let proxy = app.textFields["socks-proxy-host"]
        fill(proxy, with: "proxy.invalid", in: app)
        let port = app.textFields["socks-proxy-port"]
        XCTAssertTrue(reveal(port, in: app))
        XCTAssertEqual(port.value as? String, "1080")
        chooseTransport("Direct", in: app)
        XCTAssertFalse(proxy.exists)
        chooseTransport("SOCKS5", in: app)
        XCTAssertTrue(reveal(proxy, in: app))
        XCTAssertEqual(proxy.value as? String, "proxy.invalid")
        XCTAssertTrue(app.buttons["save-connection"].isEnabled)
        app.buttons["save-connection"].tap()
        openHostEditor(app)
        XCTAssertTrue(reveal(proxy, in: app))
        XCTAssertEqual(proxy.value as? String, "proxy.invalid")
        XCTAssertTrue(reveal(port, in: app))
        XCTAssertEqual(port.value as? String, "1080")
        chooseTransport("Direct", in: app)
        app.buttons["save-connection"].tap()
        openHostEditor(app)
        XCTAssertTrue(reveal(app.buttons["connection-transport-picker"], in: app))
        XCTAssertFalse(proxy.exists, "Direct remains selected after saving and reopening")
        chooseTransport("SOCKS5", in: app)
        XCTAssertTrue(reveal(proxy, in: app))
        XCTAssertEqual(proxy.value as? String, "proxy.invalid", "Inactive proxy metadata is retained")
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["connection-card-Offline SOCKS Switch"].waitForExistence(timeout: 5))
        capture("socks-direct-form-round-trips")
    }

    @MainActor
    private func openHostEditor(_ app: XCUIApplication) {
        let host = app.buttons["connection-card-Offline SOCKS Switch"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        let edit = app.buttons["编辑主机"]
        pressForMenu(host, until: edit)
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑 Host"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func chooseTransport(_ label: String, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let hide = keyboard.buttons.matching(NSPredicate(format: "label IN %@",
                ["Hide keyboard", "Dismiss keyboard", "Hide Keyboard", "隐藏键盘", "收起键盘"])).firstMatch
            if hide.exists && hide.isHittable {
                hide.tap()
                XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
            }
        }
        let picker = app.descendants(matching: .any).matching(identifier: "connection-transport-picker").firstMatch
        // System picker roles vary (Button, PopUpButton, MenuItem) between
        // phone and iPad. Match the actual visible option by its exact label.
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        for _ in 0..<2 {
            if choice.exists && choice.isHittable {
                choice.tap()
                return
            }
            XCTAssertTrue(reveal(picker, in: app, towardTop: true))
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let visible = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: choice)
            if XCTWaiter.wait(for: [visible], timeout: 5) == .completed {
                choice.tap()
                return
            }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "transport-picker-missing-\(label)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Transport picker did not open its \(label) menu choice")
    }

    @MainActor
    private func back(from title: String, in app: XCUIApplication) {
        app.navigationBars[title].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func fill(_ field: XCUIElement, with value: String, in app: XCUIApplication) {
        var focused = false
        for _ in 0..<2 {
            XCTAssertTrue(reveal(field, in: app))
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            let focus = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            if XCTWaiter.wait(for: [focus], timeout: 2) == .completed {
                focused = true
                break
            }
        }
        guard focused else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "form-field-focus-failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("The visible field must receive keyboard focus before typing")
            return
        }
        field.typeText(value)
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        XCTAssertTrue(reveal(element, in: app, towardTop: towardTop))
        element.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) -> Bool {
        var upward = towardTop
        for attempt in 0...28 {
            // A visible picker popup also contains a collection view. Keep
            // scrolling the host form, never that transient option list.
            let hostForm = app.collectionViews.containing(.any, identifier: "connection-transport-picker").firstMatch
            let form = hostForm.exists ? hostForm : app.collectionViews.firstMatch
            guard form.exists else { return false }
            var visible = form.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
            if app.keyboards.firstMatch.exists {
                visible.size.height = max(0, min(visible.maxY, app.keyboards.firstMatch.frame.minY - 54) - visible.minY)
            }
            guard visible.height > 70 else { return false }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty {
                // A row can be partly hittable while its coordinate-tap point
                // is still under the keyboard or the input accessory.
                if visible.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return true }
                upward = frame.midY < visible.midY
            }
            else if attempt == 12 { upward.toggle() }
            let x = visible.minX + 4 // Gutter avoids sliders and switches while scrolling.
            let fromY = visible.minY + visible.height * (upward ? 0.25 : 0.8)
            let toY = visible.minY + visible.height * (upward ? 0.8 : 0.25)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x, dy: fromY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: toY)))
        }
        return false
    }

    @MainActor
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
