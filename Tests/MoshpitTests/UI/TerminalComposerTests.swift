import SwiftUI
import SwiftTerm
import Testing
import UIKit
@testable import Moshpit

@MainActor
@Suite("Terminal composer multiline drafts", .serialized)
struct TerminalComposerTests {
    @Test("Review language also applies to the Apple fallback without changing the saved request")
    func reviewLanguageMatchesFallback() {
        let saved = DictationRequest(engine: .whisper, appleLocaleId: "en-US", whisperLanguage: "en")
        let chinese = saved.selectingReviewLanguage("zh")
        #expect(chinese.whisperLanguage == "zh")
        #expect(chinese.appleLocaleId == "zh-CN")
        #expect(saved.appleLocaleId == "en-US")
        let automatic = chinese.selectingReviewLanguage("auto")
        #expect(automatic.appleLocaleId.isEmpty)
        #expect(automatic.whisperLanguage.isEmpty)
        let regional = saved.selectingReviewLanguage("en")
        #expect(regional.appleLocaleId == "en-US")
    }

    @Test("Recognition results cannot replace a manually edited review")
    func voiceReviewPreservesManualEdits() {
        var review = DictationReviewDraft()
        review.receive("最初识别")
        review.text = "我编辑的命令 --flag"
        review.receive("迟到的识别结果")
        #expect(review.text == "我编辑的命令 --flag")
        #expect(review.baseline == "最初识别")
        #expect(review.hasEdits)
        review.undoEdits()
        #expect(review.text == "最初识别")
        #expect(!review.hasEdits)
        review.receive("重新识别的结果")
        #expect(review.text == "重新识别的结果")
        #expect(!review.hasEdits)
    }

    @Test("Return inserts a newline and preserves the complete draft")
    func returnInsertsNewline() {
        var draft = ""
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {})
        let delegate = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = delegate
        view.text = "完整草稿 hello"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.insertText("\n")
        #expect(view.text == "完整草稿 hello\n")
        #expect(draft == view.text)
    }

    @Test("Multiline insertion preserves line breaks and updates the binding")
    func multilineInsertion() {
        var draft = ""
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {})
        let delegate = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = delegate
        view.insertText("first\nsecond\n")
        #expect(draft == "first\nsecond\n")
    }

    @Test("An empty draft can begin with a newline")
    func leadingNewline() {
        var draft = ""
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {})
        let delegate = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = delegate
        view.insertText("\n")
        #expect(draft == "\n")
    }

    @Test("An end caret follows externally appended voice text using UTF-16 offsets")
    func endCaretFollowsAppendedText() {
        for original in ["typed text", "中文 👩🏽‍💻"] {
            let view = ComposerTextView()
            view.text = original
            view.selectedRange = NSRange(location: (original as NSString).length, length: 0)
            let appended = original + " simulated voice"

            view.updateDraftText(appended)

            #expect(view.selectedRange == NSRange(location: (appended as NSString).length, length: 0))
            view.insertText("\nchecked")
            #expect(view.text == appended + "\nchecked",
                    "editing after a voice append must continue after the complete result")
        }
    }

    @Test("External additions preserve a caret deliberately placed inside the draft")
    func middleCaretRemainsAtEditPosition() {
        let view = ComposerTextView()
        view.text = "prefix suffix"
        view.selectedRange = NSRange(location: 6, length: 0)

        view.updateDraftText("prefix suffix appended")

        #expect(view.selectedRange == NSRange(location: 6, length: 0))
        view.insertText("!")
        #expect(view.text == "prefix! suffix appended")
    }

    @Test("Replacement preserves a selection and clamps it when the new draft is shorter")
    func selectionSurvivesReplacementWithinNewBounds() {
        let view = ComposerTextView()
        view.text = "0123456789"
        view.selectedRange = NSRange(location: 3, length: 4)

        view.updateDraftText("ABCDEFGHIJKLMNO")
        #expect(view.selectedRange == NSRange(location: 3, length: 4))

        view.updateDraftText("ABCDE")
        #expect(view.selectedRange == NSRange(location: 3, length: 2))

        view.updateDraftText("AB")
        #expect(view.selectedRange == NSRange(location: 2, length: 0))
        view.insertText("!")
        #expect(view.text == "AB!")
    }

    @Test("An unchanged draft leaves the current selection untouched")
    func identicalDraftPreservesSelection() {
        let view = ComposerTextView()
        view.text = "unchanged draft"
        view.selectedRange = NSRange(location: 2, length: 5)

        view.updateDraftText("unchanged draft")

        #expect(view.text == "unchanged draft")
        #expect(view.selectedRange == NSRange(location: 2, length: 5))
    }

    @Test("A temporary keyboard resignation preserves the draft's intended focus")
    func temporaryResignationPreservesFocusIntent() async {
        var focused = true
        var sheetOpen = false
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused && !sheetOpen }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { window.isHidden = true }
        #expect(view.becomeFirstResponder())
        sheetOpen = true
        #expect(view.resignFirstResponder())
        await drainMainQueue()
        #expect(focused, "A system menu must not rewrite the user's intended input target")
        #expect(dismissals == 0)
        sheetOpen = false
        delegate.updateFocus(view)
        await drainMainQueue()
        #expect(view.isFirstResponder)
    }

    @Test("A late didEnd callback cannot undo focus restoration after a picker")
    func lateDidEndPreservesRestoredFocus() async {
        var focused = true
        var sheetOpen = false
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused && !sheetOpen }, set: { focused = $0 }), onFocus: {})
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { window.isHidden = true }
        #expect(view.becomeFirstResponder())
        sheetOpen = true
        // Deliver UIKit's shouldEnd now, but hold didEnd until the picker has
        // restored the binding. This is one resignation, not a duplicate end.
        #expect(delegate.textViewShouldEndEditing(view))
        view.delegate = nil
        #expect(view.resignFirstResponder())
        view.delegate = delegate
        #expect(!view.isFirstResponder)
        #expect(focused)

        sheetOpen = false
        delegate.updateFocus(view)
        delegate.textViewDidEndEditing(view)
        await drainMainQueue()
        #expect(focused)
        #expect(view.isFirstResponder)
    }

    @Test("The system keyboard Hide key cancels queued focus and stays dismissed after a redraw")
    func systemKeyboardDismissalSurvivesRedraw() async {
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { window.isHidden = true }
        #expect(UIApplication.shared.applicationState == .active)
        view.text = "kept"
        #expect(view.becomeFirstResponder())
        delegate.updateFocus(view)
        // Unlike a picker, UIKit's own Hide key resigns without first changing
        // the app's intended focus. A redraw may already have queued a take.
        #expect(view.resignFirstResponder())
        delegate.updateFocus(view)
        await drainMainQueue()
        #expect(!focused)
        #expect(dismissals == 1)
        #expect(!view.isFirstResponder)
        delegate.updateFocus(view)
        await drainMainQueue()
        #expect(!view.isFirstResponder)
        #expect(view.text == "kept", "Resigning must preserve the unsent draft")
    }

    @Test("A Menu that presents after shouldEnd only borrows the composer's keyboard")
    func delayedMenuPresentationPreservesFocusIntent() async {
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { window.isHidden = true }
        let root = window.rootViewController!
        let menu = UIViewController()
        menu.modalPresentationStyle = .overFullScreen
        #expect(view.becomeFirstResponder())
        // The SwiftUI Menu need not have a presented controller at shouldEnd.
        // It installs one before the deferred didEnd decision is resolved.
        #expect(view.resignFirstResponder())
        root.present(menu, animated: false)
        await drainMainQueue()
        #expect(root.presentedViewController === menu)
        #expect(focused)
        #expect(dismissals == 0)
        delegate.updateFocus(view)
        await drainMainQueue()
        #expect(!view.isFirstResponder, "Focus must not be reclaimed underneath an open menu")

        root.dismiss(animated: false)
        // UIKit finishing the dismissal need not cause another SwiftUI update.
        for _ in 0..<25 {
            if view.isFirstResponder { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.isFirstResponder)
        #expect(focused)
        #expect(dismissals == 0)
    }

    @Test("Tapping the terminal still transfers keyboard ownership out of the draft")
    func terminalFocusHandoffIsRespected() async {
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { window.isHidden = true }
        let terminal = TerminalView(frame: CGRect(x: 0, y: 80, width: 300, height: 160))
        window.rootViewController?.view.addSubview(terminal)
        #expect(view.becomeFirstResponder())
        #expect(terminal.becomeFirstResponder())
        await drainMainQueue()
        #expect(!focused)
        #expect(dismissals == 0, "Moving input to the terminal must not hide its keyboard")
        delegate.updateFocus(view)
        await drainMainQueue()
        #expect(terminal.isFirstResponder)
        #expect(!view.isFirstResponder)
    }

    private func makeFocusFixture(delegate: TerminalComposerView.Coordinator) -> (UIWindow, ComposerTextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = ComposerTextView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        view.delegate = delegate
        controller.view.addSubview(view)
        return (window, view)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
