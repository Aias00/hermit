import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Moshpit

@Suite("Pane-owned input and delivery", .serialized) @MainActor
struct TerminalDraftStateTests {
    private let first = TerminalInputTarget.pane(multiplexer: "herdr", id: "w1:p1")
    private let second = TerminalInputTarget.pane(multiplexer: "herdr", id: "w1:p2")

    @Test("Dial-time input binds once; pane text, selection and uploads stay independent")
    func draftOwnership() {
        let store = TerminalComposerDraftStore()
        let pending = store.current
        pending.text = "before attach"
        let a = store.select(first)
        #expect(a === pending)
        a.selection = NSRange(location: 3, length: 2)
        a.uploads.enqueue([URL(fileURLWithPath: "/first.txt")])
        let b = store.select(second)
        b.text = "other pane"
        #expect(b !== a)
        #expect(b.uploads.items.isEmpty)
        #expect(store.select(nil) === b, "an incomplete reconnect cannot bind to an unrelated shell")
        #expect(store.select(first) === a)
        #expect(a.text == "before attach")
        #expect(a.selection == NSRange(location: 3, length: 2))
        #expect(a.uploads.items.count == 1)
        #expect(store.select(.pane(multiplexer: "tmux", id: "w1:p1")) !== a)
    }

    @Test("Undo removes only the latest addition and restores its owning pane selection")
    func undoAdditionOwnership() {
        let store = TerminalComposerDraftStore()
        let a = store.select(first)
        a.text = "手写 😀 text"
        a.selection = NSRange(location: 3, length: 2)
        a.append(" 语音追加", kind: .voice)
        #expect(a.canUndoAddition && a.additionKind == .voice)
        a.append(" /uploads/file", kind: .attachment)
        let b = store.select(second)
        b.text = "另一个窗格"
        #expect(!b.canUndoAddition)
        a.undoAddition()
        #expect(a.text == "手写 😀 text 语音追加")
        #expect(a.selection == NSRange(location: 3, length: 2))
        #expect(!a.canUndoAddition)
        #expect(b.text == "另一个窗格")
    }

    @Test("Manual editing or submission revokes addition undo; caret at the end is restored")
    func undoCannotOverwriteEditsOrSentInput() async throws {
        let a = TerminalComposerDraftStore().select(first)
        a.text = "原文"
        a.append(" appended", kind: .voice)
        #expect(a.selection.location == (a.text as NSString).length)
        a.undoAddition()
        #expect(a.text == "原文" && a.selection.location == 2)
        a.append(" /file", kind: .attachment)
        a.text += " 手动修改"
        #expect(!a.canUndoAddition)
        a.undoAddition()
        #expect(a.text == "原文 /file 手动修改")
        a.append(" 新语音", kind: .voice)
        let attempt = try #require(a.beginSubmission(to: first, label: "A"))
        #expect(!a.canUndoAddition)
        await a.complete(attempt) { _, _ in throw SSHError.sessionClosed }
        a.undoAddition()
        #expect(a.requiresSendReview && a.text.hasSuffix("新语音"))
    }

    @Test("A submission captures text and target before async work and its ticket is single use")
    func immutableAttempt() async throws {
        let store = TerminalComposerDraftStore()
        let a = store.select(first)
        a.text = "original"
        let attempt = try #require(a.beginSubmission(to: first, label: "host / A"))
        a.text = "new draft"
        let b = store.select(second)
        b.text = "B"
        var calls = 0
        let send: (String, TerminalInputTarget) async throws -> Void = { text, target in
            calls += 1
            #expect(text == "original")
            #expect(target == first)
        }
        await a.complete(attempt, send: send)
        await a.complete(attempt, send: send)
        #expect(calls == 1)
        #expect(a.text == "new draft")
        #expect(a.delivery == .submitted)
        #expect(b.text == "B" && b.delivery == .idle)
        #expect(!a.isSending)
    }

    @Test("Unknown delivery retains input and blocks repeated Return until reviewed")
    func uncertainDelivery() async {
        let draft = TerminalComposerDraftStore().select(first)
        draft.text = "private command"
        var calls = 0
        await draft.submit(to: first, label: "A") { _, _ in
            calls += 1
            throw HerdrControlClient.SubmissionError.unconfirmed
        }
        #expect(draft.delivery == .unconfirmed)
        #expect(draft.text == "private command")
        #expect(!draft.isSending)
        await draft.submit(to: first, label: "A") { _, _ in calls += 1 }
        #expect(calls == 1)
        draft.resolveUnconfirmed(received: false)
        #expect(draft.text == "private command" && draft.delivery == .idle)
        #expect(calls == 1, "reviewing a result cannot replay remote input")
        await draft.submit(to: first, label: "A") { _, _ in calls += 1 }
        #expect(calls == 2 && draft.text.isEmpty && draft.delivery == .submitted)
    }

    @Test("Acknowledging receipt clears only the original unchanged draft")
    func reviewPreservesEdits() async {
        for edited in [false, true] {
            let draft = TerminalComposerDraftStore().select(first)
            draft.text = "old"
            await draft.submit(to: first, label: "A") { _, _ in throw SSHError.sessionClosed }
            #expect(draft.delivery == .unconfirmed)
            if edited { draft.text = "new text" }
            draft.resolveUnconfirmed(received: true)
            #expect(draft.text == (edited ? "new text" : ""))
            #expect(draft.delivery == .submitted)
        }
    }

    @Test("Known rejection preserves a retryable draft and target mismatch never writes")
    func rejectedTarget() async {
        let draft = TerminalComposerDraftStore().select(first)
        draft.text = "kept"
        var calls = 0
        await draft.submit(to: second, label: "B") { _, _ in calls += 1 }
        #expect(calls == 0 && draft.delivery == .failed)
        await draft.submit(to: first, label: "A") { _, _ in
            calls += 1
            throw HerdrControlClient.SubmissionError.rejected
        }
        #expect(calls == 1 && draft.delivery == .failed && !draft.requiresSendReview)
        #expect(draft.text == "kept")
    }

    @Test("Pane switching restores caret and removes old undo without replacing the responder")
    func editorSwitchesDrafts() throws {
        let store = TerminalComposerDraftStore()
        let a = store.select(first)
        a.text = "中文 😀 alpha"
        a.selection = NSRange(location: 3, length: 2)
        let b = store.select(second)
        b.text = "second"
        b.selection = NSRange(location: 2, length: 0)
        func editor(_ draft: TerminalComposerDraft) -> TerminalComposerView {
            TerminalComposerView(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                isFocused: .constant(true), onFocus: {}, onSubmit: {}, draft: draft)
        }
        let coordinator = editor(a).makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        view.restoreDraft(a.text, selection: a.selection)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { view.resignFirstResponder(); window.isHidden = true }
        #expect(view.becomeFirstResponder())
        coordinator.updateParent(editor(b), view: view)
        #expect(view.isFirstResponder)
        #expect(view.text == "second" && view.selectedRange.location == 2)
        view.insertText("!")
        #expect(b.text == "se!cond")
        coordinator.updateParent(editor(a), view: view)
        #expect(view.isFirstResponder)
        #expect(view.text == "中文 😀 alpha")
        #expect(view.selectedRange == NSRange(location: 3, length: 2))
        #expect(view.undoManager?.canUndo != true)
    }

    @Test("Programmatic draft handoff cannot carry a Pinyin composition into another pane")
    func markedTextBelongsToOldPane() {
        let store = TerminalComposerDraftStore()
        let a = store.select(first)
        let b = store.select(second)
        func editor(_ draft: TerminalComposerDraft) -> TerminalComposerView {
            TerminalComposerView(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                isFocused: .constant(false), onFocus: {}, onSubmit: {}, draft: draft)
        }
        let coordinator = editor(a).makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        coordinator.updateParent(editor(b), view: view)
        #expect(view.markedTextRange == nil)
        #expect(a.text == "拼音")
        #expect(b.text.isEmpty && view.text.isEmpty)
    }

    @Test("Upload and voice additions survive repeated IME callbacks, with or without a render")
    func markedTextPreservesExternalAdditions() {
        for renderBeforeEdit in [false, true] {
            let draft = TerminalComposerDraftStore().select(first)
            let editor = TerminalComposerView(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                isFocused: .constant(false), onFocus: {}, onSubmit: {}, draft: draft)
            let coordinator = editor.makeCoordinator()
            let view = ComposerTextView()
            view.delegate = coordinator
            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            coordinator.textViewDidChange(view)
            draft.text += " /uploads/file.txt"
            if renderBeforeEdit { coordinator.synchronizeDraft(view) }
            view.setMarkedText("nin", selectedRange: NSRange(location: 3, length: 0))
            coordinator.textViewDidChange(view)
            #expect(draft.text == "nin /uploads/file.txt")
            #expect(view.markedTextRange != nil)
            draft.text += " 语音补充"
            view.setMarkedText("您好", selectedRange: NSRange(location: 2, length: 0))
            coordinator.textViewDidChange(view)
            view.unmarkText()
            coordinator.textViewDidChange(view)
            #expect(draft.text == "您好 /uploads/file.txt 语音补充")
            #expect(view.text == draft.text)
            coordinator.synchronizeDraft(view)
            view.insertText("!")
            #expect(draft.text == "您好 /uploads/file.txt 语音补充!")
        }
    }

    @Test("Switching panes commits the old composition together with pending attachments")
    func markedTextHandoffPreservesExternalAdditions() {
        let store = TerminalComposerDraftStore()
        let a = store.select(first), b = store.select(second)
        func editor(_ draft: TerminalComposerDraft) -> TerminalComposerView {
            TerminalComposerView(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                isFocused: .constant(false), onFocus: {}, onSubmit: {}, draft: draft)
        }
        let coordinator = editor(a).makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(view)
        a.text += " /uploads/file.txt"
        coordinator.updateParent(editor(b), view: view)
        #expect(a.text == "拼音 /uploads/file.txt")
        #expect(b.text.isEmpty && view.text.isEmpty)
        coordinator.updateParent(editor(a), view: view)
        #expect(view.text == a.text)
    }
}
