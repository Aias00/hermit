import Foundation
import Testing
import UIKit
import SwiftTerm
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
@Suite("third-party keyboard input")
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
}
