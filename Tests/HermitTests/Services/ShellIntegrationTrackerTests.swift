import Foundation
import Testing
@testable import Moshpit

@Suite("Explicit shell integration")
struct ShellIntegrationTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    @Test("split OSC markers survive every byte boundary", arguments: [133, 633])
    func fragmentedLifecycle(code: Int) {
        let text = "\u{1B}]\(code);A\u{07}user$ \u{1B}]\(code);B\u{07}secret command\u{1B}]\(code);C\u{1B}\\"
        var tracker = ShellIntegrationTracker()
        for byte in text.utf8 { tracker.feed(Data([byte]), now: now) }
        #expect(tracker.command?.phase == .running)
        #expect(tracker.command?.startedAt == now)
        let finish = now.addingTimeInterval(9)
        for byte in "\u{1B}]\(code);D;7\u{1B}\\".utf8 { tracker.feed(Data([byte]), now: finish) }
        #expect(tracker.command?.phase == .finished)
        #expect(tracker.command?.exitCode == 7)
        #expect(tracker.command?.observedAt == finish)
    }

    @Test("ordinary output and silence never manufacture a task or finish")
    func noOutputHeuristics() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("$ sleep 2\r\ndone\r\n$ "), now: now)
        #expect(tracker.command == nil)
        tracker.feed(bytes("\u{1B}]133;C\u{07}"), now: now)
        tracker.feed(bytes("finished\r\n$ "), now: now.addingTimeInterval(600))
        tracker.feed(Data(), now: now.addingTimeInterval(3_600))
        #expect(tracker.command?.phase == .running)
        #expect(tracker.command?.observedAt == now)
    }

    @Test("aborted prompts and orphan finishes do not report a completed task")
    func abortedPrompt() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\u{1B}]133;D;0\u{07}"))
        #expect(tracker.command == nil)
        tracker.feed(bytes("\u{1B}]133;C\u{07}\u{1B}]133;A\u{07}"))
        #expect(tracker.command == nil)
    }

    @Test("an explicit result survives the following prompt but a new command replaces it")
    func completedResultLifetime() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]633;C\u{07}\u{1B}]633;D;0\u{07}\u{1B}]633;A\u{07}\u{1B}]633;B\u{07}"), now: now)
        #expect(tracker.command?.phase == .finished && tracker.command?.exitCode == 0)
        tracker.feed(bytes("\u{1B}]633;C\u{07}"), now: now.addingTimeInterval(8))
        #expect(tracker.command?.phase == .running && tracker.command?.exitCode == nil)
        #expect(tracker.command?.startedAt == now.addingTimeInterval(8))
    }

    @Test("an omitted exit code remains unknown rather than success")
    func unknownExit() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]133;C\u{07}\u{1B}]133;D\u{07}"))
        #expect(tracker.command?.phase == .finished)
        #expect(tracker.command?.exitCode == nil)
    }

    @Test("malformed exit codes cannot report success", arguments: ["-1", "256", "0junk", " 0", "0;secret", "9999999999999999999999"])
    func invalidExit(code: String) {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]133;C\u{07}\u{1B}]133;D;\(code)\u{07}"))
        #expect(tracker.command?.phase == .running)
    }

    @Test("a control-string payload is not a command event", arguments: ["P", "_", "^", "X"])
    func nestedStrings(introducer: String) {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}\(introducer)payload\u{1B}]133;C\u{07}payload\u{1B}\\"))
        #expect(tracker.command == nil)
        tracker.feed(bytes("\u{1B}]133;C\u{07}"))
        #expect(tracker.command?.phase == .running)
    }

    @Test("oversized and cancelled sequences recover without parsing their suffix")
    func boundedRecovery() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]133;" + String(repeating: "x", count: 10_000) + "\u{1B}]133;C\u{07}"))
        #expect(tracker.command == nil)
        tracker.feed(bytes("\u{1B}]133;C\u{18}\u{07}"))
        #expect(tracker.command == nil)
        tracker.feed(bytes("\u{1B}]133;C\u{07}"))
        #expect(tracker.command?.phase == .running)
    }

    @Test("directories support OSC 7, VS Code escaping and iTerm reports")
    func directories() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]7;file://remote/home/test/My%20Project\u{07}"))
        #expect(tracker.workingDirectory == "/home/test/My Project")
        tracker.feed(bytes("\u{1B}]633;P;Cwd=/home/test/a\\x3bb\\\\c\u{07}"))
        #expect(tracker.workingDirectory == "/home/test/a;b\\c")
        tracker.feed(bytes("\u{1B}]1337;CurrentDir=/home/项目\u{1B}\\"))
        #expect(tracker.workingDirectory == "/home/项目")
        #expect(tracker.command == nil)
    }

    @Test("invalid directory reports never replace a valid path", arguments: [
        "7;https://remote/tmp", "7;file://remote/tmp?token=secret", "7;file://user:password@remote/tmp",
        "7;file://remote/tmp%00bad", "633;P;Cwd=relative", "633;P;Cwd=/tmp/\\x0aevil",
        "633;P;Cwd=/tmp/\\q", "1337;CurrentDir=relative"
    ])
    func invalidDirectories(payload: String) {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]7;file://remote/safe\u{07}\u{1B}]\(payload)\u{07}"))
        #expect(tracker.workingDirectory == "/safe")
    }

    @Test("titles and explicit command text do not become observed programs")
    func privateTextIgnored() {
        var tracker = ShellIntegrationTracker()
        tracker.feed(bytes("\u{1B}]0;private title\u{07}\u{1B}]633;E;curl --token secret;nonce\u{07}"))
        #expect(tracker.command == nil && tracker.workingDirectory == nil)
    }
}
