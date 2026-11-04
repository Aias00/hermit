import Testing
import WebKit
@testable import Moshpit

@Suite("Offline Markdown preview") @MainActor
struct MarkdownPreviewTests {
    private func renderer() async throws -> WKWebView {
        let url = try #require(MarkdownPreview.resourceURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        for _ in 0..<250 {
            if (try? await web.evaluateJavaScript("typeof window.renderMarkdown === 'function'")) as? Bool == true {
                return web
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw NSError(domain: "MarkdownPreviewTests", code: 1)
    }

    private func render(_ source: String, in web: WKWebView) async throws -> [String: Any] {
        let value = try await execute("return await window.renderMarkdown(source)",
            arguments: ["source": source], in: web)
        return try #require(value as? [String: Any])
    }

    private func execute(_ body: String, arguments: [String: Any], in web: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
    }

    @Test("Appending text preserves existing paragraphs and rendered diagrams")
    func reusesUnchangedBlocks() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        let source = "# 标题\n\n保留这段文字。\n\n```mermaid\nflowchart TD\nA --> B\n```\n"
        let initial = try await render(source, in: web)
        #expect(initial["renderedDiagrams"] as? Int == 1)
        _ = try await web.evaluateJavaScript("window.savedHeading=document.querySelector('#content h1');window.savedDiagram=document.querySelector('#content svg');true")
        let appended = try await render(source + "\n新增正文。", in: web)
        #expect(appended["renderedDiagrams"] as? Int == 0)
        #expect(try await web.evaluateJavaScript("savedHeading === document.querySelector('#content h1') && savedDiagram === document.querySelector('#content svg')") as? Bool == true)
        let identical = try await render(source + "\n新增正文。", in: web)
        #expect(identical["unchanged"] as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content').textContent.includes('新增正文。')") as? Bool == true)
    }

    @Test("Reference definitions invalidate affected text and cached diagrams have unique IDs")
    func referencesAndDuplicateDiagrams() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        _ = try await render("[文档][ref]\n\n[ref]: https://example.com/one", in: web)
        _ = try await render("[文档][ref]\n\n[ref]: https://example.com/two", in: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content a').href") as? String == "https://example.com/two")
        let graph = "```mermaid\nflowchart TD\nA --> B\n```\n\n"
        let result = try await render(graph + graph, in: web)
        #expect(result["diagrams"] as? Int == 2)
        #expect(result["renderedDiagrams"] as? Int == 1)
        #expect(result["reusedDiagrams"] as? Int == 1)
        #expect(try await web.evaluateJavaScript("(()=>{const ids=[...document.querySelectorAll('#content [id]')].map(n=>n.id);return ids.length===new Set(ids).size})()") as? Bool == true)
        #expect(try await web.evaluateJavaScript("[...document.querySelectorAll('#content svg')].every(s=>[...s.querySelectorAll('style')].some(n=>n.textContent.includes('#'+s.id)))") as? Bool == true)
    }

    @Test("Overlapping renders retain only the latest document and a changed graph is rebuilt")
    func latestRequestWins() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        _ = try await execute("return await Promise.all([window.renderMarkdown(old),window.renderMarkdown(next),window.renderMarkdown(final)])",
            arguments: ["old": "```mermaid\nflowchart TD\nA --> B\n```", "next": "intermediate", "final": "# 最新内容"], in: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content').textContent.trim()") as? String == "最新内容")
        let result = try await render("```mermaid\nflowchart TD\nA --> C\n```", in: web)
        #expect(result["renderedDiagrams"] as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content svg').textContent.includes('C')") as? Bool == true)
    }

    @Test("Appearance changes refresh diagram styling without another source update")
    func appearanceInvalidatesDiagrams() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        let source = "```mermaid\nflowchart TD\nA --> B\n```"
        _ = try await execute("return await window.renderMarkdown(source,false)", arguments: ["source": source], in: web)
        _ = try await web.evaluateJavaScript("window.previousDiagram=document.querySelector('#content svg');window.previousColour=getComputedStyle(document.body).color;true")
        _ = try await execute("return await window.renderMarkdown(source,true)", arguments: ["source": source], in: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content svg') !== previousDiagram && document.documentElement.dataset.appearance==='dark' && getComputedStyle(document.body).color !== previousColour") as? Bool == true)
        let repeated = try #require(try await execute("return await window.renderMarkdown(source,true)", arguments: ["source": source], in: web) as? [String: Any])
        #expect(repeated["unchanged"] as? Bool == true)
    }

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
