import XCTest

/// Settings › FEEDBACK lists both channels: mail, and a GitHub Issue that
/// opens outside the app. The group sits below the fold of the settings
/// form — rows there are not in the accessibility tree until scrolled into
/// view — so this scrolls to it and keeps a screenshot, which on a headless
/// simulator is the only way to look at that part of the form.
final class SettingsFeedbackUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchIntoSettings(languages: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        if !languages.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(languages.joined(separator: ", ")))"]
        }
        app.launch()
        app.buttons["主机与设置"].tap()
        app.buttons["launchpad-tab-2"].tap()
        app.buttons["home-settings"].tap()
        return app
    }

    private func keep(_ app: XCUIApplication, as name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testFeedbackGroupListsMailAndGitHub() throws {
        let app = launchIntoSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let issue = app.buttons["settings-github-issue"]
        XCTAssertTrue(app.reveal(issue), "the GitHub row should scroll into view")
        XCTAssertTrue(app.buttons["settings-feedback"].exists, "mail stays the first row")
        XCTAssertTrue(issue.label.contains("Open a GitHub Issue"), issue.label)
        keep(app, as: "settings-feedback-en")
    }

    /// The zh-Hans copy is written, not translated: the row should say what a
    /// Chinese app would, and the same identifier must still find it.
    @MainActor
    func testFeedbackGroupReadsNativelyInSimplifiedChinese() throws {
        let app = launchIntoSettings(languages: ["zh-Hans"])
        let issue = app.buttons["settings-github-issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5) || app.reveal(issue),
                      "the GitHub row should scroll into view")
        XCTAssertTrue(issue.label.contains("去 GitHub 提 Issue"), issue.label)
        keep(app, as: "settings-feedback-zh-Hans")
    }
}
