import XCTest

final class HostSearchUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Host search fixtures reset app data; run on a dedicated simulator only")
        #endif
    }

    @MainActor
    func testSearchFiltersSavedHostsAndCanBeCleared() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MOSHPIT_RESET", "-MOSHPIT_AUTOCARE_OFF",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        addHost("Production Mini", address: "prod.example.invalid", username: "alice", in: app)
        addHost("Staging", address: "stage.example.invalid", username: "builder", in: app)
        let production = app.buttons["connection-card-Production Mini"]
        let staging = app.buttons["connection-card-Staging"]
        XCTAssertTrue(production.exists)
        XCTAssertTrue(staging.exists)
        XCTAssertTrue(production.staticTexts["alice@prod.example.invalid"].exists)

        search("production", in: app)
        XCTAssertTrue(production.exists)
        XCTAssertFalse(staging.exists)
        search("BUILDER", in: app)
        XCTAssertTrue(staging.exists)
        XCTAssertFalse(production.exists)
        search("prod.example", in: app)
        XCTAssertTrue(production.exists)
        XCTAssertFalse(staging.exists)
        search("direct", in: app)
        XCTAssertTrue(production.exists)
        XCTAssertTrue(staging.exists)

        search("production builder", in: app)
        XCTAssertFalse(production.exists)
        XCTAssertFalse(staging.exists)
        XCTAssertTrue(app.staticTexts["No matching hosts"].exists)
        XCTAssertTrue(app.buttons["home-clear-search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home-clear-search"].isHittable)
        XCTAssertFalse(app.buttons["home-add-empty"].exists, "No matches must not imply there are no saved hosts")
        app.buttons["home-clear-search"].tap()
        XCTAssertTrue(production.waitForExistence(timeout: 3))
        XCTAssertTrue(staging.exists)

        search("staging", in: app)
        dismissSearch(in: app)
        XCTAssertTrue(production.waitForExistence(timeout: 3))
        XCTAssertTrue(staging.exists)
        XCTAssertTrue(app.buttons["home-add"].isHittable)
        XCTAssertTrue(app.buttons["home-settings"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "host-search-cleared"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func addHost(_ name: String, address: String, username: String, in app: XCUIApplication) {
        let add = app.buttons["home-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        for (field, value) in [("Name", name), ("Host", address), ("Username", username)] {
            let input = app.textFields[field]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            input.typeText(value)
        }
        app.buttons["save-connection"].tap()
        XCTAssertTrue(app.buttons["connection-card-\(name)"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func search(_ query: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let clear = field.buttons.firstMatch
        if clear.exists {
            clear.tap()
            // The iPad sidebar can dismiss native search focus when clearing
            // its query; acquire the field again before entering another one.
            field.tap()
        }
        field.typeText(query)
        XCTAssertEqual(field.value as? String, query)
    }

    @MainActor
    private func dismissSearch(in app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Sidebar search stays embedded on iPad and has no Cancel/Close
            // button. Clear the query and dismiss its native keyboard instead.
            let clear = app.searchFields.firstMatch.buttons.firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 3))
            clear.tap()
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() }
            return
        }
        // Recent iOS releases present the system search dismissal as an X
        // labeled Close rather than the older Cancel button. Keep the actual
        // accessibility labels in the report if another OS changes this again.
        let inventory = app.buttons.allElementsBoundByIndex.map {
            "identifier=\($0.identifier.debugDescription), label=\($0.label.debugDescription)"
        }.joined(separator: "\n")
        print("Host search dismissal buttons:\n\(inventory)")
        let attachment = XCTAttachment(string: inventory)
        attachment.name = "host-search-dismissal-buttons"
        attachment.lifetime = .keepAlways
        add(attachment)

        let names = ["Cancel", "Close", "Close Search", "Close search"]
        let dismiss = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", names, names)).firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3), "Missing native search dismissal control:\n\(inventory)")
        XCTAssertTrue(dismiss.isHittable)
        dismiss.tap()
    }
}
