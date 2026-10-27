import SwiftUI
import Testing
import UIKit
@testable import Moshpit

@MainActor
@Suite("Terminal composer multiline drafts")
struct TerminalComposerTests {
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
}
