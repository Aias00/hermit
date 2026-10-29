import Foundation
import Testing
import UIKit
import SwiftTerm
@testable import Moshpit

/// The keyboard cover's one decision: is this move worth hiding?
///
/// It exists because a resize makes the REMOTE app redraw, and we would
/// otherwise paint the half-erased screen it goes through (measured against a
/// real Claude Code pane: tmux's own copy loses its footer for ~50ms). Hiding
/// that is worth a beat of frozen picture. Hiding NOTHING is not — switching
/// input method fires the same notification with an identical frame, and
/// covering it just makes the switch feel slow.
@Suite("keyboard cover", .serialized)
@MainActor
struct KeyboardCoverTests {

    /// The coordinator intentionally holds its view/host weakly. Keep the
    /// complete window hierarchy alive so notifications and snapshots really run.
    private final class Harness {
        let coordinator = SwiftTerminalView.Coordinator()
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let container = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window: UIWindow

        init() {
            // Scene-less windows do not render on current iOS, so they cannot
            // exercise snapshotView or the release timer behind a real cover.
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
            } else {
                window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
            }
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(container)
            container.host(terminal)
            coordinator.attach(to: terminal)
            coordinator.hostContainer = container
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            coordinator.releaseKeyboardCover()
            coordinator.unlockFrame()
            window.isHidden = true
        }
    }

    private func post(begin: CGRect, end: CGRect) {
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: begin),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: end),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
    }

    @Test("An input-method switch — same frame both ends — is not covered")
    func sameFrameIsNotCovered() {
        let harness = Harness()
        defer { harness.close() }
        let up = CGRect(x: 0, y: 500, width: 320, height: 300)
        post(begin: up, end: up)
        #expect(harness.coordinator.coverRequests == 0,
                "covering a move that changes nothing just makes it feel slow")
        #expect(!harness.container.frameLocked, "an unchanged keyboard must not delay later layout")
    }

    @Test("A keyboard actually arriving is covered")
    func realMoveIsCovered() {
        let harness = Harness()
        defer { harness.close() }
        post(begin: CGRect(x: 0, y: 800, width: 320, height: 300),
             end: CGRect(x: 0, y: 500, width: 320, height: 300))
        #expect(harness.coordinator.coverRequests == 1)
        #expect(harness.container.frameLocked)
    }

    @Test("Herdr keeps output live during dismissal and reports the final viewport once")
    func remoteGridDismissalDoesNotTakeSnapshot() {
        let harness = Harness()
        defer { harness.close() }
        harness.coordinator.remoteGrid = (80, 30)
        harness.container.layoutIfNeeded()
        let originalFrame = harness.terminal.frame
        var reports = 0
        harness.coordinator.onViewportSizeChange = { _, _ in reports += 1 }
        post(begin: CGRect(x: 0, y: 500, width: 320, height: 300),
             end: CGRect(x: 0, y: 800, width: 320, height: 300))
        #expect(harness.coordinator.coverRequests == 0)
        #expect(!harness.coordinator.hasKeyboardCover)
        #expect(harness.container.frameLocked)
        for height: CGFloat in [520, 600, 720] {
            harness.container.frame.size.height = height
            harness.container.layoutIfNeeded()
        }
        #expect(harness.terminal.frame == originalFrame)
        #expect(reports == 0)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        harness.container.layoutIfNeeded()
        #expect(!harness.container.frameLocked)
        #expect(reports == 1)
        #expect(harness.terminal.getTerminal().cols == 80)
        #expect(harness.terminal.getTerminal().rows == 30)
    }

    @Test("A modal geometry hold does not take another terminal snapshot")
    func heldGeometryDoesNotTakeSnapshot() {
        let harness = Harness()
        defer { harness.close() }
        harness.container.geometryHeld = true
        post(begin: CGRect(x: 0, y: 500, width: 320, height: 300),
             end: CGRect(x: 0, y: 800, width: 320, height: 300))
        #expect(harness.coordinator.coverRequests == 0)
        #expect(!harness.coordinator.hasKeyboardCover)
    }

    @Test("Continuous output and repeated notifications cannot indefinitely hide the terminal")
    func streamingOutputCannotExtendCoverDeadline() async throws {
        let harness = Harness()
        defer { harness.close() }
        harness.coordinator.feed(data: Data("stream starts\r\n".utf8))
        // Let the visible window draw so this checks a real snapshot's lifetime.
        try await Task.sleep(for: .milliseconds(100))
        harness.coordinator.coverForKeyboard(duration: 0.25, options: [])
        try #require(harness.coordinator.hasKeyboardCover)
        let clock = ContinuousClock()
        let start = clock.now
        var repeatedNotification = false
        while start.duration(to: clock.now) < .seconds(2) {
            harness.coordinator.feed(data: Data("stream continues\r\n".utf8))
            if !repeatedNotification, start.duration(to: clock.now) > .milliseconds(800) {
                harness.coordinator.coverForKeyboard(duration: 0.25, options: [])
                repeatedNotification = true
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!harness.coordinator.hasKeyboardCover,
                "the original 1.6s deadline must expire even while output is arriving")
    }
}
