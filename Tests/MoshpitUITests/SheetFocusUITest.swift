import XCTest

/// Rig-only: tapping the window crumb opens the Windows sheet already
/// scrolled to the window you're on. With two dozen windows the current one
/// used to sit below the fold of the medium detent, and the first thing
/// anyone did was scroll looking for the checkmark (user report, 2026-10).
///
/// Needs the local rig (`/tmp/np/rig`: seed key + user, isolated tmux
/// wrapper on socket `moshpit-np` with a session of 24 windows `w1`…`w24`,
/// `w20` current, sshd on 127.0.0.1:22) — skips everywhere else.
final class SheetFocusUITest: XCTestCase {
    private static let rig = "/tmp/np/rig"

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    func testWindowsSheetOpensOnTheCurrentWindow() throws {
        guard let key = try? String(contentsOfFile: "\(Self.rig)/seedkey.b64", encoding: .utf8),
              let user = try? String(contentsOfFile: "\(Self.rig)/seeduser", encoding: .utf8),
              let fingerprint = try? String(contentsOfFile: "\(Self.rig)/hostfp", encoding: .utf8)
        else { throw XCTSkip("needs the local rig (\(Self.rig))") }

        let app = XCUIApplication()
        app.launchArguments += [
            "-MOSHPIT_RESET", "-MOSHPIT_SEED_HOME", "1", "-MOSHPIT_AUTOCARE_OFF",
            "-MOSHPIT_SEED_USER", user.trimmingCharacters(in: .whitespacesAndNewlines),
            "-MOSHPIT_SEED_KEY_B64", key.trimmingCharacters(in: .whitespacesAndNewlines),
            "-MOSHPIT_SEED_HOST", "127.0.0.1", "-MOSHPIT_SEED_PORT", "22",
            "-MOSHPIT_SEED_NAME", "np-lab", "-MOSHPIT_SEED_MUX", "tmux",
            "-MOSHPIT_SEED_TMUX_BIN", "\(Self.rig)/tmux", "-MOSHPIT_SEED_QUIET", "1",
            "-MOSHPIT_SEED_TRUST_FP", fingerprint.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        app.launch()

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'connection-card-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "home card missing")
        card.tap()   // offline → connect
        XCTAssertTrue(app.staticTexts["LIVE"].waitForExistence(timeout: 20), "never went live")
        if card.exists { card.tap() }   // live → enter

        // The crumb reads "20:w20" (no space); sheet rows read "20: w20, …".
        let crumb = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]+:w20$'")).firstMatch
        XCTAssertTrue(crumb.waitForExistence(timeout: 20), "window crumb for w20 never appeared")
        crumb.tap()
        // Not the "Swipe to switch" footer: it trails the last row, which is
        // exactly what scrolls away now.
        XCTAssertTrue(app.navigationBars["Windows"].waitForExistence(timeout: 5), "Windows sheet didn't open")
        sleep(1)
        shot(app, "windows-sheet")

        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS ': w20,'")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "row for the current window missing")
        XCTAssertTrue(current.isHittable, "the current window's row is off screen — the sheet opened at the top")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS ': w1,'")).firstMatch
        XCTAssertFalse(first.exists && first.isHittable, "the list never moved off its first row")
    }
}
