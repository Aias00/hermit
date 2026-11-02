import UIKit
import XCTest

final class RelayConnectionUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func waitForStableFrame(_ element: XCUIElement) {
        // A keyboard moves a centered iPad sheet upward. XCTest can report
        // idle while still holding its pre-keyboard hit-test coordinates.
        var previous = CGRect.null
        var stableSince = Date()
        let settled = NSPredicate { _, _ in
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            if frame != previous {
                previous = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor
    private func openRelay(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["home-add"].waitForExistence(timeout: 10))
        app.buttons["home-add"].tap()
        let picker = app.buttons["connection-transport-picker"].firstMatch
        reveal(picker, app: app)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let option = app.buttons["RemoteForge Relay"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        let pair = app.buttons["relay-open-pairing"].firstMatch
        reveal(pair, app: app)
        pair.tap()
        XCTAssertTrue(app.secureTextFields["relay-invitation-input"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testInvalidInvitationDoesNotContactNetworkAndCanCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)"]
        app.launch();defer { app.terminate() }
        openRelay(app)
        let field = app.secureTextFields["relay-invitation-input"]
        field.tap();field.typeText("invalid-offline-fixture")
        let parse = app.buttons["relay-parse-invitation"]
        waitForStableFrame(parse)
        XCTAssertTrue(parse.isEnabled)
        parse.tap()
        let reported = app.staticTexts["relay-pairing-error"].waitForExistence(timeout: 5)
        if !reported { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "relay-invalid-form"; shot.lifetime = .keepAlways; add(shot) }
        XCTAssertTrue(reported)
        XCTAssertFalse(app.buttons["relay-confirm-pairing"].exists)
        app.buttons["relay-cancel-pairing"].tap()
        XCTAssertTrue(app.buttons["relay-open-pairing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-connection"].isEnabled)
    }
    @MainActor
    func testPairSaveAndReopenWithoutExposingInvitation() throws {
        guard let path = ProcessInfo.processInfo.environment["MOSHPIT_RELAY_FIXTURE"] else {
            throw XCTSkip("Start the isolated Relay fixture for real UI pairing")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let invites = try XCTUnwrap(record["invitations"] as? [String: Any])
        let invite = try XCTUnwrap(invites["echo"] as? [String: Any])
        let uri = try XCTUnwrap(invite["uri"] as? String)
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF", "-MOSHPIT_RELAY_LOOPBACK_TESTS", "-AppleLanguages", "(en)"]
        app.launch();defer { UIPasteboard.general.items = [];app.terminate() }
        openRelay(app)
        // Paste through the actual user control without putting the capability
        // in typeText's XCTest activity log or a screenshot.
        UIPasteboard.general.string = uri
        app.buttons["relay-paste-invitation"].tap()
        let confirm = app.buttons["relay-confirm-pairing"]
        let parsed = confirm.waitForExistence(timeout: 5)
        if !parsed { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "relay-pair-form"; shot.lifetime = .keepAlways; add(shot) }
        XCTAssertTrue(parsed)
        XCTAssertTrue(app.descendants(matching: .any)["relay-confirm-server"].exists)
        confirm.tap()
        XCTAssertTrue(app.buttons["relay-open-pairing"].waitForExistence(timeout: 10))
        let save = app.buttons["save-connection"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let card = app.buttons["connection-card-swift-test"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.removeAll(where: { $0 == "-MOSHPIT_RESET" })
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.press(forDuration: 1)
        let edit = app.buttons["编辑主机"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let pair = app.buttons["relay-open-pairing"].firstMatch
        reveal(pair, app: app)
        XCTAssertTrue(app.buttons["save-connection"].isEnabled)
        XCTAssertFalse(app.staticTexts["relay-credential-status"].exists)
        pair.tap()
        let field = app.secureTextFields["relay-invitation-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue)
        XCTAssertFalse(app.buttons["relay-confirm-pairing"].exists)
    }
}
