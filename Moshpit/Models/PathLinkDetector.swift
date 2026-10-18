import Foundation
import SwiftTerm

/// Makes the paths an agent reports tappable — "对比图：qchar/out/GripLab.png",
/// "saved to ~/Desktop/charts/" — so its output opens on the phone instead of
/// waiting for a desk. The companion of `PlainLinkDetector`: same visible-row
/// walk, same soft-wrap join, same `tagPlainTextLink` cell payload, so a path
/// link underlines and taps exactly like a URL does.
///
/// Only paths the HOST confirmed get tagged (`RemotePathLinks`), so the text
/// itself never has to be trusted: a candidate the probe hasn't answered yet
/// is left plain and picked up by the pass that runs when the answer lands.
enum PathLinkDetector {
    @MainActor
    static func linkify(terminal: Terminal, resolver: RemotePathLinks) {
        var row = 0
        while row < terminal.rows {
            var spans: [(row: Int, length: Int)] = []
            var text = ""
            var current = row
            while true {
                let rowText = terminal.viewportLineText(row: current)
                spans.append((current, rowText.count))
                text += rowText
                guard terminal.isRowWrapped(current), current + 1 < terminal.rows else { break }
                current += 1
            }
            row = current + 1

            guard text.contains("/") || text.contains(".") else { continue }
            for candidate in TerminalPathScanner.scan(text) {
                guard let first = PlainLinkDetector.cell(atOffset: candidate.offset, spans: spans) else { continue }
                // Whatever already links here wins — an OSC-8 link, a URL, or
                // this pass's own tag from an earlier run (which also keeps
                // a confirmed path from being looked up again every pass).
                if terminal.link(at: .screen(Position(col: first.col, row: first.row)),
                                 mode: .explicitOnly) != nil { continue }
                guard let path = resolver.resolvedPath(for: candidate) else { continue }
                PlainLinkDetector.tagAcrossRows(startOffset: candidate.offset, length: candidate.length,
                                                spans: spans, terminal: terminal,
                                                url: RemotePathLink.url(for: path))
            }
        }
    }
}

/// Which path candidates on one terminal the host has confirmed, and where
/// they point. One per terminal (a tmux pane has its own working directory),
/// fed by the session's probe (`PathProbe` over the file-transfer SSH).
///
/// Lookups are synchronous and never block the link pass: an unknown
/// candidate answers nil, joins the queue, and a debounced batch asks the
/// host about everything queued in one exec round trip. When answers land,
/// `onResolved` asks for another pass, which then finds them in the cache.
///
/// Misses are remembered for a while, not forever: agents often name a file
/// a moment before writing it ("I'll save the chart to out/a.png").
@MainActor
final class RemotePathLinks {
    typealias Probe = (_ cwd: String?, _ batch: [TerminalPathScanner.Candidate]) async -> [Int: PathProbe.Hit]?

    /// Called after a batch confirmed something, or after the working
    /// directory moved (every relative answer is stale then).
    var onResolved: (() -> Void)?

    /// A miss is asked again after this long: the agent may name a file
    /// before it writes it. Not sooner — every relative miss costs the host
    /// a `find`.
    static let missRetry: TimeInterval = 30
    static let workingDirectoryTTL: TimeInterval = 10
    static let batchLimit = 48
    /// A full screen of agent output reaches the link pass in several
    /// bursts; one probe for the lot beats one per burst.
    static let debounce: Duration = .milliseconds(250)
    /// The cache is per terminal and its keys are short strings; past this
    /// many it is simply started over.
    static let entryLimit = 4000

    private enum Entry {
        case hit(PathProbe.Hit)
        case miss(Date)
        case pending
    }

    private let workingDirectory: () async -> String?
    private let probe: Probe
    private let now: () -> Date

    private var entries: [String: Entry] = [:]
    private var queued: [TerminalPathScanner.Candidate] = []
    private var drainTask: Task<Void, Never>?
    private var cwd: String?
    private var cwdFetchedAt: Date?

    init(workingDirectory: @escaping () async -> String?,
         probe: @escaping Probe,
         now: @escaping () -> Date = Date.init) {
        self.workingDirectory = workingDirectory
        self.probe = probe
        self.now = now
    }

    /// The confirmed host path for `candidate`, or nil. Asking about one the
    /// host hasn't been asked about yet is what queues it.
    func resolvedPath(for candidate: TerminalPathScanner.Candidate) -> String? {
        let key = Self.key(cwd: cwd, candidate)
        switch entries[key] {
        case .hit(let hit)?:
            return hit.path
        case .pending?:
            return nil
        case .miss(let at)?:
            guard now().timeIntervalSince(at) >= Self.missRetry else { return nil }
        case nil:
            break
        }
        if entries.count >= Self.entryLimit { entries.removeAll() }
        entries[key] = .pending
        queued.append(candidate)
        if drainTask == nil {
            drainTask = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                await self?.drain()
            }
        }
        return nil
    }

    /// Forget the working directory, so the next batch asks again — for an
    /// owner that just learned it changed (OSC 7, a pane switch).
    func invalidateWorkingDirectory() {
        cwdFetchedAt = nil
    }

    private func drain() async {
        var changed = false
        while !queued.isEmpty {
            let batch = Array(queued.prefix(Self.batchLimit))
            queued.removeFirst(batch.count)

            if cwdFetchedAt.map({ now().timeIntervalSince($0) >= Self.workingDirectoryTTL }) ?? true {
                let fresh = await workingDirectory()
                cwdFetchedAt = now()
                if fresh != cwd {
                    // Every relative answer (and every pending key) belonged
                    // to the old directory. The pass `onResolved` triggers
                    // re-asks for whatever is still on screen.
                    cwd = fresh
                    entries.removeAll()
                    changed = true
                }
            }

            let hits = await probe(cwd, batch)
            let stamp = now()
            for (index, candidate) in batch.enumerated() {
                // A failed probe (no SSH right now) counts as a miss: the
                // retry window is what keeps a dead channel from being hit on
                // every link pass.
                entries[Self.key(cwd: cwd, candidate)] = hits?[index].map(Entry.hit) ?? .miss(stamp)
            }
            if hits?.isEmpty == false { changed = true }
        }
        drainTask = nil
        if changed { onResolved?() }
    }

    private static func key(cwd: String?, _ candidate: TerminalPathScanner.Candidate) -> String {
        (cwd ?? "") + "\u{0}" + (candidate.directoryOnly ? "D" : "F") + candidate.token
    }
}
