import Observation
import SwiftTerm
import SwiftUI
import UIKit

/// A small synchronized counter; output may be fed from a transport queue.
final class TerminalOutputVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    var value: UInt64 { lock.withLock { revision } }
    func advance() { lock.withLock { revision &+= 1 } }
}

struct TerminalOutputSnapshot {
    let text: String
    let revision: UInt64
    let capturedAt: Date
    let isScreenOnly: Bool
    let isTruncated: Bool

    @MainActor
    static func capture(_ coordinator: SwiftTerminalView.Coordinator, screenOnly: Bool) -> Self? {
        guard let view = coordinator.terminalView else { return nil }
        let terminal = view.getTerminal()
        let screen = screenOnly || terminal.isCurrentBufferAlternate
        let first = screen ? terminal.buffer.yDisp : max(0, terminal.buffer.yDisp - 2_000)
        let end = terminal.buffer.yDisp + terminal.rows - 1
        let raw = terminal.getText(start: Position(col: 0, row: first),
                                   end: Position(col: terminal.cols, row: end))
            .trimmingCharacters(in: .newlines)
        let limit = 200_000
        return Self(text: String(raw.suffix(limit)), revision: coordinator.outputRevision,
                    capturedAt: .now, isScreenOnly: screen,
                    isTruncated: first > 0 && !screen || raw.count > limit)
    }
}

@Observable @MainActor
final class TerminalOutputSearch {
    var query = ""
    var caseSensitive = false
    private(set) var text = ""
    private(set) var matches: [NSRange] = []
    private(set) var currentIndex = 0
    private(set) var isSearching = false
    private(set) var reachedLimit = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var selectedRange: NSRange? { matches.indices.contains(currentIndex) ? matches[currentIndex] : nil }

    func replaceText(_ text: String) { self.text = text; search() }

    func search() {
        work?.cancel()
        generation = UUID()
        let run = generation
        matches = []
        currentIndex = 0
        reachedLimit = false
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        let text = text, query = query, caseSensitive = caseSensitive
        work = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let result = await Task.detached {
                Self.find(in: text, query: query, caseSensitive: caseSensitive)
            }.value
            guard !Task.isCancelled, let self, generation == run else { return }
            matches = result.ranges
            reachedLimit = result.limited
            isSearching = false
        }
    }

    func move(forward: Bool) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + (forward ? 1 : matches.count - 1)) % matches.count
    }

    func cancel() { work?.cancel(); generation = UUID(); isSearching = false }

    nonisolated static func find(in text: String, query: String, caseSensitive: Bool) -> (ranges: [NSRange], limited: Bool) {
        guard !query.isEmpty else { return ([], false) }
        let source = text as NSString
        var ranges: [NSRange] = []
        var offset = 0
        while offset < source.length, !Task.isCancelled {
            let match = source.range(of: query, options: caseSensitive ? [] : [.caseInsensitive],
                                     range: NSRange(location: offset, length: source.length - offset))
            guard match.location != NSNotFound, match.length > 0 else { break }
            if ranges.count == 5_000 { return (ranges, true) }
            ranges.append(match)
            offset = NSMaxRange(match)
        }
        return (ranges, false)
    }
}

struct TerminalOutputReader: View {
    let title: String
    let refresh: () -> TerminalOutputSnapshot?
    let currentRevision: () -> UInt64?
    @State var snapshot: TerminalOutputSnapshot
    @State var showsPreview = false
    @State private var search = TerminalOutputSearch()
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(snapshot.isScreenOnly ? "Searches this screen snapshot. Older history stays on the server."
                         : "Searches loaded output up to this viewport, including up to 2,000 history rows.")
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot.isTruncated {
                        Text("Only the most recent part of this output is included.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("显示方式", selection: $showsPreview) {
                        Text("原文 / 搜索").tag(false)
                        Text("Markdown 预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("terminal-output-presentation")
                    if !showsPreview {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search output", text: $search.query)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .submitLabel(.search).onSubmit { search.move(forward: true) }
                            .accessibilityIdentifier("terminal-output-query")
                        if !search.query.isEmpty {
                            Button { search.query = "" } label: {
                                Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                            }
                                .accessibilityLabel("Clear search")
                                .accessibilityIdentifier("terminal-output-clear")
                        }
                        Toggle(isOn: $search.caseSensitive) { Text(verbatim: "Aa").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Match case")
                            .toggleStyle(.button).labelStyle(.titleOnly)
                            .accessibilityIdentifier("terminal-output-case")
                    }
                    HStack {
                        if search.isSearching { ProgressView() }
                        else if !search.query.isEmpty {
                            Text(search.matches.isEmpty ? String(localized: "No matches")
                                 : "\(search.currentIndex + 1)/\(search.matches.count)\(search.reachedLimit ? "+" : "")")
                                .monospacedDigit().accessibilityIdentifier("terminal-output-match-count")
                        }
                        Spacer()
                        Button { search.move(forward: false) } label: { Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Previous match").accessibilityIdentifier("terminal-output-previous")
                        Button { search.move(forward: true) } label: { Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Next match").accessibilityIdentifier("terminal-output-next")
                    }
                    .buttonStyle(.bordered).disabled(search.matches.isEmpty)
                    .font(.subheadline)
                    }
                }.padding(16)
                Divider()
                if showsPreview, !snapshot.text.isEmpty {
                    MarkdownReader(text: snapshot.text)
                } else if search.text.isEmpty {
                    ContentUnavailableView("No output yet", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    OutputTextView(text: search.text, match: search.selectedRange)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let revision = currentRevision(), revision != snapshot.revision {
                        Button("New output available · Refresh") {
                            guard let updated = refresh() else { return }
                            snapshot = updated
                            copied = false
                            search.replaceText(updated.text)
                        }
                        .padding(12).frame(maxWidth: .infinity)
                        .background(.tint.opacity(0.1))
                        .accessibilityIdentifier("terminal-output-refresh")
                    } else if currentRevision() == nil {
                        Text("The source changed. Reopen the reader for the current terminal.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
            }
            .navigationTitle("Read output").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "Copied" : "Copy output") {
                        UIPasteboard.general.string = snapshot.text
                        copied = true
                    }.disabled(snapshot.text.isEmpty).accessibilityIdentifier("terminal-output-copy")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { search.replaceText(snapshot.text) }
        .onChange(of: search.query) { search.search() }
        .onChange(of: search.caseSensitive) { search.search() }
        .onDisappear { search.cancel() }
    }
}

private struct OutputTextView: UIViewRepresentable {
    final class Coordinator {
        var highlighted: NSRange?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    let text: String
    let match: NSRange?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.keyboardDismissMode = .interactive
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.accessibilityIdentifier = "terminal-output-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let changed = view.text != text
        if changed { view.text = text; context.coordinator.highlighted = nil }
        guard changed || context.coordinator.highlighted != match else { return }
        if let previous = context.coordinator.highlighted, NSMaxRange(previous) <= view.textStorage.length {
            view.textStorage.removeAttribute(.backgroundColor, range: previous)
            view.textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: previous)
        }
        context.coordinator.highlighted = match
        if let match, NSMaxRange(match) <= view.textStorage.length {
            view.textStorage.addAttributes([.backgroundColor: UIColor.systemYellow, .foregroundColor: UIColor.black], range: match)
            view.scrollRangeToVisible(match)
        }
    }
}
