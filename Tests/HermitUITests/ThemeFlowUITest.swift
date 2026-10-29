import XCTest

/// End-to-end walk of the terminal-theme feature: gallery → duplicate a
/// built-in → edit it → save → confirm it became the selection, then import a
/// pasted palette and delete a theme.
///
/// Driven through accessibility identifiers rather than coordinates: the theme
/// rows are a scrolling list whose positions shift as custom themes are added,
/// and this suite has to keep passing when they do.
final class ThemeFlowUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings → Theme, returning the gallery's navigation bar.
    @MainActor
    private func openGallery(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["home-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let themeRow = app.staticTexts["Theme"]
        // The DISPLAY group sits below the fold on smaller devices.
        XCTAssertTrue(reveal(themeRow, in: app))
        themeRow.tap()

        let gallery = app.navigationBars["Theme"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3), "Theme row should push the gallery")
        return gallery
    }

    @MainActor
    func testGalleryListsBuiltInsAndSwitchesSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        _ = openGallery(app)

        // Every built-in is offered, by name.
        for name in ["GitHub Dark", "Dracula", "Tokyo Night"] {
            XCTAssertTrue(reveal(app.staticTexts[name], in: app))
        }
        // The iPad sheet only materializes the first few of nine built-ins.
        XCTAssertTrue(reveal(app.staticTexts["No custom themes yet."], in: app),
                      "A fresh install has no custom themes")

        // Picking one selects it: back in Settings the row shows the new name.
        let dracula = app.descendants(matching: .any).matching(identifier: "theme-row-dracula").firstMatch
        XCTAssertTrue(reveal(dracula, in: app))
        dracula.tap()
        app.navigationBars["Theme"].buttons.firstMatch.tap()      // back
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Dracula"].waitForExistence(timeout: 3),
                      "Settings' Theme row should reflect the picked theme")
    }

    @MainActor
    func testDuplicateEditAndSaveBecomesSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        _ = openGallery(app)

        // Long-press a built-in → Duplicate & Edit (the only route from a
        // read-only built-in to something editable).
        let duplicate = app.buttons["Duplicate & Edit"]
        let nord = app.descendants(matching: .any).matching(identifier: "theme-row-nord").firstMatch
        XCTAssertTrue(reveal(nord, in: app))
        pressForMenu(nord, until: duplicate)
        duplicate.tap()

        // The editor opens on a copy, pre-named and previewing live.
        XCTAssertTrue(app.navigationBars["Nord Copy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Background"].exists)
        XCTAssertTrue(reveal(app.staticTexts["Override bright colors"], in: app))
        XCTAssertFalse(app.staticTexts["Bright Black"].exists,
                       "Bright overrides start collapsed for a theme that has none")

        // Rename it so the assertion below can't accidentally match the source.
        let nameField = app.textFields["Theme name"]
        XCTAssertTrue(reveal(nameField, in: app))
        nameField.tap()
        nameField.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        nameField.typeText("Test Palette")

        app.buttons["theme-editor-save"].tap()

        // Saving both stores it and makes it the active theme.
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(app.staticTexts["Test Palette"], in: app))
        XCTAssertFalse(app.staticTexts["No custom themes yet."].exists)

        app.navigationBars["Theme"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Test Palette"].waitForExistence(timeout: 3),
                      "Editing a theme implies selecting it")
    }

    @MainActor
    func testImportPastedPaletteCreatesSelectableTheme() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        _ = openGallery(app)

        app.buttons["theme-add"].tap()
        let importButton = app.buttons["Import JSON…"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.tap()

        let editor = app.textViews["theme-import-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        // Shorthand keys and no id — the shape someone pastes from a gist.
        editor.typeText("""
        {"name":"Pasted VS","bg":"#1E1E1E","fg":"#D4D4D4","black":"#000000",\
        "red":"#CD3131","green":"#0DBC79","yellow":"#E5E510","blue":"#2472C8",\
        "magenta":"#BC3FBC","cyan":"#11A8CD","white":"#E5E5E5"}
        """)
        app.navigationBars["Import Theme"].buttons["Import"].tap()

        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(app.staticTexts["Pasted VS"], in: app),
                      "An imported theme should appear under MY THEMES and be selected")
    }

    @MainActor
    func testDeleteCustomThemeFallsBackToDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MOSHPIT_RESET"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        _ = openGallery(app)

        // Make a custom theme to delete.
        let monokai = app.descendants(matching: .any).matching(identifier: "theme-row-monokai").firstMatch
        XCTAssertTrue(reveal(monokai, in: app))
        pressForMenu(monokai, until: app.buttons["Duplicate & Edit"])
        app.buttons["Duplicate & Edit"].tap()
        XCTAssertTrue(app.navigationBars["Monokai Copy"].waitForExistence(timeout: 3))
        app.buttons["theme-editor-save"].tap()

        let copyRow = app.staticTexts["Monokai Copy"]
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(copyRow, in: app))

        let deleteButton = app.buttons["Delete"]
        pressForMenu(copyRow, until: deleteButton)
        deleteButton.tap()
        // Confirm in the app's own modal (the redesign replaced UIKit alerts
        // with the in-app modal system — XCUI's `app.alerts` no longer sees
        // it). The title wait doubles as proof the modal is up and the
        // context menu's identically-labelled Delete is gone.
        XCTAssertTrue(app.staticTexts["Delete Monokai Copy?"].waitForExistence(timeout: 3))
        app.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(reveal(app.staticTexts["No custom themes yet."], in: app))
        // Deleting the *selected* theme has to move the selection, or the
        // terminal would silently fall back with no visible reason.
        app.navigationBars["Theme"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Remote Navy"].waitForExistence(timeout: 3),
                      "Selection should fall back to the default theme")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        var towardTop = false
        for attempt in 0..<24 {
            let form = app.collectionViews.firstMatch
            guard form.exists else { return false }
            var visible = form.frame.intersection(app.frame).insetBy(dx: 10, dy: 10)
            for bar in app.navigationBars.allElementsBoundByIndex where bar.frame.intersects(visible) {
                let bottom = visible.maxY
                visible.origin.y = max(visible.minY, bar.frame.maxY)
                visible.size.height = max(0, bottom - visible.minY)
            }
            if app.keyboards.firstMatch.exists {
                visible.size.height = max(0, min(visible.maxY, app.keyboards.firstMatch.frame.minY - 54) - visible.minY)
            }
            guard visible.height > 80 else { return false }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty {
                if visible.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return true }
                towardTop = frame.midY < visible.midY
            } else if attempt == 8 || attempt == 16 { towardTop.toggle() }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = visible.minX + 4
            let from = visible.minY + visible.height * (towardTop ? 0.25 : 0.75)
            let to = visible.minY + visible.height * (towardTop ? 0.75 : 0.25)
            origin.withOffset(CGVector(dx: x, dy: from)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: to)))
        }
        return false
    }
}
