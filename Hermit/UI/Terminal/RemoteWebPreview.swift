import SwiftUI
import WebKit

@Observable @MainActor
final class RemoteWebPreviewModel: Identifiable {
    let id = UUID()
    let host: String
    let opensOnPresentation: Bool
    let scope: String?
    let preferences: PreviewPreferences
    var preferenceMessage: String?
    var address: String
    private(set) var original: RemoteWebAddress?
    private(set) var localURL: URL?
    private(set) var connecting = false
    var error: String?
    private(set) var suspended = false
    @ObservationIgnored private let acquire: () async throws -> SSHSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tunnel: RemoteWebTunnel?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored weak var browser: WKWebView?

    init(host: String, url: URL? = nil, scope: String? = nil, preferences: PreviewPreferences? = nil, acquire: @escaping () async throws -> SSHSession) {
        self.host = host; self.scope = scope; self.preferences = preferences ?? .shared
        opensOnPresentation = url != nil
        address = url?.absoluteString ?? "http://localhost:3000"; self.acquire = acquire
    }
    var favorites: [PreviewPreferences.WebEntry] { scope.map { preferences.favorites(scope: $0) } ?? [] }
    var recent: [PreviewPreferences.WebEntry] { scope.map { preferences.recent(scope: $0) } ?? [] }
    var isFavorite: Bool { scope.map { preferences.isFavorite(scope: $0, address: address) } ?? false }
    func toggleFavorite() {
        guard let scope else { return }
        if !preferences.toggleFavorite(scope: scope, address: address) { preferenceMessage = "收藏已满，请先取消一个收藏。" }
    }
    func loaded(_ webView: WKWebView) {
        guard browser === webView, let scope, let original, let localURL,
              webView.url?.host == localURL.host, webView.url?.port == localURL.port else { return }
        preferences.record(scope: scope, address: original.url.absoluteString)
    }
    func start() {
        stop(); suspended = false; error = nil
        let parsed: RemoteWebAddress
        do { parsed = try RemoteWebAddress(address) }
        catch { self.error = error.localizedDescription; return }
        original = parsed; connecting = true
        let generation = self.generation
        task = Task { [weak self, acquire] in
            var opened: RemoteWebTunnel?
            do {
                let ssh = try await acquire()
                try Task.checkCancellation()
                let tunnel = try await ssh.startWebPreview(port: parsed.port)
                opened = tunnel
                guard let self, self.generation == generation, !Task.isCancelled else { tunnel.stop(); return }
                self.tunnel = tunnel
                self.localURL = parsed.localURL(port: tunnel.localPort)
                self.connecting = false
                self.task = nil
            } catch {
                opened?.stop()
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.connecting = false; self.error = error.localizedDescription; self.task = nil
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        browser?.stopLoading(); tunnel?.stop(); tunnel = nil
        localURL = nil; connecting = false
    }
    func suspend() { stop(); suspended = true }
    func open(_ url: URL) {
        // Only same-port loopback redirects stay in this forwarding scope.
        guard let original, RemoteWebAddress.isLoopback(url), url.scheme == "http", (url.port ?? 80) == original.port,
              let localURL, let port = localURL.port else { return }
        guard let mapped = try? RemoteWebAddress(url.absoluteString) else { return }
        browser?.load(URLRequest(url: mapped.localURL(port: port)))
    }
    deinit { task?.cancel(); tunnel?.stop() }
}

private struct RemoteWebPreviewFactoryKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL?) -> RemoteWebPreviewModel?)? = nil
}
extension EnvironmentValues {
    var remoteWebPreviewFactory: (@MainActor (URL?) -> RemoteWebPreviewModel?)? {
        get { self[RemoteWebPreviewFactoryKey.self] }
        set { self[RemoteWebPreviewFactoryKey.self] = newValue }
    }
}

struct RemoteWebPreview: View {
    @Bindable var model: RemoteWebPreviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("远端主机 · \(model.host)", systemImage: "desktopcomputer").font(.subheadline).lineLimit(1)
                    HStack {
                        TextField("http://localhost:3000", text: $model.address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .focused($editing).submitLabel(.go).onSubmit { connect() }
                            .accessibilityIdentifier("remote-web-address")
                        if model.scope != nil {
                            Button { model.toggleFavorite() } label: {
                                Image(systemName: model.isFavorite ? "star.fill" : "star").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(model.isFavorite ? "取消收藏预览地址" : "收藏预览地址")
                            .accessibilityIdentifier("remote-web-favorite")
                            .disabled(PreviewPreferences.savedAddress(model.address) == nil)
                            Menu {
                                if !model.favorites.isEmpty {
                                    Section("收藏") { ForEach(model.favorites) { entry in historyButton(entry) } }
                                }
                                if !model.recent.isEmpty {
                                    Section("最近访问") { ForEach(model.recent) { entry in historyButton(entry) } }
                                    Button("清空最近访问", role: .destructive) {
                                        if let scope = model.scope { model.preferences.clearRecent(scope: scope) }
                                    }
                                }
                                Text("仅保存本主机的地址和路径；查询参数不保存。")
                            } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 44, height: 44) }
                            .accessibilityLabel("收藏与最近预览").accessibilityIdentifier("remote-web-history")
                            .disabled(model.favorites.isEmpty && model.recent.isEmpty)
                        }
                        Button { connect() } label: {
                            Image(systemName: model.localURL == nil ? "arrow.right" : "arrow.clockwise")
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("打开网页预览").accessibilityIdentifier("remote-web-open")
                    }
                    Text("通过当前 SSH 访问此主机的 HTTP 本地服务。关闭预览或进入后台会断开转发。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if let error = model.error {
                    ContentUnavailableView {
                        Label("网页暂时无法打开", systemImage: "exclamationmark.triangle").accessibilityIdentifier("remote-web-error")
                    } description: {
                        Text(error)
                        Text("请确认远端服务正在运行，且 SSH 服务器允许端口转发。")
                    } actions: { Button("重试") { connect() }.buttonStyle(.borderedProminent) }
                } else if model.connecting {
                    ProgressView("正在连接远端服务…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.localURL != nil {
                    RemoteWebBrowser(model: model)
                } else {
                    ContentUnavailableView(model.suspended ? "预览已暂停" : "预览远端网页", systemImage: "globe",
                        description: Text(model.suspended ? "返回前台后，点击打开继续预览。" : "输入远端开发服务地址，例如 localhost:3000 或 localhost:5173。"))
                }
            }
            .navigationTitle("网页预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { model.stop(); dismiss() } } }
        }
        .task { if model.opensOnPresentation, model.original == nil, !model.suspended { connect() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.suspend() } }
        .onDisappear { model.stop() }
        .alert("预览收藏", isPresented: Binding(get: { model.preferenceMessage != nil }, set: { if !$0 { model.preferenceMessage = nil } })) {
            Button("好", role: .cancel) { model.preferenceMessage = nil }
        } message: { Text(model.preferenceMessage ?? "") }
    }
    private func historyButton(_ entry: PreviewPreferences.WebEntry) -> some View {
        Button { model.address = entry.address; connect() } label: {
            Label(entry.address, systemImage: entry.favorite ? "star.fill" : "clock")
        }
    }
    private func connect() { editing = false; model.start() }
}

private struct RemoteWebBrowser: UIViewRepresentable {
    let model: RemoteWebPreviewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator; web.allowsBackForwardNavigationGestures = true
        web.accessibilityIdentifier = "remote-web-content"
        model.browser = web
        if let url = model.localURL { web.load(URLRequest(url: url, timeoutInterval: 30)) }
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil; view.loadHTMLString("", baseURL: nil)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: RemoteWebPreviewModel?
        init(model: RemoteWebPreviewModel) { self.model = model }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let model, let local = model.localURL else { decisionHandler(.cancel); return }
            if url.scheme == "http", url.host == local.host, url.port == local.port {
                if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request) }
                else { decisionHandler(.allow) }
            } else if RemoteWebAddress.isLoopback(url) {
                decisionHandler(.cancel)
                if url.scheme == "http", (url.port ?? 80) == model.original?.port { model.open(url) }
                else { model.error = "该链接使用了另一个端口或 HTTPS，请在地址栏单独打开对应的 HTTP 服务。" }
            } else {
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { model?.loaded(webView) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            let error = error as NSError
            // Canceling a loopback redirect before loading its forwarded URL
            // produces WebKit's policy-interruption error, not a failed page.
            guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled),
                  !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
            model?.error = "远端网页加载失败。\(error.localizedDescription)"
        }
    }
}
