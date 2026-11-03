import Testing
import WebKit
@testable import Moshpit

@Suite("Offline Markdown preview") @MainActor
struct MarkdownPreviewTests {
    @Test("Markdown files retain their exact source and non-file URLs are never fetched")
    func localFilesOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".MD")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "# 中文\n\n```mermaid\nflowchart TD\nA --> B\n```\n"
        try source.write(to: url, atomically: true, encoding: .utf8)
        #expect(MarkdownFileDocument.load(url)?.text == source)
        #expect(MarkdownFileDocument.load(URL(string: "https://example.invalid/doc.md")!) == nil)
    }
    @Test("Narrow-terminal Mermaid fallback is recovered without rewriting fenced code")
    func terminalDiagramFallback() {
        let source = "This Mermaid diagram doesn't fit the current\nterminal width.\nflowchart TD\n  A[输入] → B[处理]\n\n正文\n```sh\nflowchart TD\nA → B\n```"
        let prepared = MarkdownPreviewSource.prepare(source)
        #expect(prepared.contains("```mermaid\nflowchart TD\nA[输入] --> B[处理]\n```"))
        #expect(prepared.contains("正文\n```sh\nflowchart TD\nA → B\n```"))
        #expect(!prepared.contains("doesn't fit"))
    }

    @Test("Bundled renderer produces headings, tables and Mermaid offline and removes unsafe content")
    func rendersOffline() async throws {
        let url = try #require(MarkdownPreview.resourceURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        var ready = false
        for _ in 0..<250 {
            ready = (try? await web.evaluateJavaScript("typeof window.renderMarkdown === 'function'")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(ready)
        let source = "# 中文标题\n\n| 名称 | 状态 |\n| --- | --- |\n| HERDR | 正常 |\n\n```mermaid\nflowchart TD\nA[输入] --> B[处理]\n```\n\n<script>window.compromised=true</script><img src=\"https://example.invalid/tracker\"><a href=\"javascript:alert(1)\">bad</a>"
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("return await window.renderMarkdown(source)",
                arguments: ["source": source], in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
        }
        let counts = try #require(result as? [String: Any])
        #expect(counts["headings"] as? Int == 1)
        #expect(counts["tables"] as? Int == 1)
        #expect(counts["diagrams"] as? Int == 1)
        let labels = try await web.evaluateJavaScript("document.querySelector('#content svg').textContent") as? String
        #expect(labels?.contains("输入") == true)
        #expect(labels?.contains("处理") == true)
        let safe = try await web.evaluateJavaScript("!window.compromised && document.querySelectorAll('#content script,#content img,#content a[href^=\"javascript:\"]').length === 0")
        #expect(safe as? Bool == true)
        web.stopLoading()
    }
}
