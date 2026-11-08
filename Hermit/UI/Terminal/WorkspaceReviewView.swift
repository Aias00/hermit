import SwiftUI

struct WorkspaceReviewTarget: Identifiable {
    let id = UUID()
    let run: WorkspaceInspection.Run
    let directory: () async throws -> String
    let export: (String) -> Bool
}

@Observable @MainActor
final class WorkspaceReviewModel {
    var snapshot: WorkspaceGitSnapshot?
    var notes: [WorkspaceReviewNote] = []
    var loading = false
    var error: String?
    private var directory: String?
    let target: WorkspaceReviewTarget
    init(target: WorkspaceReviewTarget) { self.target = target }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let directory = try await directoryValue()
            let reply = try await target.run(WorkspaceGit.statusCommand(directory: directory))
            try Task.checkCancellation()
            let next = try WorkspaceGit.parseStatus(reply)
            if let old = snapshot, old.root != next.root, !notes.isEmpty { throw WorkspaceReviewError.changedWorkspace }
            snapshot = next
        } catch is CancellationError { }
        catch let error as WorkspaceReviewError { self.error = error.localizedDescription }
        catch { self.error = "读取 Git 改动失败。请检查连接、工作目录和 Git，然后重试。" }
    }
    private func directoryValue() async throws -> String {
        if let directory { return directory }
        let value = try await target.directory()
        directory = value
        return value
    }
}

struct WorkspaceReviewView: View {
    @State private var model: WorkspaceReviewModel
    @State private var showsNotes = false
    @State private var confirmsDiscard = false
    @Environment(\.dismiss) private var dismiss
    init(target: WorkspaceReviewTarget) { _model = State(initialValue: WorkspaceReviewModel(target: target)) }
    var body: some View {
        NavigationStack {
            Group {
                if model.loading && model.snapshot == nil { ProgressView("读取 Git 改动…") }
                else if let snapshot = model.snapshot {
                    List {
                        Section {
                            Text(snapshot.root).font(.caption.monospaced()).textSelection(.enabled)
                            Text("仅查看改动；批注加入草稿后，由你确认发送。行号基于本次读取，远端继续修改时请复核。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = model.error { Text(error).foregroundStyle(.orange) }
                        }
                        Section("改动文件 · \(snapshot.changes.count)") {
                            if snapshot.changes.isEmpty { Text("工作区干净，没有待提交改动。") }
                            ForEach(snapshot.changes) { change in
                                NavigationLink {
                                    WorkspaceDiffView(change: change, root: snapshot.root, model: model)
                                } label: {
                                    HStack {
                                        Text(change.status).font(.caption.monospaced().bold()).foregroundStyle(.blue)
                                        VStack(alignment: .leading) {
                                            Text(change.path).lineLimit(2)
                                            if let old = change.originalPath { Text("原路径：\(old)").font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }.accessibilityIdentifier("git-change-\(change.path)")
                            }
                        }
                    }.refreshable { await model.load() }
                } else {
                    ContentUnavailableView {
                        Label("无法读取 Git 改动", systemImage: "exclamationmark.triangle")
                    } description: { Text(model.error ?? "请检查连接和工作目录。") }
                    actions: { Button("重试") { Task { await model.load() } } }
                }
            }
            .navigationTitle("Git 改动").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { if model.notes.isEmpty { dismiss() } else { confirmsDiscard = true } }
                        .accessibilityIdentifier("git-review-close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("批注 (\(model.notes.count))") { showsNotes = true }
                        .disabled(model.notes.isEmpty).accessibilityIdentifier("git-review-notes")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { Task { await model.load() } } label: { Label("刷新改动", systemImage: "arrow.clockwise") }
                        .disabled(model.loading)
                }
            }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(!model.notes.isEmpty)
        .confirmationDialog("放弃尚未加入草稿的批注？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃批注", role: .destructive) { dismiss() }
            Button("继续审阅", role: .cancel) { }
        }
        .sheet(isPresented: $showsNotes) {
            WorkspaceReviewNotes(model: model) { dismiss() }
        }
    }
}

private struct WorkspaceDiffView: View {
    let change: WorkspaceGitChange
    let root: String
    let model: WorkspaceReviewModel
    @State private var lines: [WorkspaceDiffLine] = []
    @State private var loading = true
    @State private var error: String?
    @State private var truncated = false
    @State private var selected: WorkspaceDiffLine?
    @State private var comment = ""
    @State private var annotating = false
    @State private var retry = 0
    var body: some View {
        Group {
            if loading { ProgressView("读取差异…") }
            else if let error {
                ContentUnavailableView {
                    Label("差异读取失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error) }
                actions: { Button("重试") { retry += 1 } }
            } else {
                GeometryReader { bounds in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if truncated { Text("仅显示前 256 KiB；完整内容请在终端或文件浏览器查看。")
                            .foregroundStyle(.orange).font(.caption).padding() }
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Button { selected = line; comment = ""; annotating = true } label: {
                                    Text(line.line.map(String.init) ?? "·").frame(minWidth: 44, minHeight: 32)
                                }
                                .disabled(line.line == nil)
                                .accessibilityLabel("批注 \(line.side) 第 \(line.line ?? 0) 行")
                                .accessibilityIdentifier("diff-annotate-\(line.id)")
                                Text(verbatim: line.text.isEmpty ? " " : line.text)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled).padding(.vertical, 6)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.line != nil && (change.untracked || line.text.hasPrefix("+")) ? Color.green.opacity(0.12)
                                : line.line != nil && line.text.hasPrefix("-") ? Color.red.opacity(0.12) : .clear)
                        }
                    }.padding(.trailing).frame(minWidth: bounds.size.width, alignment: .leading)
                }
                }
            }
        }
        .navigationTitle((change.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("批注文件") { selected = nil; comment = ""; annotating = true }
                    .accessibilityIdentifier("git-annotate-file")
            }
        }
        .alert("添加批注", isPresented: $annotating) {
            TextField("审阅意见", text: $comment)
            Button("取消", role: .cancel) { }
            Button("添加") {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { model.notes.append(WorkspaceReviewNote(path: change.path, line: selected?.line, side: selected?.side ?? "文件", comment: text)) }
            }
        } message: { Text(change.path + (selected?.line.map { ":\($0)" } ?? "")) }
        .task(id: retry) {
            loading = true; error = nil
            defer { loading = false }
            do {
                let data = try await model.target.run(WorkspaceGit.diffCommand(root: root, change: change))
                try Task.checkCancellation()
                let result = try WorkspaceGit.diff(data, change: change)
                truncated = result.truncated
                lines = WorkspaceDiffLine.parse(result.text, untracked: change.untracked && !result.text.hasPrefix("二进制文件"))
            } catch is CancellationError { }
            catch { self.error = "文件可能已变化或连接已断开，请刷新改动后重试。" }
        }
    }
}

private struct WorkspaceReviewNotes: View {
    @Bindable var model: WorkspaceReviewModel
    let exported: () -> Void
    @State private var exportError = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach($model.notes) { $note in
                    VStack(alignment: .leading) {
                        Text(note.anchor).font(.caption.monospaced()).foregroundStyle(.secondary)
                        TextField("审阅意见", text: $note.comment, axis: .vertical)
                    }
                }.onDelete { model.notes.remove(atOffsets: $0) }
                    .onMove { model.notes.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationTitle("审阅批注").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    if let root = model.snapshot?.root {
                        ShareLink(item: WorkspaceReviewNote.draft(root: root, notes: model.notes)) {
                            Image(systemName: "square.and.arrow.up")
                        }.accessibilityLabel("导出批注")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("加入草稿，不发送") {
                        guard let root = model.snapshot?.root else { return }
                        let notes = model.notes.filter { !$0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        guard !notes.isEmpty else { return }
                        if model.target.export(WorkspaceReviewNote.draft(root: root, notes: notes)) {
                            model.notes = []; dismiss(); exported()
                        } else { exportError = true }
                    }.disabled(model.notes.isEmpty).accessibilityIdentifier("git-notes-export")
                }
            }
            .alert("草稿未修改", isPresented: $exportError) { Button("好", role: .cancel) { } }
                message: { Text("原连接或窗格已变化。可用分享按钮导出批注，再返回原窗格添加。") }
        }
    }
}
