#if DEBUG
import SwiftUI

/// Isolated simulator fixture: no account, SSH session or real workspace data.
struct WorkspaceReviewFixture: View {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-HERMIT_WORKSPACE_REVIEW_FIXTURE")
        #else
        false
        #endif
    }
    @State private var review: WorkspaceReviewTarget?
    @State private var html: StaticHTMLDocument?
    @State private var draft = "保留原有草稿"
    static let htmlText = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="report.css"></head><body><h1>Hermit 工作区报告</h1><p>静态 HTML 预览已就绪</p><img alt="report icon" src="icon.svg"><p>脚本应保持禁用</p><script>document.body.innerHTML='UNSAFE SCRIPT RAN'</script></body></html>
    """
    static let run: WorkspaceInspection.Run = { command in
        if command.contains("status --porcelain") { return Data("/isolated/review\0 M Sources/demo.swift\0?? report.html\0".utf8) }
        if command.contains("--no-ext-diff") { return Data("--- 工作区 ---\ndiff --git a/Sources/demo.swift b/Sources/demo.swift\n--- a/Sources/demo.swift\n+++ b/Sources/demo.swift\n@@ -1,2 +1,3 @@\n let title = \"Hermit\"\n-oldValue()\n+newValue()\n+finish()\n".utf8) }
        let body: String
        if command.contains("report.css") { body = "body{font:18px -apple-system;padding:24px;background:#edf3ff;color:#1e293b}h1{color:#2563eb}img{width:48px}" }
        else if command.contains("icon.svg") { body = "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'><circle cx='24' cy='24' r='22' fill='#2563eb'/></svg>" }
        else { body = htmlText }
        return Data(("HERMIT_FILE\n" + body + "\nHERMIT_END").utf8)
    }
    var body: some View {
        NavigationStack {
            Form {
                Button("Git 改动与批注") {
                    review = WorkspaceReviewTarget(run: Self.run, directory: { "/isolated/review" }, export: { text in
                        draft += "\n\n" + text; return true
                    })
                }.accessibilityIdentifier("review-fixture-open")
                Button("静态 HTML 报告") { html = StaticHTMLDocument(path: "/isolated/review/report.html", run: Self.run) }
                    .accessibilityIdentifier("review-fixture-html")
                Section("草稿（不会发送）") { TextEditor(text: $draft).frame(minHeight: 180).accessibilityIdentifier("review-fixture-draft") }
            }.navigationTitle("Hermit 验证")
        }
        .sheet(item: $review) { WorkspaceReviewView(target: $0) }
        .sheet(item: $html) { StaticHTMLPreview(document: $0) }
    }
}
#endif
