import Foundation
import Testing
import UIKit
@testable import SwiftTerm
@testable import Moshpit

/// What the terminal says back to a keyboard, and what a keyboard's own edits
/// send to the remote.
///
/// UIKit deletes one character for a third-party keyboard (豆包, and any other
/// App Store keyboard) by selecting the two before the caret, deleting both
/// and inserting the first again. Two things went wrong with that here. The
/// view reported each of those edits back to the keyboard as if the user had
/// made them, and 豆包's voice input ends its session on that — at the first
/// correction it made to text it had already streamed in, so a dictated
/// sentence stopped half-way. And when the selection reached the phantom
/// newline parked at the front of the buffer, putting it back pressed Return
/// on the remote: half a command run, half a prompt sent.
@Suite("third-party keyboard input", .serialized)
@MainActor
struct ThirdPartyKeyboardInputTests {

    final class Remote: TerminalViewDelegate {
        var bytes: [UInt8] = []
        var text: String { String(decoding: bytes, as: UTF8.self) }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// Stands in for the keyboard on the other end of `inputDelegate`.
    final class Keyboard: NSObject, UITextInputDelegate {
        var calls: [String] = []
        func selectionWillChange(_ textInput: (any UITextInput)?) { calls.append("selectionWillChange") }
        func selectionDidChange(_ textInput: (any UITextInput)?) { calls.append("selectionDidChange") }
        func textWillChange(_ textInput: (any UITextInput)?) { calls.append("textWillChange") }
        func textDidChange(_ textInput: (any UITextInput)?) { calls.append("textDidChange") }
        @available(iOS 18.4, *)
        func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    }

    struct Rig {
        let window: UIWindow
        let view: TerminalView
        let remote = Remote()
        let keyboard = Keyboard()

        init() throws {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
            view = TerminalView(frame: window.bounds)
            window.addSubview(view)
            window.makeKeyAndVisible()
            _ = view.becomeFirstResponder()
            try #require(view.isFirstResponder, "the phantom is only parked for a focused terminal")
            view.terminalDelegate = remote
            view.inputDelegate = keyboard
        }

        /// The whole input buffer as the keyboard reads it.
        var buffer: String {
            view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
                .flatMap { view.text(in: $0) } ?? ""
        }

        /// Puts the selection over `[from, to)` the way UIKit does before it
        /// deletes for a third-party keyboard.
        func select(_ from: Int, _ to: Int) {
            let start = view.position(from: view.beginningOfDocument, offset: from)!
            let end = view.position(from: view.beginningOfDocument, offset: to)!
            view.selectedTextRange = view.textRange(from: start, to: end)
        }

        /// One tap of a third-party keyboard's delete key, as UIKit carries it out.
        func deleteOneCharacterTheThirdPartyWay() {
            let caret = view.offset(from: view.beginningOfDocument, to: view.selectedTextRange!.start)
            let before = Array(buffer)
            select(caret - 2, caret)
            view.deleteBackward()
            view.insertText(String(before[caret - 2]))
        }
    }

    @Test("A keyboard's own typing and deleting is not reported back to it")
    func ownEditsAreNotReportedBack() throws {
        let rig = try Rig()
        #expect(rig.buffer == "\n", "a focused terminal parks one phantom newline")

        rig.view.insertText("帮")
        rig.view.insertText("我")
        rig.view.insertText("看")
        rig.deleteOneCharacterTheThirdPartyWay()

        #expect(rig.keyboard.calls.isEmpty,
                "豆包 reads these as the user editing and ends voice input: \(rig.keyboard.calls)")
        #expect(rig.remote.text == "帮我看\u{7f}\u{7f}我")
        #expect(rig.buffer == "\n帮我")
    }

    @Test("Return still tells the keyboard the line was cleared")
    func returnIsReported() throws {
        let rig = try Rig()
        rig.view.insertText("ls")
        rig.view.insertText("\n")

        #expect(rig.keyboard.calls.contains("textDidChange"),
                "the keyboard did not clear the buffer itself; it must re-read it")
        #expect(rig.remote.bytes.last == 13)
        #expect(rig.buffer == "\n")
    }

    @Test("Deleting the first character the third-party way does not press Return")
    func deletingTheFirstCharacterSendsNoReturn() throws {
        let rig = try Rig()
        rig.view.insertText("帮")
        rig.deleteOneCharacterTheThirdPartyWay()

        #expect(!rig.remote.bytes.contains(13), "putting the phantom back is not a Return")
        #expect(rig.remote.bytes == Array("帮".utf8) + [0x7f])
        #expect(rig.buffer == "\n", "the phantom is back for the next hold-to-delete")

        rig.view.insertText("你")
        #expect(rig.remote.text == "帮\u{7f}你")
    }

    @Test("A Return typed after a delete that reached the front is a real one")
    func laterReturnStillGoesThrough() async throws {
        let rig = try Rig()
        rig.view.insertText("帮")
        rig.select(0, 2)
        rig.view.deleteBackward()

        // The user lifts the delete key and presses Return: a later turn of
        // the run loop, not UIKit finishing its delete.
        try await Task.sleep(for: .milliseconds(50))
        rig.view.insertText("\n")

        #expect(rig.remote.bytes.last == 13)
    }

    @Test("IME selections tolerate stale UTF-16 ranges and never split a grapheme")
    func compositionSelectionBoundaries() throws {
        let rig = try Rig()
        defer { rig.window.isHidden = true; rig.view.updateUiClosed() }
        let cases: [(String, NSRange, Range<Int>)] = [
            ("你好", NSRange(location: NSNotFound, length: 0), 2..<2),
            ("你", NSRange(location: 8, length: Int.max), 1..<1),
            ("你好", NSRange(location: 1, length: Int.max), 1..<2),
            ("😀x", NSRange(location: 1, length: 0), 1..<1),
            ("😀x", NSRange(location: 1, length: 1), 0..<1),
            ("e\u{0301}x", NSRange(location: 1, length: 1), 0..<1),
            ("👩🏽‍💻x", NSRange(location: 3, length: 0), 1..<1),
            ("", NSRange(location: NSNotFound, length: Int.max), 0..<0)
        ]
        for (text, selection, expected) in cases {
            rig.view.setMarkedText(text, selectedRange: selection)
            let marked = try #require(rig.view.markedTextRange)
            let selected = try #require(rig.view.selectedTextRange)
            #expect(rig.view.text(in: marked) == text)
            #expect(rig.view.offset(from: marked.start, to: selected.start) == expected.lowerBound)
            #expect(rig.view.offset(from: marked.start, to: selected.end) == expected.upperBound)
            #expect(rig.remote.bytes.isEmpty, "a candidate update stays on the device")
        }
    }

    @Test("Committing Chinese, emoji and combining text preserves every space")
    func compositionCommitPreservesText() throws {
        let rig = try Rig()
        defer { rig.window.isHidden = true; rig.view.updateUiClosed() }
        let text = " 你好  👩🏽‍💻 e\u{0301} \t"
        rig.view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        #expect(rig.remote.bytes.isEmpty)
        rig.view.unmarkText()
        #expect(rig.remote.text == text)
        #expect(rig.view.markedTextRange == nil)
        #expect(rig.buffer == "\n" + text)
        rig.view.unmarkText()
        #expect(rig.remote.text == text, "a second unmark must not commit again")
    }

    @Test("Deleting composed emoji and accents never backspaces remote text")
    func compositionDeletionStaysLocal() throws {
        let rig = try Rig()
        defer { rig.window.isHidden = true; rig.view.updateUiClosed() }
        rig.view.insertText("prefix")
        rig.view.setMarkedText("你👩🏽‍💻e\u{0301}", selectedRange: NSRange(location: NSNotFound, length: 0))
        for expected in ["你👩🏽‍💻", "你", ""] {
            rig.view.deleteBackward()
            #expect(rig.buffer == "\nprefix" + expected)
            #expect(rig.remote.text == "prefix")
        }
        #expect(rig.view.markedTextRange == nil)
        rig.view.deleteBackward()
        #expect(rig.remote.bytes == Array("prefix".utf8) + [0x7f])
    }

    @Test("Cancelling a shortened candidate sends no text or deletion")
    func compositionCancellationStaysLocal() throws {
        let rig = try Rig()
        defer { rig.window.isHidden = true; rig.view.updateUiClosed() }
        rig.view.insertText("prefix")
        rig.view.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0))
        rig.view.setMarkedText("你", selectedRange: NSRange(location: 6, length: 0))
        rig.view.setMarkedText(nil, selectedRange: NSRange(location: NSNotFound, length: 0))
        #expect(rig.buffer == "\nprefix")
        #expect(rig.view.markedTextRange == nil)
        #expect(rig.remote.text == "prefix")
        rig.view.insertText("!")
        #expect(rig.remote.text == "prefix!")
    }

    @Test("Remote output and narrow layouts preserve composition and its caret", arguments: [false, true])
    func compositionSurvivesOutputAndResize(_ metal: Bool) throws {
        let rig = try Rig()
        defer { rig.window.isHidden = true; rig.view.updateUiClosed() }
        if metal { try rig.view.setUseMetal(true) }
        rig.view.insertText("prefix")
        let text = "你好 👩🏽‍💻 e\u{0301}"
        rig.view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        for width in [230.0, 540.0, 390.0] {
            rig.view.frame.size.width = width
            rig.view.setNeedsLayout()
            rig.view.layoutIfNeeded()
            rig.view.feed(text: "\r\nremote-output> ")
            rig.view.updateDisplay()
            let marked = try #require(rig.view.markedTextRange)
            let label = try #require(rig.view.imeCompositionLabel)
            let caret = try #require(rig.view.caretView)
            #expect(rig.view.text(in: marked) == text)
            #expect(label.attributedText?.string == text)
            #expect(abs(caret.frame.minX - label.frame.maxX) <= 1,
                    "a repaint must not move the caret before the composing text")
            #expect(abs(caret.frame.minY - label.frame.minY) <= 1)
            #expect(rig.remote.text == "prefix", "layout and output cannot commit local composition")
        }
        rig.view.unmarkText()
        #expect(rig.remote.text == "prefix" + text)
    }
}
