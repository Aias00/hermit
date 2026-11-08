import Testing
import WebKit
@testable import Moshpit

@Suite("Workspace review parsing and isolation")
struct WorkspaceReviewTests {
    @Test func nulStatusPreservesSpacesNewlinesAndRenames() throws {
        let raw = Data("/repo\0 M space file.swift\0R  renamed.swift\0old.swift\0?? new\nfile.md\0".utf8)
        let result = try WorkspaceGit.parseStatus(raw)
        #expect(result.root == "/repo")
        #expect(result.changes.map(\.path) == ["space file.swift", "renamed.swift", "new\nfile.md"])
        #expect(result.changes[1].originalPath == "old.swift")
        #expect(result.changes[2].untracked)
        #expect(try WorkspaceGit.parseStatus(Data("/repo\0".utf8)).changes.isEmpty)
    }
    @Test(arguments: ["fatal: not a git repository", "/repo\0R  missing\0", "/repo\0?? ../escape\0", "/repo\0?? /absolute\0", "/repo\0 M truncated"])
    func rejectsMalformedAndEscapingPaths(_ value: String) {
        #expect(throws: WorkspaceReviewError.self) { try WorkspaceGit.parseStatus(Data(value.utf8)) }
    }
    @Test func diffLinesUseHunkSideAndResetBetweenStagedAndWorking() {
        let source = "--- 暂存区 ---\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -8,2 +9,2 @@\n context\n--- old content\n+++ new content\n--- 工作区 ---\ndiff --git a/x b/x\n@@ -20 +21 @@\n-next\n+replacement"
        let lines = WorkspaceDiffLine.parse(source)
        #expect(lines[5].line == 9)
        #expect(lines[6].line == 9 && lines[6].side == "暂存区·旧文件")
        #expect(lines[7].line == 10 && lines[7].side == "暂存区·新文件")
        #expect(lines[11].line == 20 && lines[12].line == 21)
        #expect(lines[12].side == "工作区·新文件")
        #expect(WorkspaceDiffLine.parse("--- not a diff\n@@ literal", untracked: true).map(\.line) == [1, 2])
    }
    @Test func boundedDiffAndBinaryContent() throws {
        let change = WorkspaceGitChange(status: " M", path: "file", originalPath: nil)
        let big = Data(repeating: 65, count: WorkspaceGit.diffLimit + 1)
        let value = try WorkspaceGit.diff(big, change: change)
        #expect(value.truncated && value.text.utf8.count == WorkspaceGit.diffLimit)
        #expect(try WorkspaceGit.diff(Data([0, 1]), change: change).text.contains("二进制"))
        #expect(throws: WorkspaceReviewError.self) { try WorkspaceGit.parseStatus(big) }
    }
    @Test func resourcePathsStayInPreviewOrigin() throws {
        #expect(try StaticHTMLResource.relativePath(URL(string: "hermit-report://fixture/%E6%8A%A5%E5%91%8A/a.css?v=1")!, host: "fixture") == "报告/a.css")
        for source in ["hermit-report://other/a.css", "https://fixture/a.css", "hermit-report://fixture/%2e%2e/secret", "hermit-report://fixture/a/%2e%2e/b", "hermit-report://fixture/a%00.css", "hermit-report://fixture/a%5cb.css"] {
            #expect(throws: WorkspaceReviewError.self) { try StaticHTMLResource.relativePath(URL(string: source)!, host: "fixture") }
        }
    }
    @Test func incompleteAndOversizeResourceNeverRenders() throws {
        let body = Data("HERMIT_FILE\ncontent\nHERMIT_END".utf8)
        #expect(try StaticHTMLResource.decode(body, limit: 7) == Data("content".utf8))
        #expect(throws: WorkspaceReviewError.self) { try StaticHTMLResource.decode(body, limit: 6) }
        #expect(throws: WorkspaceReviewError.self) { try StaticHTMLResource.decode(Data("HERMIT_FILE\ncontent".utf8), limit: 100) }
    }
    @Test @MainActor func reviewAppendCanBeUndoneWithoutSending() {
        let draft = TerminalComposerDraft()
        draft.text = "原有草稿"
        let text = WorkspaceReviewNote.draft(root: "/repo", notes: [WorkspaceReviewNote(path: "src/a.swift", line: 12, comment: "检查取消处理")])
        draft.append("\n" + text, kind: .review)
        #expect(draft.text.contains("src/a.swift:12") && draft.text.contains("检查取消处理"))
        #expect(!draft.isSending && draft.delivery == .idle && draft.canUndoAddition)
        draft.undoAddition()
        #expect(draft.text == "原有草稿")
    }
    private actor Reader {
        var active = 0
        var maximum = 0
        var calls = 0
        func run(_ command: String) async throws -> Data {
            active += 1; maximum = max(maximum, active); calls += 1
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            return Data("HERMIT_FILE\nbody\nHERMIT_END".utf8)
        }
    }
    @Test func resourcesSerializeAndStopAtRequestBudget() async throws {
        let reader = Reader()
        let resources = StaticHTMLResources(path: "/repo/index.html", run: { try await reader.run($0) })
        try await withThrowingTaskGroup(of: Data.self) { group in
            for i in 0..<12 { group.addTask { try await resources.read("asset\(i).css") } }
            for try await data in group { #expect(data == Data("body".utf8)) }
        }
        #expect(await reader.maximum == 1)
        for _ in 12..<64 { _ = try await resources.read("asset.css") }
        await #expect(throws: WorkspaceReviewError.self) { try await resources.read("extra.css") }
        #expect(await reader.calls == 64)
    }

    @Test @MainActor func refreshPinsDirectoryAndPreservesNotesOnRootChange() async {
        var directoryCalls = 0
        let replies = ReplySequence()
        let target = WorkspaceReviewTarget(run: { _ in await replies.next() }, directory: {
            directoryCalls += 1; return "/first"
        }, export: { _ in false })
        let model = WorkspaceReviewModel(target: target)
        await model.load()
        model.notes = [WorkspaceReviewNote(path: "file", line: 1, comment: "keep")]
        await model.load()
        #expect(directoryCalls == 1)
        #expect(model.snapshot?.root == "/first" && model.notes.first?.comment == "keep")
        #expect(model.error != nil)
    }
    private actor ReplySequence {
        var count = 0
        func next() -> Data {
            count += 1
            return Data((count == 1 ? "/first\0" : "/second\0").utf8)
        }
    }

    @Test func inspectionCancellationLeavesSSHUsable() async throws {
        let transport = InspectionTransport()
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let work = Task { try await session.inspectWorkspace("hang") }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.started)
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        for _ in 0..<100 {
            if await transport.cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.cancelled)
        #expect(try await session.executeCommand("next") == Data("ready".utf8))
        #expect(await transport.shutdowns == 0)
        await session.close()
    }
    private actor InspectionTransport: SSHClientTransport {
        var started = false, cancelled = false
        var shutdowns = 0
        func run(_ command: String) async throws -> Data {
            if command == "hang" {
                started = true
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = true; throw error }
            }
            return Data("ready".utf8)
        }
        func openPTY(rows: Int, cols: Int, onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter { Writer() }
        func shutdown() async { shutdowns += 1 }
    }
    private struct Writer: SSHPTYWriter {
        func write(_ data: Data) async throws { }
        func resize(cols: Int, rows: Int) async throws { }
    }
}

@Suite("Static report WebKit isolation", .serialized) @MainActor
struct StaticHTMLWebTests {
    private actor Reads {
        var commands: [String] = []
        func run(_ command: String) async throws -> Data {
            commands.append(command)
            return try await WorkspaceReviewFixture.run(command)
        }
        var hasAssets: Bool { commands.contains { $0.contains("report.css") } && commands.contains { $0.contains("icon.svg") } }
    }
    @Test func cssAndImagesRenderWithoutExecutingScripts() async throws {
        let reads = Reads()
        let document = StaticHTMLDocument(path: "/isolated/review/report.html", run: { try await reads.run($0) })
        var loading = true
        var error: String?
        let handler = StaticHTMLWebView.Handler(document: document,
            error: .init(get: { error }, set: { error = $0 }), loading: .init(get: { loading }, set: { loading = $0 }))
        let web = StaticHTMLWebView.webView(document: document, handler: handler)
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        defer { web.stopLoading(); handler.stop() }
        for _ in 0..<250 {
            if !loading, await reads.hasAssets { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(!loading && error == nil)
        #expect(await reads.hasAssets)
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        // The sandbox also rejects app-injected page-world JavaScript. Do not
        // weaken the production CSP merely to inspect the DOM in a test.
        await #expect(throws: (any Error).self) { try await web.evaluateJavaScript("document.body.innerHTML='UNSAFE SCRIPT RAN'") }
        let original = web.url
        web.load(URLRequest(url: URL(string: "https://example.invalid/blocked")!))
        try await Task.sleep(for: .milliseconds(200))
        #expect(web.url == original)
    }
}
