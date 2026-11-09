import XCTest

/// Explicit isolated fixture only. The short-lived receiver credential is
/// written by the verification harness, never compiled into the app, and is
/// revoked and removed after the test. No production SSH session is opened.
final class DiagnosticReportingUITest: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testConsentedBackgroundUploadReceivesRealHTTPSAcknowledgement() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires an isolated simulator")
        #endif
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = workspace.appendingPathComponent("hermit-relay-verification/diagnostic-reporting/ui-fixture.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Explicit receiver fixture is not configured") }
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: String])
        let endpoint = try XCTUnwrap(values["endpoint"])
        let token = try XCTUnwrap(values["token"])
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8)); settings.tap()
        let diagnostics = app.buttons["settings-diagnostic-reporting"].firstMatch
        reveal(diagnostics, app: app); diagnostics.tap()
        let reset = app.buttons["diagnostics-forget"]
        reveal(reset, app: app); reset.tap()
        XCTAssertTrue(app.staticTexts["本地诊断记录和接收端绑定已清除。"].waitForExistence(timeout: 5))
        // Exercise the same dedicated app link produced by the owner-only
        // setup page. No credential needs to be pasted into a password field.
        var link = URLComponents(); link.scheme = "hermit-diagnostics"; link.host = "diagnostics"; link.path = "/configure"
        link.queryItems = [.init(name: "endpoint", value: endpoint), .init(name: "token", value: token)]
        app.open(try XCTUnwrap(link.url))
        let enable = app.buttons["diagnostics-confirm-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5), "configuration must require explicit consent")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "diagnostic-reporting-consent"; shot.lifetime = .keepAlways; add(shot)
        enable.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: enable)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        // Opening a URL can bring a different navigation destination forward.
        if !app.navigationBars["自动诊断上报"].exists {
            if app.buttons["home-settings"].exists, app.buttons["home-settings"].isHittable {
                app.buttons["home-settings"].tap()
            }
            let entry = app.buttons["settings-diagnostic-reporting"].firstMatch
            reveal(entry, app: app); entry.tap()
        }
        let acknowledged = app.descendants(matching: .any)["diagnostics-last-success"].firstMatch
        XCTAssertTrue(acknowledged.waitForExistence(timeout: 45), "system-owned HTTPS upload must receive the exact batch acknowledgement")
        let success = XCTAttachment(screenshot: app.screenshot()); success.name = "diagnostic-reporting-acknowledged"; success.lifetime = .keepAlways; add(success)
        let forget = app.buttons["diagnostics-forget"]
        reveal(forget, app: app); forget.tap()
        let disabled = app.descendants(matching: .any)["diagnostics-enabled-state"].firstMatch
        reveal(disabled, app: app)
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "未开启"), object: disabled)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        var upward = false
        for attempt in 0..<16 {
            let top = max(app.frame.minY + 120, app.navigationBars.firstMatch.frame.maxY + 8)
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY - 30
            if element.exists, element.isHittable, element.frame.midY > top, element.frame.midY < bottom { return }
            if element.exists, !element.frame.isEmpty { upward = element.frame.midY < (top + bottom) / 2 }
            else if attempt == 8 { upward.toggle() }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: 10, dy: top + (bottom - top) * (upward ? 0.25 : 0.8)))
            let end = origin.withOffset(CGVector(dx: 10, dy: top + (bottom - top) * (upward ? 0.8 : 0.25)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
