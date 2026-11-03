import SwiftUI
import SwiftTerm
import Testing
import UIKit
@testable import Moshpit

@MainActor
@Suite("Terminal composer multiline drafts", .serialized)
struct TerminalComposerTests {
    @Test("An empty draft lends Delete and arrows to the remote without acquiring terminal focus")
    func emptyDraftRemoteEditing() throws {
        let view = ComposerTextView()
        var deletes = 0
        var arrows: [String] = []
        view.onEmptyDelete = { deletes += 1 }
        view.onEmptyArrow = { arrows.append($0) }
        #expect(view.hasText, "keep software Delete available for the remote input")
        view.deleteBackward()
        view.deleteBackward()
        let left = try #require(view.keyCommands?.first { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags.isEmpty })
        _ = view.perform(left.action, with: left)
        #expect(deletes == 2)
        #expect(arrows == ["left"])
        #expect(view.text.isEmpty)
        #expect(!view.isFirstResponder)
    }

    @Test("Deleting a local draft cannot continue into the remote during key repeat")
    func deletionStopsAtLocalBoundary() throws {
        let view = ComposerTextView()
        var remoteDeletes = 0
        view.onEmptyDelete = { remoteDeletes += 1 }
        view.onEmptyArrow = { _ in }
        view.insertText("字😀")
        #expect(view.keyCommands?.contains { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags.isEmpty } == false)
        for _ in 0..<10 { view.deleteBackward() }
        #expect(view.text.isEmpty)
        #expect(remoteDeletes == 0)
        #expect(!view.hasText, "repeat must stop once the local draft is erased")
        let left = try #require(view.keyCommands?.first { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags.isEmpty })
        _ = view.perform(left.action, with: left)
        view.deleteBackward()
        #expect(remoteDeletes == 1, "an explicit remote navigation enables remote editing again")
    }

    @Test("Marked text keeps deletion and navigation inside the IME")
    func remoteKeysDoNotEscapeComposition() {
        let view = ComposerTextView()
        var events = 0
        view.onEmptyDelete = { events += 1 }
        view.onEmptyArrow = { _ in events += 1 }
        view.onControlKey = { _ in events += 1 }
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        #expect(view.keyCommands?.contains { $0.action == NSSelectorFromString("emptyArrow:") || $0.action == NSSelectorFromString("controlKey:") } == false)
        view.deleteBackward()
        #expect(events == 0)
    }

    @Test("Remote Ctrl preserves a parked draft; literal paste is never consumed as Ctrl")
    func controlPreservesDraftAndPaste() throws {
        var draft = ""
        var controls: [UInt8] = []
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {}, onControlKey: { controls.append($0) },
            consumeControlText: { text in
                guard text == "c" else { return false }
                controls.append(3)
                return true
            })
        let delegate = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = delegate
        delegate.configureReturn(view)
        view.insertText("kept draft")
        view.insertText("c")
        #expect(draft == "kept draft")
        let ctrlR = try #require(view.keyCommands?.first { $0.input == "r" && $0.modifierFlags == .control })
        _ = view.perform(ctrlR.action, with: ctrlR)
        #expect(controls == [3, 18])
        let escape = try #require(view.keyCommands?.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
        _ = view.perform(escape.action, with: escape)
        #expect(controls == [3, 18, 27])
        UIPasteboard.general.string = "c"
        defer { UIPasteboard.general.items = [] }
        view.paste(nil)
        #expect(draft == "kept draftc")
        #expect(controls == [3, 18, 27])
    }

    @Test("A committed Ctrl candidate leaves no marked letter in the local draft")
    func committedControlCandidateDoesNotPolluteDraft() {
        var draft = ""
        var controls = 0
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {}, consumeControlText: { text in
                guard text == "c" else { return false }
                controls += 1
                return true
            })
        let delegate = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = delegate
        delegate.configureReturn(view)
        view.insertText("kept draft ")
        view.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0))
        #expect(controls == 0, "Pinyin candidates cannot issue remote controls")
        view.insertText("c")
        #expect(controls == 1)
        #expect(view.markedTextRange == nil)
        #expect(view.text == "kept draft ")
        #expect(draft == "kept draft ")
    }

    @Test("Return submits the latest draft once without inserting a line break")
    func returnSubmitsDraft() {
        var draft = ""
        var submissions: [String] = []
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), onFocus: {}, onSubmit: { submissions.append(draft) })
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        coordinator.configureReturn(view)
        view.insertText("中文 😀 complete draft")
        view.insertText("\n")
        #expect(submissions == ["中文 😀 complete draft"])
        #expect(view.text == "中文 😀 complete draft", "the send owner alone clears acknowledged text")
        #expect(view.returnKeyType == .send)
    }

    @Test("A second Return cannot resurrect a draft acknowledged before the next UI render")
    func acknowledgedDraftIsNotRestoredFromStaleView() {
        var draft = ""
        var submissions: [String] = []
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {}, onSubmit: {
                submissions.append(draft)
                draft = ""
            })
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        coordinator.configureReturn(view)
        view.insertText("send once")
        view.insertText("\n")
        #expect(draft.isEmpty)
        #expect(view.text == "send once", "simulate the pending SwiftUI update")
        view.insertText("\n")
        #expect(submissions == ["send once", ""])
        #expect(draft.isEmpty)
    }

    @Test("Shift+Return and the explicit New line action edit at the caret without submitting")
    func explicitLineBreakDoesNotSubmit() throws {
        var draft = ""
        var submissions = 0
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {}, onSubmit: { submissions += 1 })
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        coordinator.configureReturn(view)
        view.insertText("first second")
        view.selectedRange = NSRange(location: 5, length: 0)
        view.insertDraftLineBreak()
        #expect(draft == "first\n second")
        let shift = try #require(view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift })
        _ = view.perform(shift.action, with: shift)
        #expect(draft == "first\n\n second")
        #expect(submissions == 0)
    }

    @Test("A Return confirms marked Chinese text without submitting; the next Return submits")
    func compositionConfirmationDoesNotSend() {
        var draft = ""
        var submissions: [String] = []
        let editor = TerminalComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), onFocus: {}, onSubmit: { submissions.append(draft) })
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        coordinator.configureReturn(view)
        view.setMarkedText("正在确认", selectedRange: NSRange(location: 4, length: 0))
        #expect(view.markedTextRange != nil)
        view.insertText("\n")
        #expect(submissions.isEmpty)
        #expect(view.markedTextRange == nil)
        #expect(view.text == "正在确认")
        view.insertText("\n")
        #expect(submissions == ["正在确认"])
    }

    @Test("Pasting paragraphs or a single newline never invokes the Return submit action")
    func pasteDoesNotSend() {
        let view = ComposerTextView()
        var submissions = 0
        view.onReturn = { submissions += 1 }
        UIPasteboard.general.string = "first\nsecond\n"
        defer { UIPasteboard.general.items = [] }
        view.paste(nil)
        #expect(view.text == "first\nsecond\n")
        UIPasteboard.general.string = "\n"
        view.paste(nil)
        #expect(view.text == "first\nsecond\n\n")
        #expect(submissions == 0)
    }

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
        await waitForActiveApplication()
        var focused = true
        var sheetOpen = false
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused && !sheetOpen }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { dismissFocusFixture(window) }
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
        await waitForActiveApplication()
        var focused = true
        var sheetOpen = false
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused && !sheetOpen }, set: { focused = $0 }), onFocus: {})
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { dismissFocusFixture(window) }
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
        await waitForActiveApplication()
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { dismissFocusFixture(window) }
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
        await waitForActiveApplication()
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { dismissFocusFixture(window) }
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
        await waitForActiveApplication()
        var focused = true
        var dismissals = 0
        let editor = TerminalComposerView(text: .constant("kept"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onFocus: {}, onKeyboardDismiss: { dismissals += 1 })
        let delegate = editor.makeCoordinator()
        let (window, view) = makeFocusFixture(delegate: delegate)
        defer { dismissFocusFixture(window) }
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
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = ComposerTextView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        view.delegate = delegate
        controller.view.addSubview(view)
        return (window, view)
    }

    private func dismissFocusFixture(_ window: UIWindow) {
        window.isHidden = true
        // Return the scene's keyboard to its real host window between tests.
        window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
    }

    private func waitForActiveApplication() async {
        // Hosted tests can begin before the cold-launched app receives its
        // foreground notification. Focus assertions require an active app.
        for _ in 0..<100 {
            if UIApplication.shared.applicationState == .active { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(UIApplication.shared.applicationState == .active)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
