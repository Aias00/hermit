import XCTest
import UIKit

/// Real SSH against an isolated terminal owned by the simulator test harness.
final class TerminalReliabilityUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIApplication().terminate()
    }

    @MainActor
    private func openTerminal(multiplexer: String = "herdr", seedImage: Bool = false,
                              seedVoice: Bool = false, seedVoiceFailure: Bool = false,
                              seedVoiceReview: Bool = false) throws -> XCUIApplication {
        XCTAssertTrue(!seedVoiceFailure || seedVoice, "a failed voice preview also requires the voice seed")
        XCTAssertTrue(!seedVoiceReview || seedVoice, "a voice review preview also requires the voice seed")
        #if !targetEnvironment(simulator)
        if seedVoice { throw XCTSkip("Voice previews reset app data; use a dedicated simulator only") }
        #endif
        let environment = ProcessInfo.processInfo.environment
        let password = environment["MOSHPIT_SEED_PASSWORD"] ?? ""
        let key = environment["MOSHPIT_SEED_KEY_B64"] ?? ""
        guard !password.isEmpty || !key.isEmpty else {
            throw XCTSkip("requires an isolated SSH test host and MOSHPIT_SEED_PASSWORD or MOSHPIT_SEED_KEY_B64")
        }
        let app = XCUIApplication()
        if !key.isEmpty { app.launchEnvironment["MOSHPIT_SEED_KEY_B64"] = key }
        else { app.launchEnvironment["MOSHPIT_SEED_PASSWORD"] = password }
        app.launchArguments += ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "1",
            "-MOSHPIT_SEED_USER", environment["MOSHPIT_SEED_USER"] ?? "aias",
            "-MOSHPIT_SEED_HOST", environment["MOSHPIT_SEED_HOST"] ?? "127.0.0.1",
            "-MOSHPIT_SEED_PORT", environment["MOSHPIT_SEED_PORT"] ?? "22",
            "-MOSHPIT_SEED_NAME", "Isolated-UI-Lab", "-MOSHPIT_SEED_QUIET", "1",
            "-MOSHPIT_SEED_MUX", multiplexer,
            "-MOSHPIT_SEED_HERDR_BIN", environment["MOSHPIT_SEED_HERDR_BIN"] ?? "/tmp/moshpit-ui-lab/herdr",
            "-MOSHPIT_SEED_TRUST_FP", environment["MOSHPIT_SEED_TRUST_FP"] ?? "SHA256:iKK6EXDfFALcYCaggiqUfP0PcryrRX4KtJgLoam+npA",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if seedImage { app.launchArguments.append("-MOSHPIT_SEED_IMAGE_DRAFT") }
        if seedVoice {
            // Use one explicit navigation path for voice fixtures. Automatic
            // DEBUG navigation must not race a cold-launch host-card tap.
            app.launchArguments += ["-MOSHPIT_SEED_VOICE_DRAFT", "-MOSHPIT_SEED_HOME", "1"]
        }
        if seedVoiceFailure { app.launchArguments.append("-MOSHPIT_SEED_VOICE_FAILURE") }
        if seedVoiceReview { app.launchArguments.append("-MOSHPIT_SEED_VOICE_REVIEW") }
        // A simulator may retain a process started during installation. The
        // voice fixture must start a fresh process with its explicit seed args.
        if seedVoice { app.terminate() }
        app.launch()
        let terminalKeyboard = app.buttons["conversation-keyboard-toggle"]
        #if targetEnvironment(simulator)
        if seedVoice {
            XCTAssertEqual(environment["MOSHPIT_SEED_HOST"] ?? "127.0.0.1", "127.0.0.1")
            let host = app.buttons["connection-card-Isolated-UI-Lab"]
            XCTAssertTrue(host.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["home-settings"].exists)
            XCTAssertTrue(host.label.contains("127.0.0.1"), "only open the isolated loopback host")
            host.tap()
        }
        #endif
        XCTAssertTrue(terminalKeyboard.waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-composer").firstMatch
    }

    /// The isolated SSH fixture records the PTY input itself. This distinguishes
    /// a real remote Return from a button that merely leaves the local draft alone.
    private func inputReceiptURL() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["MOSHPIT_INPUT_RECEIPT_URL"],
              let url = URL(string: value), url.host == "127.0.0.1" else {
            throw XCTSkip("requires the isolated loopback raw-input receipt endpoint")
        }
        return url
    }

    /// Voice reviews use a deterministic recognizer and an isolated loopback
    /// receiver, never a physical phone or a real remote host.
    private func voiceInputReceiptURL() throws -> URL {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Voice previews reset app data; use a dedicated simulator only")
        #else
        guard (ProcessInfo.processInfo.environment["MOSHPIT_SEED_HOST"] ?? "127.0.0.1") == "127.0.0.1" else {
            throw XCTSkip("Voice previews require the isolated loopback SSH fixture")
        }
        return try inputReceiptURL()
        #endif
    }

    private func resetInputReceipt(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func receivedInput(_ url: URL) async throws -> [Int] {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(receipt["bytes"] as? [Int])
    }

    private func assertOneRemoteReturn(_ url: URL) async throws {
        var received: [Int] = []
        for _ in 0..<50 {
            received = try await receivedInput(url)
            if !received.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(received, [13], "one tap must send exactly one remote Return, without draft text")
        // Catch delayed retries or accidental second sends as well.
        try await Task.sleep(for: .milliseconds(300))
        let settled = try await receivedInput(url)
        XCTAssertEqual(settled, [13])
    }

    @MainActor
    private func waitForKeyboardToolbar(_ button: XCUIElement, in app: XCUIApplication,
                                        keyboardVisible: Bool) {
        var previousFrame = CGRect.null
        var stableSince = Date()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists == keyboardVisible, button.exists, button.isHittable else {
                stableSince = Date()
                return false
            }
            let frame = button.frame
            // Keyboard AX can exist before the toolbar's lift animation ends.
            // Tapping its old position can otherwise type a punctuation key.
            guard !keyboardVisible || frame.maxY <= keyboard.frame.minY else {
                stableSince = Date()
                return false
            }
            if frame != previousFrame {
                previousFrame = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor
    private func submit(_ command: String, in app: XCUIApplication) {
        let field = composer(app)
        field.tap()
        field.typeText(command)
        XCTAssertEqual(field.value as? String, command, "complete input must remain in the composer before sending")
        let send = app.buttons["conversation-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let cleared = NSPredicate { element, _ in
            !String(describing: (element as? XCUIElement)?.value ?? "").contains(command)
        }
        expectation(for: cleared, evaluatedWith: field)
        waitForExpectations(timeout: 15)
    }

    @MainActor
    func testHerdrKeyboardCtrlAndDraftPreservation() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("kept draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let ctrl = app.buttons["conversation-ctrl"]
        ctrl.tap()
        XCTAssertTrue(ctrl.isSelected)
        app.typeText("c")
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: ctrl)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(String(describing: field.value ?? "").contains("kept draft"))
        field.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "herdr-keyboard-ctrl-submit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testHerdrKeyboardCyclesDuringContinuousOutputPreserveDraftAndInputDestination() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Continuous-output fixtures reset app data; use a dedicated simulator only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["MOSHPIT_SWITCH_FIXTURE_DIR"],
              directory.hasPrefix("/private/tmp/moshpit-ui-lab") || directory.hasPrefix("/tmp/moshpit-ui-lab"),
              env["MOSHPIT_SEED_HOST"] == "127.0.0.1",
              let herdr = env["MOSHPIT_SEED_HERDR_BIN"],
              URL(fileURLWithPath: herdr).deletingLastPathComponent().standardizedFileURL
                == URL(fileURLWithPath: directory).standardizedFileURL else {
            throw XCTSkip("Requires terminal-session-fixture.py's isolated real Herdr shell")
        }
        let base = URL(fileURLWithPath: directory).appendingPathComponent("keyboard-output-\(UUID().uuidString)")
        let script = base.appendingPathExtension("py")
        let progress = base.appendingPathExtension("tick")
        let input = base.appendingPathExtension("input")
        let stop = base.appendingPathExtension("stop")
        let done = base.appendingPathExtension("done")
        let source = """
        import os, select, sys, termios, time, tty
        from pathlib import Path
        base = Path(sys.argv[1])
        fd = sys.stdin.fileno()
        original = termios.tcgetattr(fd)
        tick = 0
        base.with_suffix('.input').write_bytes(b'')
        try:
            tty.setraw(fd)
            # Bounded even if the UI runner exits before sending its stop marker.
            deadline = time.monotonic() + 120
            next_frame = time.monotonic()
            while time.monotonic() < deadline and not base.with_suffix('.stop').exists():
                tick += 1
                sys.stdout.write('\\r\\x1b[2KKEYBOARD_STRESS %04d — 中文 / English' % tick)
                sys.stdout.flush()
                base.with_suffix('.next').write_text(str(tick))
                base.with_suffix('.next').replace(base.with_suffix('.tick'))
                ready, _, _ = select.select([fd], [], [], 0)
                if ready:
                    data = os.read(fd, 4096)
                    if not data: break
                    with base.with_suffix('.input').open('ab') as receipt: receipt.write(data)
                next_frame += 0.05
                time.sleep(max(0, next_frame - time.monotonic()))
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, original)
            sys.stdout.write('\\r\\nKEYBOARD_STRESS_DONE\\r\\n')
            sys.stdout.flush()
            base.with_suffix('.done').write_text(str(tick))
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        defer {
            try? Data().write(to: stop)
            // Never remove a live program's stop marker. A failed test leaves
            // only disposable lab artifacts; the producer also has a time cap.
            if FileManager.default.fileExists(atPath: done.path) {
                for file in [script, progress, input, stop, done, base.appendingPathExtension("next")] {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func tick() -> Int { (try? String(contentsOf: progress, encoding: .utf8)).flatMap(Int.init) ?? 0 }
        let app = try openTerminal()
        submit("/usr/bin/python3 -u \(quote(script.path)) \(quote(base.path))", in: app)
        let started = expectation(for: NSPredicate { _, _ in tick() > 0 }, evaluatedWith: nil)
        await fulfillment(of: [started], timeout: 20)
        let field = composer(app)
        field.tap()
        var draft = "kept during terminal output"
        field.typeText(draft)
        let keyboard = app.buttons["conversation-keyboard-toggle"]

        for round in 1...3 {
            let before = tick()
            waitForKeyboardToolbar(keyboard, in: app, keyboardVisible: true)
            keyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            waitForKeyboardToolbar(keyboard, in: app, keyboardVisible: false)
            let reappeared = expectation(for: NSPredicate { _, _ in app.keyboards.firstMatch.exists }, evaluatedWith: app)
            reappeared.isInverted = true
            await fulfillment(of: [reappeared], timeout: 2)
            XCTAssertEqual(field.value as? String, draft)
            XCTAssertGreaterThan(tick(), before, "The remote producer must still be emitting during keyboard dismissal")
            XCTAssertFalse(FileManager.default.fileExists(atPath: done.path))
            XCTAssertTrue(app.buttons["conversation-direct-input"].isHittable)
            if round == 1 || round == 3 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "herdr-continuous-output-keyboard-hidden-\(round)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            keyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            waitForKeyboardToolbar(keyboard, in: app, keyboardVisible: true)
            // No composer tap: showing the keyboard must restore draft focus.
            app.typeText(" \(round)")
            draft += " \(round)"
            XCTAssertEqual(field.value as? String, draft)
        }
        XCTAssertEqual(try Data(contentsOf: input), Data(), "Keyboard and draft changes must not send remote input")
        let hand = app.buttons["conversation-direct-input"]
        hand.tap()
        XCTAssertTrue(hand.isSelected)
        app.typeText("direct-keys\n")
        let direct = Data("direct-keys\r".utf8)
        let delivered = expectation(for: NSPredicate { _, _ in
            (try? Data(contentsOf: input)) == direct
        }, evaluatedWith: nil)
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(field.value as? String, draft)
        hand.tap()
        XCTAssertFalse(hand.isSelected)
        app.typeText(" local again")
        draft += " local again"
        XCTAssertEqual(field.value as? String, draft)
        waitForKeyboardToolbar(keyboard, in: app, keyboardVisible: true)
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try Data().write(to: stop)
        let finished = expectation(for: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: done.path)
        }, evaluatedWith: nil)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: input), direct, "Returning to the draft must stop remote typing")
        XCTAssertEqual(field.value as? String, draft)
        let evidence = XCTAttachment(string: "Output frames: \(try String(contentsOf: done, encoding: .utf8)); direct input bytes: \(Array(direct)); keyboard cycles: 3")
        evidence.name = "herdr-keyboard-output-and-input-receipt"
        evidence.lifetime = .keepAlways
        add(evidence)
        // Functional lifecycle and delivery checks; XCTest action durations do
        // not measure frame rate or keyboard-animation smoothness.
        #endif
    }

    @MainActor
    func testNativeFontSidebarRotationAndForeground() throws {
        let app = try openTerminal()
        let menu = app.buttons["conversation-menu"]
        menu.tap()
        app.buttons["自动适配字号"].tap()
        let before = Double(String(describing: menu.value ?? "").components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(before, 0)
        menu.tap()
        app.buttons["放大字体"].tap()
        let enlarged = NSPredicate { _, _ in
            let value = Double(String(describing: menu.value ?? "").components(separatedBy: " ").first ?? "") ?? 0
            return value > before
        }
        expectation(for: enlarged, evaluatedWith: menu)
        waitForExpectations(timeout: 5)
        let sidebar = app.buttons["conversation-sidebar"]
        let tabs = app.descendants(matching: .any).matching(identifier: "herdr-tabs").firstMatch
        XCTAssertTrue(tabs.exists)
        let fullWidth = tabs.frame.width
        sidebar.tap()
        XCTAssertTrue(sidebar.isSelected)
        XCTAssertLessThan(tabs.frame.width, fullWidth, "sidebar must reserve its own width")
        app.buttons["conversation-sidebar-collapse"].tap()
        XCTAssertEqual(tabs.frame.width, fullWidth, accuracy: 1, "hiding sidebar returns width to terminal")
        XCTAssertTrue(app.buttons["herdr-tab-add"].isHittable)
        XCTAssertFalse(sidebar.isSelected)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        // A query can finish during rotation. Tapping waits for animations to
        // settle, then verifies the actual controls in the new geometry.
        menu.tap()
        app.buttons["自动适配字号"].tap()
        XCTAssertTrue(app.buttons["conversation-keyboard-toggle"].isHittable)
        XCTAssertTrue(app.buttons["conversation-arrow-right"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["conversation-send"].waitForExistence(timeout: 10))
        submit("printf 'HERDR_RESUME_OK\\n' >> /tmp/moshpit-ui-lab/received.log", in: app)
    }

    @MainActor
    func testRejectedHerdrSubmissionRetainsDraft() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("__MOSHPIT_REJECT_DRAFT__")
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__")
        let send = app.buttons["conversation-send"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '草稿已保留'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(String(describing: field.value ?? "").contains("__MOSHPIT_REJECT_DRAFT__"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "failed-submission-retains-draft"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testReturnAddsNewlineThenPlaneSendsForHerdrAndSSH() throws {
        for mux in ["herdr", "none"] {
            let app = try openTerminal(multiplexer: mux)
            let field = composer(app)
            field.tap()
            let command = "printf 'PLANE_AFTER_NEWLINE_" + mux.uppercased() + "_OK\\n' >> /tmp/moshpit-ui-lab/received.log"
            field.typeText(command)
            XCTAssertEqual(field.value as? String, command)
            field.typeText("\n")
            XCTAssertEqual(field.value as? String, command + "\n")
            field.typeText("# second line")
            XCTAssertEqual(field.value as? String, command + "\n# second line")
            app.buttons["conversation-send"].tap()
            expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
            waitForExpectations(timeout: 15)
            app.terminate()
        }
    }

    @MainActor
    func testRemoteEnterSendsOneKeyAndPreservesComposerFocus() async throws {
        let receipt = try inputReceiptURL()
        let app = try openTerminal(multiplexer: "none")
        let field = composer(app)
        let enter = app.buttons["conversation-enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: enter)
        await fulfillment(of: [enabled], timeout: 20)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["conversation-send"].isEnabled,
                       "the plane sends drafts; an empty draft is not a remote Enter")

        try await resetInputReceipt(receipt)
        waitForKeyboardToolbar(enter, in: app, keyboardVisible: true)
        enter.tap()
        try await assertOneRemoteReturn(receipt)
        XCTAssertEqual(field.value as? String, "")
        app.typeText("kept draft")
        XCTAssertEqual(field.value as? String, "kept draft", "remote Enter must not take keyboard focus")

        try await resetInputReceipt(receipt)
        waitForKeyboardToolbar(enter, in: app, keyboardVisible: true)
        enter.tap()
        try await assertOneRemoteReturn(receipt)
        XCTAssertEqual(field.value as? String, "kept draft")
        app.typeText("\nsecond line")
        XCTAssertEqual(field.value as? String, "kept draft\nsecond line",
                       "keyboard Return still edits the draft after using remote Enter")

        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try await resetInputReceipt(receipt)
        waitForKeyboardToolbar(enter, in: app, keyboardVisible: false)
        enter.tap()
        try await assertOneRemoteReturn(receipt)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "remote Enter must also work with the keyboard hidden")
        XCTAssertEqual(field.value as? String, "kept draft\nsecond line")

        // The restored hand button changes the input destination without
        // sending or discarding the local draft. Verify actual SSH bytes.
        let directInput = app.buttons["conversation-direct-input"]
        XCTAssertTrue(directInput.isHittable)
        XCTAssertFalse(directInput.isSelected)
        let inputMode = app.descendants(matching: .any).matching(identifier: "conversation-input-mode").firstMatch
        XCTAssertTrue(inputMode.exists)
        let draftModeLabel = inputMode.label
        try await resetInputReceipt(receipt)
        directInput.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(directInput.isSelected, "the hand must clearly identify direct terminal input")
        XCTAssertNotEqual(inputMode.label, draftModeLabel)
        app.typeText("direct input\n")
        let expected = Array("direct input\r".utf8).map(Int.init)
        for _ in 0..<50 {
            if try await receivedInput(receipt) == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let remoteInput = try await receivedInput(receipt)
        XCTAssertEqual(remoteInput, expected)
        XCTAssertEqual(field.value as? String, "kept draft\nsecond line")

        directInput.tap()
        XCTAssertFalse(directInput.isSelected, "the hand toggles back to the preserved draft")
        XCTAssertEqual(inputMode.label, draftModeLabel)
        app.typeText(" local again")
        XCTAssertEqual((field.value as? String)?.replacingOccurrences(of: " local again", with: ""),
                       "kept draft\nsecond line")
        let afterReturningToDraft = try await receivedInput(receipt)
        XCTAssertEqual(afterReturningToDraft, expected, "Returning to the draft must stop remote typing")
        directInput.tap()
        XCTAssertTrue(directInput.isSelected)
        field.tap()
        XCTAssertFalse(directInput.isSelected, "tapping the draft must also clear direct-input selection")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "hand-button-terminal-and-draft-focus"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFilePickerRestoresComposerFocusAndHiddenKeyboard() throws {
        let app = try openTerminal(multiplexer: "none")
        let field = composer(app)
        field.tap()
        field.typeText("before picker")
        let attachments = app.buttons["conversation-attachments"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: attachments)
        waitForExpectations(timeout: 20)

        func openAndCancelPicker() {
            attachments.tap()
            app.buttons["本地文件（单个最多 20 MB）"].tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        }

        openAndCancelPicker()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Do not tap the composer here: that would hide a focus-restoration bug.
        app.typeText("\nafter picker")
        XCTAssertEqual(field.value as? String, "before picker\nafter picker")

        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        openAndCancelPicker()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a picker must preserve a previously hidden keyboard")
        XCTAssertEqual(field.value as? String, "before picker\nafter picker")
    }

    @MainActor
    func testVoiceTranscriptStagesInDraftUntilPlaneSends() async throws {
        let receipt = try voiceInputReceiptURL()
        let app = try openTerminal(multiplexer: "none", seedVoice: true)
        let field = composer(app)
        field.tap()
        field.typeText("typed text")
        let send = app.buttons["conversation-send"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        await fulfillment(of: [enabled], timeout: 20)
        try await resetInputReceipt(receipt)

        let voice = app.buttons["语音输入"]
        waitForKeyboardToolbar(voice, in: app, keyboardVisible: true)
        voice.tap()
        let insert = app.buttons["dictation-insert"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5))
        let overlay = app.descendants(matching: .any).matching(identifier: "dictation-overlay").firstMatch
        XCTAssertTrue(overlay.exists)
        XCTAssertFalse(overlay.buttons.matching(NSPredicate(format: "label IN %@", ["发送", "Send"])).firstMatch.exists,
            "voice uses the shared draft send action")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "voice-result-before-draft-insertion"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        insert.tap()
        let staged = expectation(for: NSPredicate { _, _ in
            field.value as? String == "typed text simulated voice"
        }, evaluatedWith: field)
        await fulfillment(of: [staged], timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "dictation-overlay").firstMatch.exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let beforeSend = try await receivedInput(receipt)
        XCTAssertEqual(beforeSend, [], "inserting a voice result must not type into the remote program")
        let stagedScreenshot = XCTAttachment(screenshot: app.screenshot())
        stagedScreenshot.name = "voice-result-staged-in-shared-draft"
        stagedScreenshot.lifetime = .keepAlways
        add(stagedScreenshot)

        // Recognition quality is outside this test: the seeded transcript only
        // verifies the same editing/submit path used by a real recognizer result.
        app.typeText("\nchecked")
        let draft = "typed text simulated voice\nchecked"
        XCTAssertEqual(field.value as? String, draft)
        let afterReturn = try await receivedInput(receipt)
        XCTAssertEqual(afterReturn, [], "keyboard Return must remain local after voice insertion")
        send.tap()
        let cleared = expectation(for: NSPredicate { _, _ in
            (field.value as? String)?.isEmpty == true
        }, evaluatedWith: field)
        await fulfillment(of: [cleared], timeout: 10)
        let expected = Array(("\u{1b}[200~" + draft + "\u{1b}[201~\r").utf8).map(Int.init)
        var delivered: [Int] = []
        for _ in 0..<50 {
            delivered = try await receivedInput(receipt)
            if delivered.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(delivered, expected, "the plane sends the complete shared draft and one Return")
        app.typeText("next draft")
        XCTAssertEqual(field.value as? String, "next draft", "sending keeps focus in the draft")
    }

    @MainActor
    func testFailedVoiceTranscriptRequiresExplicitKeepBeforeSending() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The failed voice preview resets app data; use a dedicated simulator only")
        #else
        let receipt = try voiceInputReceiptURL()
        // This deterministic preview tests recovery and delivery, not microphone
        // capture or recognition accuracy. The failure is .finalizationFailed.
        let app = try openTerminal(multiplexer: "none", seedVoice: true, seedVoiceFailure: true)
        let field = composer(app)
        field.tap()
        field.typeText("typed text")
        let send = app.buttons["conversation-send"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        await fulfillment(of: [enabled], timeout: 20)
        try await resetInputReceipt(receipt)

        let voice = app.buttons["语音输入"]
        waitForKeyboardToolbar(voice, in: app, keyboardVisible: true)
        voice.tap()
        let keep = app.buttons["dictation-keep-partial"]
        let failure = app.staticTexts.matching(NSPredicate(format: "label IN %@", [
            "末尾内容未能完成识别。你可以保留目前已识别的文字。",
            "末尾內容未能完成辨識。你可以保留目前已辨識的文字。",
            "The last words could not be finalized. You can keep the text recognized so far.",
        ])).firstMatch
        let partial = app.textViews["dictation-review-editor"]
        let overlay = app.descendants(matching: .any).matching(identifier: "dictation-overlay").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "the failed preview must explain that the last words were not finalized")
        XCTAssertTrue(partial.waitForExistence(timeout: 5), "recognized partial text must remain readable after failure")
        XCTAssertEqual(partial.value as? String, "simulated voice")
        XCTAssertEqual(field.value as? String, "typed text", "a recognition failure must leave the existing draft unchanged")
        try await Task.sleep(for: .milliseconds(300))
        let afterFailure = try await receivedInput(receipt)
        XCTAssertEqual(afterFailure, [], "failure must neither type nor send partial text to the remote program")
        let failedScreenshot = XCTAttachment(screenshot: app.screenshot())
        failedScreenshot.name = "voice-finalization-failure-requires-explicit-keep"
        failedScreenshot.lifetime = .keepAlways
        add(failedScreenshot)

        keep.tap()
        let draft = "typed text simulated voice"
        let staged = expectation(for: NSPredicate { _, _ in field.value as? String == draft }, evaluatedWith: field)
        await fulfillment(of: [staged], timeout: 5)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let beforeSend = try await receivedInput(receipt)
        XCTAssertEqual(beforeSend, [], "explicitly keeping partial speech only adds it to the local draft")

        waitForKeyboardToolbar(send, in: app, keyboardVisible: true)
        send.tap()
        let cleared = expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
        await fulfillment(of: [cleared], timeout: 10)
        let expected = Array(("\u{1b}[200~" + draft + "\u{1b}[201~\r").utf8).map(Int.init)
        var delivered: [Int] = []
        for _ in 0..<50 {
            delivered = try await receivedInput(receipt)
            if delivered.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(delivered, expected, "the plane sends the original draft plus accepted partial text and exactly one Return")
        try await Task.sleep(for: .milliseconds(300))
        let settled = try await receivedInput(receipt)
        XCTAssertEqual(settled, expected, "a failed recognition must not cause delayed or duplicate sends")

        app.typeText("old draft kept")
        XCTAssertEqual(field.value as? String, "old draft kept")
        waitForKeyboardToolbar(voice, in: app, keyboardVisible: true)
        voice.tap()
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(partial.waitForExistence(timeout: 5))
        XCTAssertEqual(partial.value as? String, "simulated voice")
        XCTAssertEqual(field.value as? String, "old draft kept")
        let beforeDismissal = try await receivedInput(receipt)
        XCTAssertEqual(beforeDismissal, expected)
        let dismiss = app.buttons["dictation-cancel"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "old draft kept", "dismissing failed speech must not append or replace the previous draft")
        try await Task.sleep(for: .milliseconds(300))
        let afterDismissal = try await receivedInput(receipt)
        XCTAssertEqual(afterDismissal, expected, "dismissing failed speech must produce no additional remote input")
        #endif
    }

    @MainActor
    func testVoiceStopReviewRetryAndOriginalKeepDraftLocal() async throws {
        let receipt = try voiceInputReceiptURL()
        // The scripted capture never opens the microphone. English retry is
        // deterministic and exercises the same review/accept UI as real audio.
        let app = try openTerminal(multiplexer: "none", seedVoice: true, seedVoiceReview: true)
        let field = composer(app)
        field.tap()
        field.typeText("typed text")
        try await resetInputReceipt(receipt)
        openVoiceReview(in: app)
        XCTAssertEqual(app.buttons["dictation-language"].value as? String, "auto")
        XCTAssertFalse(app.textViews["dictation-review-editor"].exists)
        XCTAssertEqual(field.value as? String, "typed text")

        app.buttons["dictation-stop"].tap()
        let editor = waitForVoiceReviewText("simulated voice", in: app)
        XCTAssertFalse(app.buttons["dictation-stop"].exists)
        XCTAssertTrue(app.buttons["dictation-insert"].isEnabled)
        XCTAssertEqual(field.value as? String, "typed text", "Stop only opens review; it must not commit speech")
        let stoppedBytes = try await receivedInput(receipt)
        XCTAssertEqual(stoppedBytes, [])
        captureVoiceReview(app, name: "voice-stopped-awaiting-review")

        retryVoiceReviewInEnglish(in: app)
        XCTAssertEqual(field.value as? String, "typed text", "Re-recognition must leave the existing draft alone")
        let retriedBytes = try await receivedInput(receipt)
        XCTAssertEqual(retriedBytes, [])
        let original = app.buttons["dictation-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.isEnabled)
        original.tap()
        _ = waitForVoiceReviewText("simulated voice", in: app)
        XCTAssertEqual(app.buttons["dictation-language"].value as? String, "auto",
                       "Restoring the original also restores its language provenance")
        XCTAssertFalse(original.exists && original.isEnabled, "Original is already displayed")
        XCTAssertEqual(editor.value as? String, "simulated voice")
        captureVoiceReview(app, name: "voice-original-restored-before-insertion")

        app.buttons["dictation-insert"].tap()
        let staged = expectation(for: NSPredicate { _, _ in
            field.value as? String == "typed text simulated voice"
        }, evaluatedWith: field)
        await fulfillment(of: [staged], timeout: 5)
        XCTAssertTrue(app.textViews["dictation-review-editor"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let insertedBytes = try await receivedInput(receipt)
        XCTAssertEqual(insertedBytes, [], "Only the plane may send the shared draft to the remote terminal")

        // A new voice session takes the unchanged global preference. The
        // English retry above must not silently change future recordings.
        openVoiceReview(in: app)
        XCTAssertEqual(app.buttons["dictation-language"].value as? String, "auto")
        app.buttons["dictation-cancel"].tap()
        XCTAssertTrue(app.buttons["dictation-stop"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "typed text simulated voice")
        try await Task.sleep(for: .milliseconds(300))
        let cancelledBytes = try await receivedInput(receipt)
        XCTAssertEqual(cancelledBytes, [], "Cancelling the next recording must not insert or send anything")
    }

    @MainActor
    func testVoiceReviewEditsBlockReplayAndCancelPreservesDraft() async throws {
        let receipt = try voiceInputReceiptURL()
        let app = try openTerminal(multiplexer: "none", seedVoice: true, seedVoiceReview: true)
        let field = composer(app)
        field.tap()
        field.typeText("existing draft")
        try await resetInputReceipt(receipt)
        openVoiceReview(in: app)
        app.buttons["dictation-stop"].tap()
        _ = waitForVoiceReviewText("simulated voice", in: app)
        retryVoiceReviewInEnglish(in: app)

        let editor = app.textViews["dictation-review-editor"]
        editor.tap()
        editor.typeText(" manually edited")
        let edited = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(edited.contains("manually edited"))
        XCTAssertNotEqual(edited, "retried English voice")
        let retry = app.buttons["dictation-retry"]
        let original = app.buttons["dictation-original"]
        XCTAssertTrue(retry.exists)
        XCTAssertTrue(original.exists)
        XCTAssertFalse(retry.isEnabled, "Retry must not replace manual edits")
        XCTAssertFalse(original.isEnabled, "Restoring original must not replace manual edits")
        XCTAssertEqual(field.value as? String, "existing draft")
        let editedBytes = try await receivedInput(receipt)
        XCTAssertEqual(editedBytes, [])
        captureVoiceReview(app, name: "voice-manual-edits-protected")

        let undo = app.buttons["dictation-undo-edits"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        _ = waitForVoiceReviewText("retried English voice", in: app)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(original.isEnabled)
        editor.tap()
        editor.typeText(" cancelled changes")
        XCTAssertTrue((editor.value as? String)?.contains("cancelled changes") == true)
        // The bottom microphone is also a dismiss action. It must restore
        // the draft's focus just like the panel's Cancel button does.
        let voice = app.buttons["语音输入"]
        waitForKeyboardToolbar(voice, in: app, keyboardVisible: true)
        voice.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "existing draft", "Cancelling review must discard its edits and preserve the previous draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Do not tap the composer: typing must already target the draft.
        app.typeText(" after cancel")
        let expectedDraft = "existing draft after cancel"
        XCTAssertEqual(field.value as? String, expectedDraft)
        try await Task.sleep(for: .milliseconds(300))
        let cancelledBytes = try await receivedInput(receipt)
        XCTAssertEqual(cancelledBytes, [], "Review edits and cancellation must never reach the remote program")

        // This session ends with English selected, so restoring Original in
        // another test cannot mask a change to the saved language preference.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        openVoiceReview(in: app)
        XCTAssertEqual(app.buttons["dictation-language"].value as? String, "auto",
                       "The next recording must still use the unchanged global preference")
        app.buttons["dictation-cancel"].tap()
        XCTAssertTrue(app.buttons["dictation-stop"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, expectedDraft)
        let nextSessionBytes = try await receivedInput(receipt)
        XCTAssertEqual(nextSessionBytes, [])
    }

    @MainActor
    private func openVoiceReview(in app: XCUIApplication) {
        let voice = app.buttons["语音输入"]
        waitForKeyboardToolbar(voice, in: app, keyboardVisible: true)
        voice.tap()
        XCTAssertTrue(app.buttons["dictation-stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dictation-cancel"].exists)
    }

    @MainActor
    @discardableResult
    private func waitForVoiceReviewText(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let editor = app.textViews["dictation-review-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.value as? String == text
        }, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        return editor
    }

    @MainActor
    private func retryVoiceReviewInEnglish(in app: XCUIApplication) {
        let language = app.buttons["dictation-language"]
        language.tap()
        let english = app.buttons["dictation-language-en-US"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        XCTAssertEqual(language.value as? String, "en-US")
        XCTAssertEqual(app.textViews["dictation-review-editor"].value as? String, "simulated voice",
                       "Changing session language must not start recognition before Retry is tapped")
        let retry = app.buttons["dictation-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        _ = waitForVoiceReviewText("retried English voice", in: app)
    }

    @MainActor
    private func captureVoiceReview(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPlaneFailureRetainsMultilineDraft() throws {
        let app = try openTerminal()
        let field = composer(app)
        field.tap()
        field.typeText("__MOSHPIT_REJECT_DRAFT__\n")
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__\n")
        app.buttons["conversation-send"].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '草稿已保留'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "__MOSHPIT_REJECT_DRAFT__\n")
    }

    @MainActor
    func testVisualStatesAndShortcutKeys() throws {
        let app = try openTerminal()
        let menu = app.buttons["conversation-menu"]
        func capture(_ name: String) {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let name = name.replacingOccurrences(of: "ipad-", with: device + "-")
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            print("VISUAL \(name) app=\(app.frame) image=\(shot.image.size) orientation=\(shot.image.imageOrientation.rawValue)")
        }
        func verifyKeys() {
            for button in [app.buttons["conversation-attachments"],
                           app.buttons["conversation-ctrl"], app.buttons["Esc"],
                           app.buttons["更多快捷键"], app.buttons["向上"], app.buttons["向下"],
                           app.buttons["向左"], app.buttons["conversation-arrow-right"],
                           app.buttons["conversation-enter"],
                           app.buttons["conversation-keyboard-toggle"]] {
                XCTAssertTrue(button.isHittable, button.identifier)
                XCTAssertTrue(app.frame.contains(button.frame), "key must be fully inside the app: \(button.identifier)")
            }
        }
        submit("python3 /tmp/moshpit-ui-lab/visual-check.py screen", in: app)
        app.buttons["conversation-keyboard-toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        menu.tap()
        app.buttons["自动适配字号"].tap()
        verifyKeys()
        capture("ipad-portrait-font-colours-and-keys")
        app.buttons["conversation-sidebar"].tap()
        XCTAssertTrue(app.buttons["conversation-sidebar"].isSelected)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'spaces'")).count, 1,
            "workspace header must appear once even when several agents are present")
        XCTAssertTrue(app.buttons["conversation-sidebar-collapse"].isHittable)
        verifyKeys()
        capture("ipad-portrait-sidebar")
        app.buttons["conversation-sidebar"].tap()
        composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        verifyKeys()
        capture("ipad-portrait-software-keyboard")
        let more = app.buttons["更多快捷键"]
        let previousY = more.frame.minY
        more.tap()
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.frame.minY, previousY, accuracy: 1, "primary keys must not jump when extras open")
        XCTAssertTrue(app.buttons["conversation-extra-keys-close"].isHittable)
        capture("ipad-portrait-extra-shortcuts")
        app.buttons["conversation-extra-keys-close"].tap()
        verifyKeys()
        app.buttons["conversation-keyboard-toggle"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        menu.tap()
        app.buttons["自动适配字号"].tap()
        verifyKeys()
        capture("ipad-landscape-font-colours-and-keys")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        submit("python3 /tmp/moshpit-ui-lab/visual-check.py keys", in: app)
        for label in ["Esc", "向上", "向下", "向左"] { app.buttons[label].tap() }
        app.buttons["conversation-arrow-right"].tap()
        app.buttons["conversation-ctrl"].tap()
        app.typeText("c")
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: app.buttons["conversation-ctrl"])
        waitForExpectations(timeout: 5)
        capture("ipad-shortcut-actions-completed")
    }

    @MainActor
    func testImageUploadStagesInSharedDraftAndPlaneSends() throws {
        for mux in ["herdr", "none"] {
            let app = try openTerminal(multiplexer: mux, seedImage: true)
            let field = composer(app)
            expectation(for: NSPredicate { _, _ in
                (field.value as? String)?.contains("/IMG-") == true
            }, evaluatedWith: field)
            waitForExpectations(timeout: 30)
            let draft = try XCTUnwrap(field.value as? String)
            print("IMAGE_DRAFT_RECEIPT \(draft)")
            XCTAssertFalse(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(app.buttons["image-attach-send"].exists, "images use the same send button as text")
            XCTAssertFalse(app.buttons["image-attach-insert"].exists)
            app.buttons["conversation-send"].tap()
            expectation(for: NSPredicate { _, _ in (field.value as? String)?.isEmpty == true }, evaluatedWith: field)
            waitForExpectations(timeout: 15)
            app.terminate()
        }
    }

    @MainActor
    func testPlainSSHConfirmedSubmission() throws {
        let app = try openTerminal(multiplexer: "none")
        submit("printf 'SSH_COMPOSER_OK\\n' >> /tmp/moshpit-ui-lab/received.log", in: app)
    }
}
