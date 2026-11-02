import XCTest

extension XCTestCase {
    /// Long-press `element` until `revealed` shows up — RETRIED, because on a
    /// loaded CI runner a synthesized long-press occasionally lands while the
    /// row is still settling and the context menu simply never opens. The
    /// press is the flaky half, not the wait: the same test went green at
    /// 17:39 and red at 17:53 on identical code (2026-08-16) before every
    /// context-menu site was routed through here.
    func pressForMenu(_ element: XCUIElement,
                      until revealed: XCUIElement,
                      attempts: Int = 3,
                      _ message: String = "context menu should appear") {
        for attempt in 1...attempts {
            element.press(forDuration: 1.3)
            if revealed.waitForExistence(timeout: 3) { return }
            XCTAssertTrue(attempt < attempts, message)
        }
    }
}

extension XCUIApplication {
    /// Scroll until `element` is on screen and returns whether it got there.
    ///
    /// The app's forms are `Form`/`List`, which materialise rows lazily: a row
    /// below the fold is not in the accessibility tree at all, so `.exists`
    /// on it is false until the list has scrolled it into view. Swipes up
    /// first (most targets sit further down a form), then back down.
    @discardableResult
    func reveal(_ element: XCUIElement, up: Int = 6, down: Int = 8) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<up {
            swipeUp()
            if element.exists && element.isHittable { return true }
        }
        for _ in 0..<down {
            swipeDown()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }
}

/// Form coordinates must exclude navigation chrome and the software keyboard.
/// Scope scrolling to the presented form, never the settings page behind it.
@MainActor
enum FormInteraction {
    private static func form(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        if element.exists {
            let key = element.identifier.isEmpty ? element.label : element.identifier
            if !key.isEmpty,
               let containing = app.collectionViews.containing(.any, identifier: key)
                .allElementsBoundByIndex.reversed().first(where: { $0.isHittable }) {
                return containing
            }
        }
        return app.collectionViews.allElementsBoundByIndex.reversed().first(where: { $0.isHittable })
            ?? app.scrollViews.allElementsBoundByIndex.reversed().first(where: { $0.isHittable })
    }

    private static func viewport(of form: XCUIElement, in app: XCUIApplication) -> CGRect {
        var visible = form.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
        for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable {
            let frame = bar.frame
            if frame.intersects(visible), frame.minY <= visible.minY + 80 {
                let top = max(visible.minY, frame.maxY + 8)
                visible = CGRect(x: visible.minX, y: top, width: visible.width,
                                 height: max(0, visible.maxY - top))
            }
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.intersects(visible) {
            visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY - 54) - visible.minY)
        }
        return visible
    }

    static func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) -> Bool {
        var upward = towardTop
        for attempt in 0...28 {
            guard let form = form(for: element, in: app) else { return element.exists && element.isHittable }
            let visible = viewport(of: form, in: app)
            guard visible.height > 70 else { return false }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty {
                if visible.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return true }
                upward = frame.midY < visible.midY
            } else if attempt == 12 { upward.toggle() }
            // The gutter avoids changing sliders, toggles or editor selections.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = visible.minX + 4
            let fromY = visible.minY + visible.height * (upward ? 0.25 : 0.8)
            let toY = visible.minY + visible.height * (upward ? 0.8 : 0.25)
            origin.withOffset(CGVector(dx: x, dy: fromY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: toY)))
        }
        return false
    }

    static func waitForStableFrame(_ element: XCUIElement) -> Bool {
        var previous = CGRect.null
        var stableSince = Date()
        let predicate = NSPredicate { _, _ in
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            if frame != previous {
                previous = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8) == .completed
    }

    static func tap(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) -> Bool {
        guard reveal(element, in: app, towardTop: towardTop), waitForStableFrame(element),
              reveal(element, in: app, towardTop: towardTop) else { return false }
        element.tap()
        return true
    }

    static func focus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<2 {
            if field.exists, focused.evaluate(with: field) { return true }
            guard reveal(field, in: app), waitForStableFrame(field), reveal(field, in: app) else { return false }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 5) == .completed {
                return true
            }
        }
        return false
    }
}
