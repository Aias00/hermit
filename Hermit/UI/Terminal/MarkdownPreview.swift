import SwiftUI
import WebKit

struct MarkdownFileDocument: Identifiable {
    let url: URL
    let text: String
    var id: URL { url }

    static func load(_ url: URL) -> Self? {
        guard url.isFileURL, ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self(url: url, text: text)
    }
}

struct MarkdownFilePreview: View {
    let document: MarkdownFileDocument
    @State private var preview = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("显示方式", selection: $preview) {
                    Text("Markdown 预览").tag(true)
                    Text("原文").tag(false)
                }.pickerStyle(.segmented).padding()
                if document.text.count > 200_000 {
                    Text("预览仅包含文档前 200,000 个字符；原文可查看全部内容。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if preview { MarkdownPreview(text: document.text) }
                else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: document.text).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).padding()
                    }
                }
            }
            .navigationTitle(document.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { UIPasteboard.general.string = document.text }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Terminal renderers can remove code fences when falling back to a narrow
/// text layout. Recover complete bare Mermaid blocks without interpreting
/// ordinary terminal prose or executable snippets as diagrams.
enum MarkdownPreviewSource {
    static func prepare(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [String] = [], index = 0, fence: Character?
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let character = trimmed.first!
                if fence == character { fence = nil } else if fence == nil { fence = character }
                result.append(line); index += 1; continue
            }
            let flow = trimmed.range(of: #"^(flowchart|graph)\s+(TD|TB|BT|RL|LR)\s*;?$"#, options: .regularExpression) != nil
            if fence == nil, flow {
                var diagram = [trimmed]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.contains("→") || next.contains("-->") || next.contains("---")
                        || next.hasPrefix("subgraph ") || next == "end"
                        || next.hasPrefix("%%") || next.hasPrefix("style ") || next.hasPrefix("classDef ") else { break }
                    diagram.append(next.replacingOccurrences(of: "→", with: "-->"))
                    index += 1
                }
                if diagram.count > 1 { result += ["```mermaid"] + diagram + ["```"] }
                else { result += diagram }
                continue
            }
            if fence == nil, trimmed.hasPrefix("This Mermaid diagram doesn't fit") {
                index += 1
                if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "terminal width." { index += 1 }
                continue
            }
            result.append(line); index += 1
        }
        return result.joined(separator: "\n")
    }
}

struct MarkdownPreview: UIViewRepresentable {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    static var resourceURL: URL? {
        Bundle.main.url(forResource: "Markdown", withExtension: "bundle")?.appendingPathComponent("index.html")
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, darkMode: colorScheme == .dark) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "terminal-markdown-content"
        if let url = Self.resourceURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.loadHTMLString("<p>预览资源不可用，请切换到原文。</p>", baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let darkMode = colorScheme == .dark
        guard !context.coordinator.text.utf8.elementsEqual(text.utf8)
                || context.coordinator.darkMode != darkMode else { return }
        context.coordinator.text = text
        context.coordinator.darkMode = darkMode
        if context.coordinator.loaded { context.coordinator.render(view) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var text: String
        var darkMode: Bool
        var loaded = false
        init(text: String, darkMode: Bool) { self.text = text; self.darkMode = darkMode }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(webView)
        }
        func render(_ webView: WKWebView) {
            webView.callAsyncJavaScript("return await window.renderMarkdown(source,darkMode)",
                arguments: ["source": MarkdownPreviewSource.prepare(text), "darkMode": darkMode], in: nil, in: .page) { _ in }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.request.url?.isFileURL == true || action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }
    }
}
