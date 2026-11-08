import SwiftUI
import WebKit

struct StaticHTMLDocument: Identifiable {
    let id = UUID()
    let path: String
    let run: WorkspaceInspection.Run
    init(path: String, files: RemoteFileAccess) { self.path = path; run = WorkspaceInspection.runner(files) }
    init(path: String, run: @escaping WorkspaceInspection.Run) { self.path = path; self.run = run }
}

struct StaticHTMLPreview: View {
    let document: StaticHTMLDocument
    @State private var error: String?
    @State private var revision = 0
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    VStack {
                        Text(error).font(.callout).foregroundStyle(.orange)
                        Button("重新加载") { self.error = nil; loading = true; revision += 1 }
                    }.padding()
                }
                StaticHTMLWebView(document: document, error: $error, loading: $loading).id(revision)
                    .overlay { if loading { ProgressView("打开静态报告…") } }
                Text("静态报告 · 脚本和外部网络已禁用")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            .navigationTitle((document.path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("static-html-close")
            } }
        }
    }
}

struct StaticHTMLWebView: UIViewRepresentable {
    let document: StaticHTMLDocument
    @Binding var error: String?
    @Binding var loading: Bool
    func makeCoordinator() -> Handler { Handler(document: document, error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        Self.webView(document: document, handler: context.coordinator)
    }
    static func webView(document: StaticHTMLDocument, handler: Handler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(handler, forURLScheme: "hermit-report")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = handler
        view.accessibilityIdentifier = "static-html-content"
        var url = URLComponents()
        url.scheme = "hermit-report"; url.host = handler.host
        url.path = "/" + (document.path as NSString).lastPathComponent
        if let url = url.url { view.load(URLRequest(url: url)) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Handler) {
        view.stopLoading(); view.navigationDelegate = nil; coordinator.stop()
    }

    @MainActor final class Handler: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        let host = UUID().uuidString.lowercased()
        let resources: StaticHTMLResources
        let documentName: String
        var error: Binding<String?>
        var loading: Binding<Bool>
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        init(document: StaticHTMLDocument, error: Binding<String?>, loading: Binding<Bool>) {
            self.resources = StaticHTMLResources(path: document.path, run: document.run)
            self.documentName = (document.path as NSString).lastPathComponent
            self.error = error
            self.loading = loading
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { tasks[id] = nil }
                do {
                    guard let url = urlSchemeTask.request.url else { throw WorkspaceReviewError.invalidPath }
                    let path = try StaticHTMLResource.relativePath(url, host: host)
                    guard let mime = StaticHTMLResource.mimeTypes[(path as NSString).pathExtension.lowercased()]
                    else { throw WorkspaceReviewError.invalidPath }
                    let data = try await resources.read(path)
                    try Task.checkCancellation()
                    guard tasks[id] != nil else { return }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
                        "Content-Security-Policy": StaticHTMLResource.csp, "Cache-Control": "no-store"
                    ])!
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                } catch {
                    guard tasks[id] != nil, !Task.isCancelled else { return }
                    self.loading.wrappedValue = false
                    self.error.wrappedValue = "部分内容无法预览。仅支持报告目录内的 HTML、CSS、图片和字体；文件可能超出大小限制或连接已断开。"
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        }
        func stop() { let pending = tasks.values; tasks = [:]; pending.forEach { $0.cancel() } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let path = navigationAction.request.url.flatMap { try? StaticHTMLResource.relativePath($0, host: host) }
            decisionHandler(path == documentName && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }
}
