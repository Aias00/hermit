import XCTest

/// Offline UI checks on a dedicated simulator. No iCloud account, network
/// result or sync status is injected, and this suite never enables syncing.
final class CloudSyncSettingsUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test resets saved hosts; use a dedicated simulator")
        #endif
    }

    @MainActor
    func testCloudSyncSettingsInEnglish() throws {
        try verifySettings(copy: .english)
    }

    @MainActor
    func testCloudSyncSettingsInSimplifiedChinese() throws {
        try verifySettings(copy: .chinese)
    }

    @MainActor
    private func verifySettings(copy: Copy) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
            "-AppleLanguages", "(\(copy.language))", "-AppleLocale", copy.locale]
        // Do not set moshpit.icloud defaults through launch arguments: the
        // initial values and the signing capability must come from the app.
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        app.buttons["home-settings"].tap()
        let entry = app.buttons["settings-icloud-sync"].firstMatch
        XCTAssertTrue(reveal(entry, in: app))
        XCTAssertTrue(entry.label.contains(copy.title), "The entry must use the selected language")
        entry.tap()
        let navigation = app.navigationBars[copy.title]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))

        let enabled = app.switches["icloud-sync-enabled"]
        let credentials = app.switches["icloud-sync-credentials"]
        XCTAssertTrue(reveal(enabled, in: app))
        XCTAssertEqual(enabled.value as? String, "0", "iCloud sync is opt-in by default")
        XCTAssertTrue(reveal(credentials, in: app))
        XCTAssertEqual(credentials.value as? String, "1", "Credential sync defaults to on, as requested")
        XCTAssertTrue(credentials.label.contains(copy.credentials))
        let available = enabled.isEnabled
        XCTAssertEqual(credentials.isEnabled, available,
                       "Both switches must respect this build's actual iCloud capability")
        capture(app, name: "icloud-\(copy.language)-defaults")

        // SwiftUI exposes LabeledContent as a combined accessibility row on
        // some runtimes; the value need not be a separate StaticText.
        let lastSync = try labeledRowText("icloud-last-sync", in: app)
        XCTAssertTrue(lastSync.contains(copy.notSynced),
                      "A fresh test install must not claim a successful sync: \(lastSync)")
        let syncNow = app.buttons["icloud-sync-now"]
        XCTAssertTrue(reveal(syncNow, in: app))
        XCTAssertFalse(syncNow.isEnabled, "Manual sync remains disabled while the main switch is off")

        if !available {
            let status = app.staticTexts["icloud-sync-status"].firstMatch
            XCTAssertTrue(reveal(status, in: app), "An unavailable build needs a visible explanation")
            XCTAssertTrue(status.label.contains(copy.unavailableFragment), status.label)
            XCTAssertTrue(status.label.contains("CloudKit"), status.label)
        } else {
            // A future CloudKit-enabled build takes this branch naturally.
            // Merely opening settings must neither enable sync nor upload data.
            let status = app.staticTexts["icloud-sync-status"].firstMatch
            if status.exists {
                XCTAssertFalse(status.label.contains(copy.unavailableFragment))
            }
        }
        capture(app, name: "icloud-\(copy.language)-capability-status")
        let capability = XCTAttachment(string: "iCloud controls enabled by actual build: \(available)")
        capability.name = "icloud-\(copy.language)-capability"
        capability.lifetime = .keepAlways
        add(capability)

        // Reset clears hosts and custom themes, but deliberately leaves SSH
        // key material alone. Check that each count is visible and numeric.
        try assertCountRow("icloud-count-hosts", expected: 0, in: app)
        try assertCountRow("icloud-count-keys", expected: nil, in: app)
        try assertCountRow("icloud-count-themes", expected: 0, in: app)
        try assertCountRow("icloud-count-shortcuts", expected: nil, in: app)
        let appearance = try labeledRowText("icloud-appearance", in: app)
        XCTAssertTrue(appearance.contains(copy.included), appearance)
        capture(app, name: "icloud-\(copy.language)-local-counts")

        navigation.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-icloud-sync"].waitForExistence(timeout: 5))
        let activity = app.switches["settings-live-activity"]
        XCTAssertTrue(reveal(activity, in: app))
        XCTAssertTrue(activity.isEnabled)
        let original = try XCTUnwrap(activity.value as? String)
        XCTAssertTrue(["0", "1"].contains(original))
        activity.tap()
        assertValue(original == "1" ? "0" : "1", of: activity)
        capture(app, name: "icloud-\(copy.language)-live-activity-round-trip")
        activity.tap()
        assertValue(original, of: activity)
    }

    @MainActor
    private func assertCountRow(_ label: String, expected: Int?, in app: XCUIApplication) throws {
        let text = try labeledRowText(label, in: app)
        let range = try XCTUnwrap(text.range(of: "[0-9]+", options: .regularExpression),
                                 "The \(label) row must expose its numeric count: \(text)")
        let count = try XCTUnwrap(Int(text[range]))
        XCTAssertGreaterThanOrEqual(count, 0)
        if let expected { XCTAssertEqual(count, expected, label) }
    }

    @MainActor
    private func labeledRowText(_ title: String, in app: XCUIApplication) throws -> String {
        let row = app.descendants(matching: .any).matching(identifier: title).firstMatch
        guard reveal(row, in: app, requiresHitTest: false) else {
            captureFailure(app, name: "icloud-missing-row-\(title)")
            XCTFail("Missing labeled row: \(title)")
            throw RowNotFound()
        }
        let cell = app.cells.containing(.any, identifier: row.label).firstMatch
        let container = cell.exists ? cell : row
        let elements = [container] + container.descendants(matching: .any).allElementsBoundByIndex
        return elements.map { $0.label + " " + (($0.value as? String) ?? "") }
            .joined(separator: " ")
    }

    private struct RowNotFound: Error {}

    @MainActor
    private func assertValue(_ value: String, of element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                     timeout: 3), .completed)
    }

    /// Form rows are lazy and disabled switches can be visible but not
    /// hittable. Scroll in the leading gutter, away from the settings slider.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, requiresHitTest: Bool = true) -> Bool {
        let form = app.collectionViews.firstMatch
        var towardTop = false
        for attempt in 0...8 {
            if element.exists, element.isHittable { return true }
            if element.exists, (!requiresHitTest || !element.isEnabled), !element.frame.isEmpty,
               app.frame.intersection(form.frame).contains(CGPoint(x: element.frame.midX,
                                                                  y: element.frame.midY)) { return true }
            if attempt == 8 { break }
            if element.exists, !element.frame.isEmpty {
                towardTop = element.frame.midY < form.frame.midY
            } else if attempt == 4 {
                towardTop.toggle()
            }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardTop ? 0.3 : 0.78))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardTop ? 0.78 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return false
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureFailure(_ app: XCUIApplication, name: String) {
        capture(app, name: name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private struct Copy {
        let language: String
        let locale: String
        let title: String
        let credentials: String
        let lastSync: String
        let notSynced: String
        let unavailableFragment: String
        let hosts: String
        let keys: String
        let themes: String
        let shortcuts: String
        let appearance: String
        let included: String

        static let english = Copy(language: "en", locale: "en_US", title: "iCloud Sync",
            credentials: "Sync SSH Credentials", lastSync: "Last successful sync", notSynced: "Not synced yet",
            unavailableFragment: "not signed for iCloud", hosts: "SSH Hosts", keys: "Portable SSH Keys",
            themes: "Custom Themes", shortcuts: "Keyboard Shortcuts", appearance: "Terminal Appearance",
            included: "Included")
        static let chinese = Copy(language: "zh-Hans", locale: "zh_CN", title: "iCloud 同步",
            credentials: "同步 SSH 凭据", lastSync: "上次成功同步", notSynced: "尚未同步", unavailableFragment: "未启用 iCloud 签名",
            hosts: "SSH 主机", keys: "可迁移的 SSH 密钥", themes: "自定义主题", shortcuts: "键盘快捷键",
            appearance: "终端外观", included: "已包含")
    }
}
