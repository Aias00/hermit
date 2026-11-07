import Testing
import WebKit
@testable import Moshpit

@Suite("Offline Markdown preview") @MainActor
struct MarkdownPreviewTests {
    private final class Messages: NSObject, WKScriptMessageHandler {
        var copies: [String] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], body["type"] as? String == "copy", let text = body["text"] as? String { copies.append(text) }
        }
    }
    private func renderer(messages: Messages? = nil) async throws -> WKWebView {
        let url = try #require(MarkdownPreview.resourceURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let messages { configuration.userContentController.add(messages, name: "hermitMarkdown") }
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
    @Test("Reader searches literal Unicode text, navigates matches and refreshes safely")
    func renderedSearchAndOutline() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        let source = "# 中文目录\n\nAlpha **alpha** [a+b] 中文\n\n## 下一节\n\n```sh\nprintf 'alpha'\n```"
        _ = try await render(source, in: web)
        let result = try #require(try await execute("return window.hermitMarkdownReader.search(query)", arguments: ["query": "alpha"], in: web) as? [String: Any])
        #expect(result["count"] as? Int == 3)
        #expect(result["index"] as? Int == 1)
        let next = try #require(try await execute("return window.hermitMarkdownReader.search(query,-1)", arguments: ["query": "alpha"], in: web) as? [String: Any])
        #expect(next["index"] as? Int == 3)
        _ = try await render(source + "\n\nALPHA", in: web)
        #expect(try await web.evaluateJavaScript("window.hermitMarkdownReader.state().count") as? Int == 4)
        #expect(try await web.evaluateJavaScript("window.hermitMarkdownReader.state().index") as? Int == 3)
        let literal = try #require(try await execute("return window.hermitMarkdownReader.search(query)", arguments: ["query": "[a+b]"], in: web) as? [String: Any])
        #expect(literal["count"] as? Int == 1)
        let outline = try #require(literal["outline"] as? [[String: Any]])
        #expect(outline.count == 2)
        #expect(outline.first?["title"] as? String == "中文目录")
        #expect(try await web.evaluateJavaScript("window.hermitMarkdownReader.jump('hermit-heading-1')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("window.hermitMarkdownReader.jump('arbitrary')") as? Bool == false)
        _ = try await render("replacement", in: web)
        #expect(try await web.evaluateJavaScript("window.hermitMarkdownReader.state().count === 0 && window.hermitMarkdownReader.state().outline.length === 0 && !document.querySelector('.reader-dialog')") as? Bool == true)
    }

    @Test("Reader caps large searches and preserves copy sources and unique diagram references")
    func readerToolsAndExpandedGraph() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        _ = try await render("# Tools\n\n" + String(repeating: "needle ", count: 1100), in: web)
        let state = try #require(try await execute("return window.hermitMarkdownReader.search(query)", arguments: ["query": "needle"], in: web) as? [String: Any])
        #expect(state["count"] as? Int == 1000)
        #expect(state["limited"] as? Bool == true)
        _ = try await render("```mermaid\nflowchart TD\nA --> B\n```\n\n| Key | Value |\n| --- | --- |\n| one | two |", in: web)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-reader-action=copy-code]').length") as? Int == 1)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-reader-action=expand-diagram]').click();true")
        #expect(try await web.evaluateJavaScript("document.querySelector('dialog').open") as? Bool == true)
        #expect(try await web.evaluateJavaScript("(()=>{const svg=document.querySelector('dialog svg');const ids=[...document.querySelectorAll('[id]')].map(n=>n.id);return ids.length===new Set(ids).size && [...svg.querySelectorAll('style')].some(n=>n.textContent.includes('#'+svg.id)) && [...svg.querySelectorAll('[marker-end]')].every(n=>document.getElementById(n.getAttribute('marker-end').match(/#([^)'\"]+)/)[1]))})()") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-reader-action=zoom-in]').click();document.querySelector('[data-reader-action=close]').click();document.querySelector('[data-reader-action=expand-table]').click();true")
        #expect(try await web.evaluateJavaScript("document.querySelector('dialog table').textContent.includes('two')") as? Bool == true)
        _ = try await render("fresh document", in: web)
        #expect(try await web.evaluateJavaScript("!document.querySelector('dialog') && document.querySelectorAll('#content button').length===0") as? Bool == true)
    }

    @Test("Content cannot forge native reader actions")
    func readerSanitization() async throws {
        let messages = Messages()
        let web = try await renderer(messages: messages)
        defer { web.stopLoading() }
        _ = try await render("<button data-reader-action='expand-diagram'>spoof</button><textarea>bad</textarea><a href='file:///etc/passwd'>file</a>\n\n```sh\n  printf '中文'\n\n```", in: web)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#content button').length === 1 && !document.querySelector('#content textarea') && !document.querySelector('#content a[href]')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('#content pre code').textContent") as? String == "  printf '中文'\n")
        _ = try await web.evaluateJavaScript("window.hermitMarkdownReader.search('printf');document.querySelector('[data-reader-action=copy-code]').click();true")
        for _ in 0..<20 where messages.copies.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(messages.copies == ["  printf '中文'\n"])
    }

    @Test("Reading anchors survive appended text and width changes without applying to unrelated content")
    func semanticReadingPosition() async throws {
        let web = try await renderer()
        defer { web.stopLoading() }
        let source = (0..<150).map { "## Section \($0)\n\nParagraph \($0) " + String(repeating: "readable text 中文 ", count: 12) }.joined(separator: "\n\n")
        _ = try await render(source, in: web)
        let result = try #require(try await execute("document.querySelectorAll('#content h2')[60].scrollIntoView(); await new Promise(r=>setTimeout(r,40)); return window.hermitMarkdownReader.position()", arguments: [:], in: web) as? [String: Any])
        let saved = try #require(PreviewPreferences.ReadingPosition(message: result))
        #expect(saved.index >= 100 && saved.ratio > 0.1)
        _ = try await render(source + "\n\nAdditional tail", in: web)
        let appended = try #require(try await web.evaluateJavaScript("window.hermitMarkdownReader.position()") as? [String: Any])
        #expect(appended["block"] as? String == saved.block)
        web.frame.size.width = 700
        let restored = try await execute("await new Promise(r=>setTimeout(r,40)); return window.hermitMarkdownReader.restore(position)", arguments: ["position": saved.arguments], in: web)
        #expect(restored as? Bool == true)
        let wide = try #require(try await web.evaluateJavaScript("window.hermitMarkdownReader.position()") as? [String: Any])
        #expect(wide["block"] as? String == saved.block)
        _ = try await render("# A completely different document", in: web)
        #expect(try await execute("return window.hermitMarkdownReader.restore(position)", arguments: ["position": saved.arguments], in: web) as? Bool == false)
    }

}
