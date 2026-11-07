import SwiftUI

@Observable @MainActor
final class MarkdownReaderController {
    struct Heading: Identifiable {
        let id: String
        let level: Int
        let title: String
    }
    var query = ""
    private(set) var outline: [Heading] = []
    private(set) var count = 0
    private(set) var index = 0
    private(set) var limited = false
    var copied = false
    var restored = false
    @ObservationIgnored weak var coordinator: MarkdownPreview.Coordinator?

    func update(_ state: [String: Any]) {
        outline = ((state["outline"] as? [[String: Any]]) ?? []).prefix(200).compactMap {
            guard let id = $0["id"] as? String, let level = $0["level"] as? Int,
                  let title = $0["title"] as? String else { return nil }
            return Heading(id: id, level: level, title: title)
        }
        guard state["query"] as? String == String(query.prefix(256)) else { return }
        count = state["count"] as? Int ?? 0
        index = state["index"] as? Int ?? 0
        limited = state["limited"] as? Bool ?? false
    }
    func search(move: Int = 0) {
        coordinator?.command("return window.hermitMarkdownReader.search(query,move)",
                             arguments: ["query": String(query.prefix(256)), "move": move])
    }
    func jump(_ heading: Heading) {
        coordinator?.command("return window.hermitMarkdownReader.jump(id)", arguments: ["id": heading.id])
    }
}

/// Tools belong to the reader, never to the terminal's input responder.
struct MarkdownReader: View {
    let text: String
    var readingIdentity: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.remoteWebPreviewFactory) private var webFactory
    @State private var webPreview: RemoteWebPreviewModel?
    @State private var unavailable = false
    @State private var reader = MarkdownReaderController()
    @State private var searching = false
    @State private var outline = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    searching.toggle()
                    searchFocused = searching
                    if !searching { reader.query = ""; reader.search() }
                } label: { Label("查找", systemImage: "magnifyingglass").frame(minHeight: 44) }
                    .accessibilityIdentifier("markdown-search-toggle")
                Button { outline = true } label: {
                    Label("目录", systemImage: "list.bullet.indent").frame(minHeight: 44)
                }
                .disabled(reader.outline.isEmpty)
                .accessibilityIdentifier("markdown-outline")
                .popover(isPresented: $outline) {
                    NavigationStack {
                        List(reader.outline) { heading in
                            Button {
                                searchFocused = false
                                reader.jump(heading)
                                outline = false
                            } label: {
                                Text(heading.title).foregroundStyle(.primary)
                                    .padding(.leading, CGFloat(heading.level - 1) * 12)
                                    .frame(minHeight: 36, alignment: .leading)
                            }
                        }
                        .navigationTitle("文档目录").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { outline = false } } }
                    }
                    .frame(idealWidth: 360, idealHeight: 420)
                    .presentationDetents([.medium, .large])
                }
                Spacer()
                if reader.restored && !reader.copied {
                    Text("已恢复阅读位置").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("markdown-position-restored")
                }
                if reader.copied {
                    Text("代码已复制").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("markdown-code-copied")
                }
            }
            .font(.subheadline).padding(.horizontal, 16)
            if searching {
                HStack(spacing: 8) {
                    TextField("查找文档内容", text: $reader.query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.search).onSubmit { reader.search(move: 1) }
                        .accessibilityIdentifier("markdown-query")
                    Text("\(reader.index)/\(reader.count)\(reader.limited ? "+" : "")")
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("markdown-match-count")
                    Button { reader.search(move: -1) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                        .accessibilityLabel("上一个匹配").disabled(reader.count == 0)
                    Button { reader.search(move: 1) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("下一个匹配").disabled(reader.count == 0)
                }.padding(.horizontal, 16)
            }
            Divider()
            MarkdownPreview(text: text, reader: reader, openRemoteWeb: { url in
                searchFocused = false
                if let model = webFactory?(url) { webPreview = model }
                else { unavailable = true }
            }, readingIdentity: readingIdentity)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.coordinator?.capturePosition(flush: true) } }
        .appSheet(item: $webPreview) { model in RemoteWebPreview(model: model) }
        .alert("需要远端主机", isPresented: $unavailable) {
            Button("好", role: .cancel) {}
        } message: { Text("请从已连接主机的终端打开此文档，再预览其中的本地服务链接。") }
        .task(id: reader.query) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            reader.search()
        }
        .task(id: reader.copied) {
            guard reader.copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            reader.copied = false
        }
    }
}
