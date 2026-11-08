import XCTest

final class WorkspaceReviewUITest: XCTestCase {
    @MainActor func testDiffAnnotationExportsToDraftAndHTMLRenders() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-HERMIT_WORKSPACE_REVIEW_FIXTURE"]
        app.launch()
        defer { app.terminate() }
        app.buttons["review-fixture-open"].tap()
        let change = app.buttons["git-change-Sources/demo.swift"]
        XCTAssertTrue(change.waitForExistence(timeout: 15))
        change.tap()
        let line = app.buttons["diff-annotate-8"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.tap()
        let alert = app.alerts["添加批注"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("Please verify cancellation")
        alert.buttons["添加"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["git-review-notes"].tap()
        let export = app.buttons["git-notes-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let draft = app.textViews["review-fixture-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        let value = try XCTUnwrap(draft.value as? String)
        XCTAssertTrue(value.contains("保留原有草稿"))
        XCTAssertTrue(value.contains("Sources/demo.swift:3"))
        XCTAssertTrue(value.contains("Please verify cancellation"))
        app.buttons["review-fixture-html"].tap()
        let web = app.webViews["static-html-content"]
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        XCTAssertTrue(web.staticTexts["Hermit 工作区报告"].waitForExistence(timeout: 10))
        XCTAssertFalse(web.staticTexts["UNSAFE SCRIPT RAN"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "static-html-report"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["static-html-close"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, value)
    }
}
