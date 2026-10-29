import Foundation
import SwiftTerm
import Testing
@testable import Moshpit

/// mosh's predictive echo, driven headlessly: a SwiftTerm `Terminal` plays the
/// screen, the test plays mosh-server (host bytes + echo ack), and every step
/// runs the owner's cycle — withdraw → feed → settle → apply — exactly as
/// `SwiftTerminalView.Coordinator` does.
@Suite("MoshPrediction", .serialized)   // AttributeForge's scratch terminal is shared
struct MoshPredictionTests {

    // MARK: - Rig

    /// `Terminal.tdel` is weak, so the delegate has to outlive the terminal.
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private final class Clock { var now: UInt64 = 10_000 }

    private final class Rig {
        let sink = Sink()
        let terminal: Terminal
        let engine: MoshPrediction
        private let clock = Clock()
        var now: UInt64 {
            get { clock.now }
            set { clock.now = newValue }
        }
        /// The user-state number the next keystroke batch rides in.
        var nextState: UInt64 = 1
        var ack: UInt64 = 0

        init(mode: PredictMode = .always, trail: Bool = false, srttMs: Double = 500,
             cols: Int = 20, rows: Int = 4, prompt: String = "$ ") {
            terminal = Terminal(delegate: sink, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0))
            engine = MoshPrediction(mode: mode, trail: trail, clock: { [clock] in clock.now })
            engine.srttMs = srttMs
            terminal.feed(text: prompt)
        }

        /// The user types `keys`; returns whether anything new was drawn.
        @discardableResult
        func type(_ keys: String) -> Bool {
            engine.withdraw(from: terminal)
            guard let batch = engine.userInput(Data(keys.utf8), on: terminal) else { return false }
            engine.sent(batch: batch, as: nextState)
            nextState += 1
            return engine.apply(to: terminal)
        }

        /// The server's frame: `bytes` of output, and an echo ack covering
        /// every keystroke sent so far (or `ack`, when given).
        @discardableResult
        func host(_ bytes: String = "", ack: UInt64? = nil) -> Bool {
            engine.withdraw(from: terminal)
            if !bytes.isEmpty { terminal.feed(text: bytes) }
            self.ack = ack ?? (nextState - 1)
            engine.noteEchoAck(self.ack)
            engine.settle(on: terminal)
            return engine.apply(to: terminal)
        }

        /// Type `keys` and have the server echo them verbatim — confirms the
        /// epoch so later guesses show.
        func warmUp(_ keys: String = "a") {
            type(keys)
            host(keys)
        }

        /// A row's text, trailing blanks dropped.
        func row(_ row: Int) -> String {
            guard let line = terminal.getLine(row: row) else { return "" }
            var text = ""
            for col in 0..<terminal.cols {
                let cell = line[col]
                guard cell.width > 0 else { continue }
                let character = terminal.getCharacter(for: cell)
                text.append(character == "\u{0}" ? " " : character)
            }
            while text.last == " " { text.removeLast() }
            return text
        }

        var cursor: (col: Int, row: Int) { (terminal.buffer.x, terminal.buffer.y) }

        func cell(_ col: Int, row: Int = 0) -> CharData {
            terminal.getLine(row: row)![col]
        }

        /// Everything a cell shows, for exact before/after comparisons.
        func snapshot() -> [String] {
            (0..<terminal.rows).flatMap { row in
                (0..<terminal.cols).map { col in
                    let cell = self.cell(col, row: row)
                    return "\(terminal.getCharacter(for: cell))|\(cell.width)|\(cell.attribute)"
                }
            } + ["cursor \(cursor.col),\(cursor.row)"]
        }
    }

    // MARK: - Epochs

    @Test("the first guess waits for the server; once it confirms, typing shows at once")
    func epochConfirmation() {
        let rig = Rig()
        #expect(!rig.type("l"), "an unconfirmed epoch is never drawn")
        #expect(rig.row(0) == "$")
        #expect(rig.cursor.col == 2)

        rig.host("l")
        #expect(rig.row(0) == "$ l")

        #expect(rig.type("s"))
        #expect(rig.row(0) == "$ ls")
        #expect(rig.cursor.col == 4)

        rig.engine.withdraw(from: rig.terminal)
        #expect(rig.row(0) == "$ l", "withdrawn, the screen is the server's again")
        #expect(rig.cursor.col == 3)
    }

    @Test("withdraw puts back every cell and the cursor exactly")
    func withdrawIsExact() {
        let rig = Rig(prompt: "\u{1b}[32m$ \u{1b}[0mab")
        rig.warmUp("x")
        rig.host("\u{1b}[1;4H")                                        // cursor back on the 'b'
        rig.engine.withdraw(from: rig.terminal)
        let before = rig.snapshot()

        rig.type("yz\u{7f}\u{1b}[D")
        #expect(rig.engine.isApplied)
        #expect(rig.snapshot() != before)

        #expect(rig.engine.withdraw(from: rig.terminal))
        #expect(rig.snapshot() == before)
        #expect(!rig.engine.withdraw(from: rig.terminal), "a second withdraw has nothing to put back")
    }

    @Test("a wrong guess in a shown epoch drops every guess, and the next ones wait again")
    func mispredictionResets() {
        let rig = Rig()
        rig.warmUp("a")
        #expect(rig.type("b"))
        #expect(rig.row(0) == "$ ab")

        // The app upper-cases what it echoes.
        rig.host("B")
        #expect(rig.row(0) == "$ aB")
        #expect(!rig.engine.isApplied)

        #expect(!rig.type("c"), "after a miss, guesses are tentative until confirmed again")
        #expect(rig.row(0) == "$ aB")
    }

    @Test("a prompt that doesn't echo never shows a typed character")
    func passwordNeverShows() {
        let rig = Rig()
        rig.warmUp("su")
        rig.type("\r")
        rig.host("\r\nPassword: ")
        #expect(rig.row(1) == "Password:")

        for key in "hunter2" {
            rig.type(String(key))
            #expect(rig.row(1) == "Password:", "typed \(key) must not appear")
            rig.host()                                   // acked, nothing echoed
            #expect(rig.row(1) == "Password:")
        }
        #expect(!rig.engine.isApplied)
    }

    // MARK: - Editing

    @Test("backspace pulls the rest of the line left")
    func backspaceShifts() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("\r\u{1b}[K$ abcd\u{1b}[1;5H")          // cursor on 'c'
        #expect(rig.cursor.col == 4)

        #expect(rig.type("\u{7f}"))
        #expect(rig.row(0) == "$ acd")
        #expect(rig.cursor.col == 3)

        // The server agrees (readline: BS, delete-char): nothing left to draw.
        rig.host("\u{8}\u{1b}[P")
        #expect(!rig.engine.isApplied)
        #expect(rig.row(0) == "$ acd")
        #expect(rig.cursor.col == 3)
    }

    @Test("typing mid-line pushes the rest of the line right")
    func insertShifts() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("\r\u{1b}[K$ acd\u{1b}[1;4H")           // cursor on 'c'
        #expect(rig.type("b"))
        #expect(rig.row(0) == "$ abcd")
        #expect(rig.cursor.col == 4)
    }

    @Test("plain arrows move the cursor; modified ones and the end of the text wait")
    func arrows() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("bcd")                                  // "$ abcd", cursor at 6
        #expect(rig.cursor.col == 6)

        #expect(!rig.type("\u{1b}[C"), "→ past the text: a line editor may not move")
        #expect(rig.cursor.col == 6)
        rig.host()

        rig.warmUp("e")                                  // the miss above cost the epoch
        #expect(rig.cursor.col == 7)
        #expect(rig.type("\u{1b}[D"))
        #expect(rig.cursor.col == 6)
        #expect(rig.type("\u{1b}OD"), "SS3 arrows (application cursor mode) too")
        #expect(rig.cursor.col == 5)
        #expect(rig.type("\u{1b}[C"))
        #expect(rig.cursor.col == 6)

        rig.type("\u{1b}[1;5D")                          // ⌃← jumps a word: unknowable
        rig.type("\u{1b}[D")
        #expect(rig.cursor.col == 6, "after ⌃← nothing more is guessed until the server answers")
    }

    // MARK: - Barriers (no newline / wrap prediction)

    @Test("after Return nothing is guessed until the server has placed the cursor")
    func carriageReturnBarrier() {
        let rig = Rig()
        rig.warmUp("l")
        rig.type("s")
        rig.type("\r")
        rig.type("x")
        rig.type("y")
        #expect(rig.row(0) == "$ ls")
        #expect(rig.row(1) == "")

        rig.host("s\r\nfile\r\n$ ", ack: rig.nextState - 3)  // acks through Return only
        #expect(rig.row(2) == "$")
        #expect(!rig.engine.isApplied)
        rig.host("xy")
        #expect(rig.row(2) == "$ xy")

        rig.type("z")
        #expect(rig.row(2) == "$ xy", "a new line starts a new, unconfirmed epoch")
    }

    @Test("the last column waits for the server — it may wrap, or not")
    func lastColumnBarrier() {
        let rig = Rig(cols: 10)
        rig.warmUp("a")
        rig.host("bcdefg")                               // "$ abcdefg", cursor in the last column
        #expect(rig.cursor.col == 9)

        rig.type("h")
        rig.type("i")
        #expect(rig.row(0) == "$ abcdefg")
        #expect(rig.row(1) == "")
        #expect(!rig.engine.isApplied)
    }

    @Test("wide characters are the server's to draw and to erase")
    func wideCharacters() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("中")                                    // cols 3–4, cursor at 5
        #expect(rig.cursor.col == 5)

        #expect(!rig.type("\u{7f}"), "erasing a wide character moves two columns")
        #expect(rig.row(0) == "$ a中")
        #expect(rig.cursor.col == 5)
        #expect(!rig.type("\u{1b}[D"))
        #expect(rig.cursor.col == 5)

        let fresh = Rig()
        fresh.warmUp("a")
        #expect(!fresh.type("中"), "a wide character is never guessed")
        #expect(fresh.row(0) == "$ a")
    }

    // MARK: - Showing

    @Test("adaptive: hidden on a fast link, shown on a slow one")
    func adaptiveGate() {
        let fast = Rig(mode: .adaptive, srttMs: 12)
        fast.warmUp("a")
        #expect(!fast.type("b"))
        #expect(fast.row(0) == "$ a")

        let slow = Rig(mode: .adaptive, srttMs: 400)
        slow.warmUp("a")
        #expect(slow.type("b"))
        #expect(slow.row(0) == "$ ab")
    }

    @Test("adaptive: a guess stuck past 250ms shows even on a fast link")
    func glitchTrigger() {
        let rig = Rig(mode: .adaptive, srttMs: 12)
        rig.warmUp("a")
        #expect(!rig.type("b"))
        #expect(rig.engine.needsTick)

        rig.now += 100
        #expect(!rig.engine.tick())
        rig.now += 200
        #expect(rig.engine.tick(), "the glitch trigger flips what should be drawn")
        #expect(rig.engine.apply(to: rig.terminal))
        #expect(rig.row(0) == "$ ab")
    }

    @Test("never guesses nothing")
    func neverMode() {
        let rig = Rig(mode: .never)
        #expect(rig.engine.userInput(Data("a".utf8), on: rig.terminal) == nil)
        #expect(!rig.engine.needsTick)
    }

    @Test("trail: unconfirmed characters are drawn faint, in the colour of their neighbour")
    func trailDims() {
        let rig = Rig(trail: true, srttMs: 400)
        rig.type("a")
        rig.host("\u{1b}[31ma\u{1b}[0m")

        #expect(rig.type("b"))
        let drawn = rig.cell(3)
        #expect(rig.terminal.getCharacter(for: drawn) == "b")
        #expect(drawn.attribute.style.contains(.dim))
        #expect(drawn.attribute.fg == .ansi256(code: 1))

        let untrailed = Rig(trail: false, srttMs: 400)
        untrailed.warmUp("a")
        untrailed.type("b")
        #expect(!untrailed.cell(3).attribute.style.contains(.dim))
    }

    @Test("a no-credit confirmation still corrects the colours of the guesses after it")
    func noCreditFixesRenditions() {
        let rig = Rig()
        rig.warmUp("a")
        // zsh: the first word is red while it's not a command yet, and the
        // autosuggestion's grey "bc" already sits where the next keys land.
        rig.host("\r\u{1b}[K$ \u{1b}[31ma\u{1b}[90mbc\u{1b}[0m\u{1b}[1;4H")
        rig.type("b")
        rig.type("c")
        #expect(rig.cell(4).attribute.fg == .ansi256(code: 1), "guessed in the colour on its left")

        // The server echoes 'b' — over the suggestion's own 'b', so no credit
        // — and the word is no longer red.
        rig.host("\r\u{1b}[K$ ab\u{1b}[90mc\u{1b}[0m\u{1b}[1;5H", ack: rig.nextState - 2)
        #expect(rig.row(0) == "$ abc")
        #expect(rig.terminal.getCharacter(for: rig.cell(4)) == "c")
        #expect(rig.cell(4).attribute.fg == .defaultColor, "the pending 'c' took the colour the server gave 'b'")
    }

    @Test("typing along an autosuggestion consumes it instead of pushing it right")
    func autosuggestionIsNotShifted() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("\u{1b}[90mbcd\u{1b}[0m\u{1b}[1;4H")       // "$ a" + grey "bcd", cursor on the 'b'
        #expect(rig.type("b"))
        #expect(rig.row(0) == "$ abcd", "not \"$ abbcd\"")
        #expect(rig.cell(3).attribute.fg == .defaultColor, "typed text, not suggestion grey")

        // zsh consumes the suggestion's 'b': no miss, so the next key shows at once.
        rig.host("b\u{1b}[90mcd\u{1b}[0m\u{1b}[1;5H")
        #expect(rig.type("c"))
        #expect(rig.row(0) == "$ abcd")
        #expect(rig.cursor.col == 5)
    }

    @Test("backspace in front of an autosuggestion erases the character and leaves the rest")
    func backspaceBeforeAutosuggestion() {
        let rig = Rig()
        rig.warmUp("a")
        rig.host("b\u{1b}[90mcd\u{1b}[0m\u{1b}[1;5H")      // "$ ab" + grey "cd", cursor on the 'c'
        #expect(rig.type("\u{7f}"))
        #expect(rig.row(0) == "$ a cd", "the 'b' is gone, the suggestion stays put")
        #expect(rig.cursor.col == 3)

        // zsh re-suggests from history: "$ a" + grey "bcd". Not a miss.
        rig.host("\u{8}\u{1b}[90mbcd\u{1b}[0m\u{1b}[1;4H")
        rig.engine.withdraw(from: rig.terminal)
        #expect(rig.row(0) == "$ abcd")
        #expect(rig.type("b"), "the epoch survived")
    }

    @Test("host output elsewhere never carries a guess into the server's screen")
    func diffPeerContract() {
        let rig = Rig()
        rig.warmUp("a")
        #expect(rig.type("b"))

        // A status line repaints while the keystroke is in flight.
        rig.host("\u{1b}7\u{1b}[4;1Hstatus\u{1b}8", ack: rig.ack)
        #expect(rig.row(0) == "$ ab", "still guessed")
        #expect(rig.row(3) == "status")

        rig.engine.withdraw(from: rig.terminal)
        #expect(rig.row(0) == "$ a", "the guess was never written into the server's cells")
        #expect(rig.cursor.col == 3)
    }

    @Test("a resize leaves the overlay alone and starts over")
    func resize() {
        let rig = Rig()
        rig.warmUp("a")
        #expect(rig.type("b"))
        rig.terminal.resize(cols: 30, rows: 4)
        #expect(!rig.engine.withdraw(from: rig.terminal), "cells moved; the server repaints")
        #expect(!rig.type("c"), "a new size is a new, unconfirmed screen")
    }

    // MARK: - Pieces

    @Test("only single-column, non-combining characters are guessed",
          arguments: [("a", true), ("é", true), ("~", true), ("中", false), ("😀", false),
                      ("\u{301}", false), ("\u{200B}", false), ("\u{7}", false)])
    func predictable(text: String, expected: Bool) {
        #expect(MoshPrediction.predictable(text.unicodeScalars.first!) == expected)
    }

    @Test("faint is added through SGR without losing colours or underline")
    func attributeForge() {
        let rig = Rig(prompt: "\u{1b}[1;3;4:3;38;2;10;20;30;48;5;200;58;5;9mX")
        let source = rig.cell(0).attribute
        #expect(AttributeForge.sgr(source) != nil)
        let made = AttributeForge.adding(dim: source)
        #expect(made.style == source.style.union(.dim))
        #expect(made.fg == source.fg)
        #expect(made.bg == source.bg)
        #expect(made.underlineStyle == source.underlineStyle)
        #expect(made.style.contains(.dim))
        #expect(made.underlineColor == source.underlineColor)
    }

    @Test("the keystroke scanner")
    func scanner() {
        var scanner = InputScanner()
        func events(_ text: String) -> [InputScanner.Event] { scanner.scan(Data(text.utf8)) }

        #expect(events("a\u{7f}") == [.print("a"), .print("\u{7f}")])
        #expect(events("\r") == [.execute(0x0D)])
        #expect(events("\u{1b}[C") == [.csi(final: UInt8(ascii: "C"), plain: true)])
        #expect(events("\u{1b}OD") == [.csi(final: UInt8(ascii: "D"), plain: true)])
        #expect(events("\u{1b}[1;5D") == [.csi(final: UInt8(ascii: "D"), plain: false)])
        #expect(events("\u{1b}x") == [.escape])
        #expect(events("\u{1b}]0;t\u{7}") == [.string])
        #expect(events("é中") == [.print("é"), .print("中")])
        #expect(events("\u{1b}[1\u{18}a") == [.execute(0x18), .print("a")], "CAN aborts")

        // A sequence split across sends still parses.
        #expect(events("\u{1b}[").isEmpty)
        #expect(events("A") == [.csi(final: UInt8(ascii: "A"), plain: true)])
        #expect(scanner.scan(Data([0xE4, 0xB8])).isEmpty)
        #expect(scanner.scan(Data([0xAD])) == [.print("中")])
    }

    @Test("a connection's own predict mode wins; adaptive defers to Settings")
    func effectiveMode() {
        #expect(SessionHub.ActiveSession.effectivePredictMode(connection: .adaptive, app: .never) == .never)
        #expect(SessionHub.ActiveSession.effectivePredictMode(connection: .adaptive, app: .always) == .always)
        #expect(SessionHub.ActiveSession.effectivePredictMode(connection: .never, app: .always) == .never)
        #expect(SessionHub.ActiveSession.effectivePredictMode(connection: .experimental, app: .adaptive) == .experimental)
    }
}
