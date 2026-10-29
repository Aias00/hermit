import XCTest

/// Offline settings and recording-review checks on a dedicated simulator.
/// The key is deliberately invalid; no test submits it or audio to a provider.
/// Recording uses the existing scripted recognizer and PCM source, never the
/// simulator microphone or an external speech service.
final class CloudVoiceUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("These tests clear saved hosts and use a fake voice key; use a dedicated simulator")
        #endif
    }

    @MainActor
    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    @MainActor
    func testLocalRecognitionTestNeedsNoHostAndDoesNotSelectCloud() throws {
        let app = launch()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "connection-card-")).count, 0)
        openSettings(app)
        openRecognition(app)
        selectEngine("apple", in: app)
        back(in: app)

        tap(element("settings-voice-test", in: app), in: app)
        let engine = element("voice-test-engine", in: app)
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        XCTAssertTrue(exposedText(engine).contains("Apple"), exposedText(engine))
        XCTAssertTrue(app.buttons["voice-test-start"].isEnabled)
        XCTAssertFalse(app.buttons["dictation-stop"].exists)
        XCTAssertFalse(app.buttons["conversation-send"].exists,
                       "A settings recording test must not expose a remote send action")
        capture(app, name: "voice-test-local-without-host")

        back(in: app)
        openRecognition(app)
        XCTAssertTrue(app.buttons["voice-engine-apple"].isSelected,
                      "Opening the test page must not silently select a cloud engine")
        XCTAssertFalse(app.buttons["voice-engine-doubao"].isSelected)
    }

    @MainActor
    func testCloudKeyPersistsWithoutBeingRevealedAndCanBeDeleted() throws {
        let fakeKey = "hermit-ui-test-only-invalid-key"
        var app = launch()
        openSettings(app)
        openRecognition(app)
        selectEngine("doubao", in: app)
        tap(element("voice-doubao-settings-link", in: app), in: app)

        var status = element("doubao-key-status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        waitUntil("Credential status must finish loading") {
            ["saved", "missing"].contains(status.value as? String ?? "")
        }
        if status.value as? String == "saved" {
            tap(app.buttons["doubao-delete-key"], in: app)
            waitUntil("Existing simulator-only key must be removed") { status.value as? String == "missing" }
        }

        let disclosure = element("doubao-upload-disclosure", in: app)
        XCTAssertTrue(reveal(disclosure, in: app))
        XCTAssertTrue(disclosure.label.localizedCaseInsensitiveContains("recording"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("Volcengine"), disclosure.label)
        let key = app.secureTextFields["doubao-api-key"]
        XCTAssertTrue(reveal(key, in: app))
        XCTAssertFalse(app.buttons["doubao-save-key"].isEnabled)
        key.tap()
        key.typeText(fakeKey)
        tap(app.buttons["doubao-save-key"], in: app)
        waitUntil("Saving the key must update its status") { status.value as? String == "saved" }
        XCTAssertNotEqual(key.value as? String, fakeKey)
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "value == %@", fakeKey)).firstMatch.exists)
        capture(app, name: "voice-cloud-key-saved-redacted")

        // Exercise the existing-item update path, not just first-time Add.
        let replacement = "hermit-ui-test-only-replacement-key"
        XCTAssertTrue(reveal(key, in: app))
        key.tap()
        key.typeText(replacement)
        tap(app.buttons["doubao-save-key"], in: app)
        waitUntil("Replacing a key must complete without exposing it") {
            status.value as? String == "saved"
                && app.buttons["doubao-save-key"].isEnabled
                && (key.value as? String ?? "").count < replacement.count
        }
        XCTAssertFalse(app.staticTexts["doubao-configuration-error"].exists)

        app.terminate()
        app = launch(reset: false)
        openSettings(app)
        openRecognition(app)
        XCTAssertTrue(app.buttons["voice-engine-doubao"].isSelected)
        tap(element("voice-doubao-settings-link", in: app), in: app)
        status = element("doubao-key-status", in: app)
        waitUntil("Saved key must remain available after restart") { status.value as? String == "saved" }
        let reopenedKey = app.secureTextFields["doubao-api-key"]
        XCTAssertTrue(reveal(reopenedKey, in: app))
        let visibleValue = reopenedKey.value as? String ?? ""
        XCTAssertTrue(visibleValue.isEmpty || visibleValue == reopenedKey.placeholderValue,
                      "The stored key must not be copied back into the editable field")
        tap(app.buttons["doubao-delete-key"], in: app)
        waitUntil("Deleting the key must clear its status") { status.value as? String == "missing" }
        capture(app, name: "voice-cloud-key-removed")

        // Leave this dedicated simulator with local recognition selected.
        back(in: app)
        selectEngine("apple", in: app)
    }

    @MainActor
    func testIndependentRecordingReviewEditsAndLeavingRecordingCancels() throws {
        let app = launch(preview: true)
        openSettings(app)
        openRecognition(app)
        selectEngine("apple", in: app)
        back(in: app)
        tap(element("settings-voice-test", in: app), in: app)
        tap(app.buttons["voice-test-start"], in: app)
        let stop = app.buttons["dictation-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(element("dictation-engine-label", in: app).label.contains("UI"),
                      "Only the scripted recognizer may run in this test")
        tap(stop, in: app)
        let editor = app.textViews["dictation-review-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitUntil("The scripted recording must finalize before review") {
            editor.value as? String == "simulated voice"
        }
        editor.tap()
        editor.typeText(" checked")
        waitUntil("Manual edits must be visible in review") {
            (editor.value as? String)?.contains("checked") == true
        }
        let keep = app.buttons["dictation-insert"]
        XCTAssertTrue(keep.label.contains("Keep result"), keep.label)
        tap(keep, in: app)
        let result = element("voice-test-result", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("checked") || (result.value as? String)?.contains("checked") == true)
        XCTAssertTrue(app.buttons["voice-test-copy"].isEnabled)
        XCTAssertFalse(app.buttons["conversation-send"].exists)
        capture(app, name: "voice-test-edited-result-kept-locally")

        tap(app.buttons["voice-test-start"], in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        back(in: app)
        tap(element("settings-voice-test", in: app), in: app)
        XCTAssertTrue(app.buttons["voice-test-start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voice-test-start"].isEnabled)
        XCTAssertFalse(stop.exists, "Returning after leaving must not retain an active recording")
        XCTAssertFalse(app.otherElements["dictation-overlay"].exists)
        capture(app, name: "voice-test-recording-cancelled-on-leave")
    }

    @MainActor
    func testCloudConfigurationAndRecordingDisclosureInSimplifiedChinese() throws {
        let app = launch(language: "zh-Hans")
        openSettings(app, chinese: true)
        openRecognition(app)
        XCTAssertTrue(app.navigationBars["识别引擎"].exists)
        let cloud = app.buttons["voice-engine-doubao"]
        XCTAssertTrue(cloud.label.contains("豆包"), cloud.label)
        selectEngine("doubao", in: app)
        tap(element("voice-doubao-settings-link", in: app), in: app)
        XCTAssertTrue(app.navigationBars["配置豆包"].waitForExistence(timeout: 5))
        let configurationDisclosure = element("doubao-upload-disclosure", in: app)
        XCTAssertTrue(reveal(configurationDisclosure, in: app))
        for fragment in ["录音", "火山引擎", "费用"] {
            XCTAssertTrue(configurationDisclosure.label.contains(fragment), configurationDisclosure.label)
        }
        XCTAssertTrue(app.secureTextFields["doubao-api-key"].exists)
        capture(app, name: "voice-cloud-configuration-zh-Hans")

        back(in: app)
        tap(element("voice-test-link", in: app), in: app)
        XCTAssertTrue(app.navigationBars["录音测试"].waitForExistence(timeout: 5))
        let testDisclosure = element("voice-test-disclosure", in: app)
        XCTAssertTrue(reveal(testDisclosure, in: app))
        for fragment in ["停止并识别", "上传至火山引擎", "费用"] {
            XCTAssertTrue(testDisclosure.label.contains(fragment), testDisclosure.label)
        }
        XCTAssertTrue(exposedText(element("voice-test-engine", in: app)).contains("豆包"))
        XCTAssertTrue(app.buttons["voice-test-start"].exists)
        XCTAssertFalse(app.buttons["dictation-stop"].exists,
                       "Inspecting the disclosure must not start recording")
        capture(app, name: "voice-test-cloud-before-recording-zh-Hans")

        back(in: app)
        selectEngine("apple", in: app)
    }

    @MainActor
    func testLocalVocabularyPersistsAndDoesNotSelectCloud() throws {
        var app = launch()
        openSettings(app)
        openRecognition(app)
        selectEngine("apple", in: app)
        tap(element("voice-vocabulary-link", in: app), in: app)
        let editor = app.textViews["voice-vocabulary-editor"]
        XCTAssertTrue(reveal(editor, in: app))
        if let value = editor.value as? String, !value.isEmpty {
            tap(app.buttons["voice-vocabulary-clear"], in: app)
        }
        XCTAssertTrue(reveal(editor, in: app))
        editor.tap()
        editor.typeText("Hermit\nDocker\nhermit")
        tap(app.buttons["voice-vocabulary-save"], in: app)
        XCTAssertTrue(element("voice-vocabulary-saved", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Hermit\nDocker")
        capture(app, name: "voice-local-vocabulary-saved")
        app = launch(reset: false)
        openSettings(app)
        openRecognition(app)
        XCTAssertTrue(app.buttons["voice-engine-apple"].isSelected)
        tap(element("voice-vocabulary-link", in: app), in: app)
        XCTAssertEqual(app.textViews["voice-vocabulary-editor"].value as? String, "Hermit\nDocker")
        tap(app.buttons["voice-vocabulary-clear"], in: app)
        tap(app.buttons["voice-vocabulary-save"], in: app)
    }

    @MainActor
    func testSameRecordingComparisonShowsTimingAndProtectsEdits() throws {
        let app = launch(preview: true)
        openSettings(app)
        openRecognition(app)
        selectEngine("apple", in: app)
        tap(element("voice-test-link", in: app), in: app)
        tap(app.buttons["voice-test-start"], in: app)
        tap(app.buttons["dictation-stop"], in: app)
        let editor = app.textViews["dictation-review-editor"]
        waitUntil("First recording must finish") { editor.value as? String == "simulated voice" }
        XCTAssertTrue(reveal(element("voice-test-timing", in: app), in: app))
        tap(app.buttons["voice-test-compare"], in: app)
        // Menu items live in a transient presentation on iPad. Scrolling the
        // underlying Form while the menu is opening dismisses that presentation.
        let appleComparison = element("voice-test-compare-apple", in: app)
        capture(app, name: "voice-local-comparison-menu")
        XCTAssertTrue(appleComparison.waitForExistence(timeout: 5))
        XCTAssertTrue(appleComparison.isHittable)
        appleComparison.tap()
        waitUntil("Comparison must use the retained recording") {
            editor.value as? String == "retried automatic voice"
        }
        XCTAssertTrue(reveal(element("voice-test-comparisons", in: app), in: app))
        capture(app, name: "voice-local-comparison-and-timing")
        XCTAssertTrue(reveal(editor, in: app))
        editor.tap()
        editor.typeText(" edited")
        let compare = app.buttons["voice-test-compare"]
        XCTAssertTrue(reveal(compare, in: app))
        waitUntil("Comparison must not replace manually edited text") { !compare.isEnabled }
        tap(app.buttons["dictation-undo-edits"], in: app)
        waitUntil("Undoing edits must restore comparison") { compare.isEnabled }
        back(in: app)
        XCTAssertTrue(app.buttons["voice-engine-apple"].isSelected,
                      "Comparisons must not change the default engine")
    }

    @MainActor
    private func launch(reset: Bool = true, preview: Bool = false, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "zh-Hans" ? "zh_CN" : "en_US"]
        if reset { app.launchArguments.append("-MOSHPIT_RESET") }
        if preview { app.launchArguments.append("-MOSHPIT_VOICE_SETTINGS_TEST_PREVIEW") }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication, chinese: Bool = false) {
        app.buttons["home-settings"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "设置" : "Settings"].waitForExistence(timeout: 5))
        let enabled = app.switches[chinese ? "启用语音输入" : "Enable Voice Input"]
        XCTAssertTrue(reveal(enabled, in: app))
        if enabled.value as? String == "0" { enabled.tap() }
    }

    @MainActor
    private func openRecognition(_ app: XCUIApplication) {
        tap(element("settings-voice-recognition", in: app), in: app)
        XCTAssertTrue(app.buttons["voice-engine-apple"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func selectEngine(_ engine: String, in app: XCUIApplication) {
        let row = app.buttons["voice-engine-\(engine)"]
        tap(row, in: app)
        XCTAssertTrue(row.isSelected)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func exposedText(_ element: XCUIElement) -> String {
        element.label + " " + (element.value as? String ?? "")
    }

    @MainActor
    private func back(in app: XCUIApplication) {
        let button = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(reveal(element, in: app), "Element must be visible: \(element.identifier)")
        waitUntil("Control must finish its pending operation: \(element.identifier)") { element.isEnabled }
        element.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        var towardTop = false
        for attempt in 0..<24 {
            let form = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            if !form.exists { return element.exists && element.isHittable }
            var visible = form.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY - 40) - visible.minY)
            }
            guard visible.height > 70 else { return element.exists && element.isHittable }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty {
                if visible.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return true }
                towardTop = frame.midY < visible.midY
            } else if attempt == 12 { towardTop.toggle() }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = CGPoint(x: visible.minX + 4, y: visible.minY + visible.height * (towardTop ? 0.25 : 0.8))
            let to = CGPoint(x: visible.minX + 4, y: visible.minY + visible.height * (towardTop ? 0.8 : 0.25))
            origin.withOffset(CGVector(dx: from.x, dy: from.y)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
