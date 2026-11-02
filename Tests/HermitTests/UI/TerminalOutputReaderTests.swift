import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import Moshpit

@Suite("Terminal output reading") @MainActor
struct TerminalOutputReaderTests {
    private func terminal() -> (TerminalView, SwiftTerminalView.Coordinator) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 220),
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.getTerminal().resize(cols: 24, rows: 6)
        let coordinator = SwiftTerminalView.Coordinator()
        view.terminalDelegate = coordinator
        coordinator.attach(to: view)
        return (view, coordinator)
    }

    @Test("A parsed snapshot removes escape codes, joins soft wraps and preserves hard breaks")
    func snapshotFormatting() throws {
        let (view, coordinator) = terminal()
        let long = "ABCDEFGHIJ" + String(repeating: "K", count: 28)
        coordinator.feed(data: Data("\u{1b}[31m中文😀\u{1b}[0m\r\n\(long)\r\nfinal".utf8))
        let snapshot = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: false))
        #expect(snapshot.text.contains("中文😀"))
        #expect(snapshot.text.contains(long))
        #expect(snapshot.text.contains("\nfinal"))
        #expect(!snapshot.text.contains("\u{1b}"))
        #expect(!snapshot.isScreenOnly)
        #expect(snapshot.revision == coordinator.outputRevision)
        _ = view
    }

    @Test("Screen scope and alternate buffers do not claim or export normal scrollback")
    func scopesAreExplicit() throws {
        let (view, coordinator) = terminal()
        coordinator.feed(data: Data((0..<25).map { "history-\($0)\r\n" }.joined().utf8))
        let history = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: false))
        #expect(history.text.contains("history-0"))
        let screen = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: true))
        #expect(screen.isScreenOnly)
        #expect(!screen.text.contains("history-0"))
        coordinator.feed(data: Data("\u{1b}[?1049hALT_SCREEN".utf8))
        let alternate = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: false))
        #expect(alternate.isScreenOnly)
        #expect(alternate.text.contains("ALT_SCREEN"))
        #expect(!alternate.text.contains("history-"))
        _ = view
    }

    @Test("Back to latest flushes held output in order without sending terminal input")
    func latestIsLocalOnly() throws {
        let (view, coordinator) = terminal()
        var sent = Data()
        coordinator.onInput = { sent.append($0) }
        coordinator.feed(data: Data((0..<30).map { "old-\($0)\r\n" }.joined().utf8))
        coordinator.scrollLocal(lines: 20)
        #expect(coordinator.isReadingLocalHistory)
        coordinator.feed(data: Data("new-one\r\nnew-two\r\n".utf8))
        #expect(coordinator.hasHeldOutput)
        let heldSnapshot = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: false))
        #expect(!heldSnapshot.text.contains("new-one"), "capturing history must not resume or move its viewport")
        coordinator.returnToLatestLocalOutput()
        #expect(!coordinator.isReadingLocalHistory)
        #expect(!coordinator.hasHeldOutput)
        let snapshot = try #require(TerminalOutputSnapshot.capture(coordinator, screenOnly: false))
        #expect(snapshot.text.contains("new-one\nnew-two"))
        #expect(sent.isEmpty)
        #expect(view.scrollPosition > 0.999)
    }

    @Test("Local navigation is unavailable for a remote scroll owner")
    func remoteOwnerIsNotDrivenByLocalNavigation() {
        let (view, coordinator) = terminal()
        var calls = 0
        coordinator.onScroll = { _ in calls += 1 }
        coordinator.returnToLatestLocalOutput()
        #expect(!coordinator.isReadingLocalHistory)
        #expect(calls == 0)
        _ = view
    }

    @Test("Literal search produces valid UTF-16 ranges for CJK, emoji, case and regex characters")
    func unicodeAndLiteralSearch() {
        let text = "😀中文 test TEST .* 中文😀"
        let result = TerminalOutputSearch.find(in: text, query: "中文", caseSensitive: false)
        #expect(result.ranges.count == 2)
        #expect(result.ranges.allSatisfy { (text as NSString).substring(with: $0) == "中文" })
        #expect(TerminalOutputSearch.find(in: text, query: "test", caseSensitive: false).ranges.count == 2)
        #expect(TerminalOutputSearch.find(in: text, query: "test", caseSensitive: true).ranges.count == 1)
        #expect(TerminalOutputSearch.find(in: text, query: ".*", caseSensitive: false).ranges.count == 1)
        #expect(TerminalOutputSearch.find(in: text, query: "", caseSensitive: false).ranges.isEmpty)
    }

    @Test("Dense search results have a bounded navigation budget")
    func matchBudget() {
        let result = TerminalOutputSearch.find(in: String(repeating: "a ", count: 6_000), query: "a", caseSensitive: true)
        #expect(result.ranges.count == 5_000)
        #expect(result.limited)
    }

    @Test("Debounced queries cannot publish stale matches after text replacement or cancellation")
    func staleSearchDoesNotPublish() async throws {
        let search = TerminalOutputSearch()
        search.query = "old"
        search.replaceText("old old")
        search.query = "中文"
        search.replaceText("new 中文😀 中文")
        for _ in 0..<200 {
            if !search.isSearching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(search.matches.count == 2)
        #expect(search.currentIndex == 0)
        search.move(forward: false)
        #expect(search.currentIndex == 1)
        search.move(forward: true)
        #expect(search.currentIndex == 0)
        search.query = "new"
        search.search()
        search.cancel()
        try await Task.sleep(for: .milliseconds(220))
        #expect(search.matches.isEmpty)
    }
}
