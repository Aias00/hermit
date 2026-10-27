import SwiftUI

/// The launchpad owns navigation choices; SessionHub continues to own transports.
struct LaunchpadView: View {
    @Environment(DeepLinkRouter.self) private var router
    let connections: [ServerConnection]
    let hub: SessionHub
    @Binding var tab: Int
    let onAdd: () -> Void
    let onEdit: (ServerConnection) -> Void
    let onOpen: (UUID) -> Void
    let onDelete: (ServerConnection) -> Void
    let onSettings: () -> Void
    let onRun: (ServerConnection, String, String) -> Void
    @State private var collapsed: Set<String> = []
    @AppStorage("moshpit.launchItems.v1") private var savedItems = Data()
    @State private var editing: LaunchItem?
    @State private var pendingRun: LaunchItem?

    private var items: [LaunchItem] {
        (try? JSONDecoder().decode([LaunchItem].self, from: savedItems)) ?? LaunchItem.defaults
    }
    private func save(_ item: LaunchItem) {
        var list = items
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item }
        else { list.append(item) }
        persist(list)
    }
    private func persist(_ list: [LaunchItem]) {
        if let data = try? JSONEncoder().encode(list) { savedItems = data }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if tab == 0 { launchpad }
                else if tab == 1 { terminals }
                else { profile }
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 24)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.071))
        .foregroundStyle(.white)
        .navigationTitle(tab == 0 ? "启动台" : tab == 1 ? "Host 终端" : "我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("启动台", systemImage: "square.stack.3d.up") { tab = 0 }.accessibilityIdentifier("launchpad-tab-0")
                    Button("终端活动", systemImage: "terminal") { tab = 1 }.accessibilityIdentifier("launchpad-tab-1")
                    Button("我的", systemImage: "person") { tab = 2 }.accessibilityIdentifier("launchpad-tab-2")
                    Divider()
                    Button("添加主机", action: onAdd).keyboardShortcut("n", modifiers: .command)
                    Button("设置", action: onSettings).keyboardShortcut(",", modifiers: .command)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("主机与设置")
            }
        }
        .appSheet(item: $editing) { item in
            LaunchItemEditor(item: item, connections: connections, onSave: save)
        }
        .confirmationDialog("执行快捷操作", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }), titleVisibility: .visible) {
            if let item = pendingRun, let host = connections.first(where: { $0.id == item.hostID }) {
                Button("在 \(host.displayName) 上运行") {
                    pendingRun = nil
                    onRun(host, item.name, item.shellCommand)
                }
            }
            Button("取消", role: .cancel) { pendingRun = nil }
        } message: {
            if let item = pendingRun { Text("将在独立 SSH 终端执行：\n\(item.shellCommand)") }
        }
    }
    private var launchpad: some View {
        Group {
            sectionHeader("Hosts", add: onAdd)
            if !collapsed.contains("Hosts") {
                if connections.isEmpty { empty("还没有主机", detail: "添加 SSH 主机，开始远程工作", action: onAdd) }
                ForEach(connections) { host in hostCard(host) }
            }
            sectionHeader("Actions", add: { editing = LaunchItem(name: "", command: "") })
            if !collapsed.contains("Actions") { itemGrid(items.filter { !$0.isProject }) }
            sectionHeader("Projects", add: { editing = LaunchItem(name: "", command: "", isProject: true) })
            if !collapsed.contains("Projects") {
                let projects = items.filter(\.isProject)
                if projects.isEmpty {
                    empty("添加第一个项目", detail: "保存主机与工作目录，下次直接进入", action: { editing = LaunchItem(name: "", command: "", isProject: true) })
                } else { itemGrid(projects) }
            }
        }
    }
    private var terminalConnections: [ServerConnection] {
        let saved = Set(connections.map(\.id))
        return connections + hub.sessions.values.filter { !saved.contains($0.connection.id) }
            .map(\.connection).sorted { $0.displayName < $1.displayName }
    }
    private var terminals: some View {
        Group {
            HStack {
                Text("终端活动").font(.title3.bold())
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus").font(.title2) }.accessibilityIdentifier("terminal-add")
            }
            if terminalConnections.isEmpty { empty("暂无终端", detail: "添加主机后即可连接", action: onAdd) }
            ForEach(terminalConnections) { host in
                VStack(alignment: .leading, spacing: 16) {
                    hostCard(host)
                    if let active = hub.session(for: host), let snapshot = active.herdrControl?.snapshot ?? active.tmuxControl?.snapshot {
                        let hooks = active.herdrControl?.agentHooks ?? active.tmuxController?.agentHooks ?? [:]
                        Text("\(host.multiplexer.label) 会话").font(.headline)
                        Text("\(snapshot.sessions.count) 个工作区 · \(snapshot.panes.count) 个窗格 · \(hooks.count) 个 Agent")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(snapshot.sessions.values.sorted(by: { $0.name < $1.name }), id: \.id) { session in
                            Button {
                                let window = snapshot.windows.values.filter { $0.sessionId == session.id }.sorted { $0.index < $1.index }.first
                                if let pane = snapshot.panes.values.filter({ $0.windowId == window?.id }).sorted(by: { $0.index < $1.index }).first {
                                    router.request(connectionId: host.id, paneId: pane.id)
                                }
                                onOpen(host.id)
                            } label: {
                                HStack { Image(systemName: "rectangle.split.2x2"); Text(session.name); Spacer(); Image(systemName: "chevron.right") }
                                    .padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        Text("连接主机后显示实时工作区与 Agent 状态")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var profile: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 42)).foregroundStyle(.blue)
                Text("你的远程工作台").font(.title2.bold())
                Text("\(connections.count) 台主机 · \(items.filter(\.isProject).count) 个项目")
                    .foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(cardFill, in: RoundedRectangle(cornerRadius: 20))
            Button(action: onSettings) {
                HStack { Label("终端、密钥与外观设置", systemImage: "gearshape"); Spacer(); Image(systemName: "chevron.right") }
                    .padding(20).background(cardFill, in: RoundedRectangle(cornerRadius: 18))
            }.accessibilityIdentifier("home-settings")
            Text("凭据保存在系统 Keychain。快捷操作只有确认后才会执行。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private let cardFill = Color.white.opacity(0.045)
    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            Button(action: add) { Image(systemName: "plus").frame(width: 38, height: 36) }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier(title == "Hosts" ? "home-add" : "add-\(title)")
            Button { if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) } } label: {
                Image(systemName: collapsed.contains(title) ? "chevron.down" : "chevron.up").frame(width: 38, height: 36)
            }.background(cardFill, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("折叠或展开 \(title)")
        }.foregroundStyle(.white.opacity(0.85))
    }
    private func hostCard(_ host: ServerConnection) -> some View {
        Button { onOpen(host.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer").font(.system(size: 27)).foregroundStyle(.blue)
                    .frame(width: 54, height: 54).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(host.displayName).font(.headline).foregroundStyle(.white)
                    Text(host.host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Text(host.multiplexer == .none ? host.connectionProtocol.label : host.multiplexer.label)
                        .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.055), in: Capsule())
                    if let session = hub.session(for: host), case .connected = session.viewModel.status {
                        Text("已连接").font(.caption2).foregroundStyle(.green)
                    }
                }.foregroundStyle(.secondary)
            }.padding(18).background(cardFill, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
        .accessibilityIdentifier("connection-card-\(host.displayName)")
        .contextMenu {
            if connections.contains(where: { $0.id == host.id }) {
                Button("编辑主机", systemImage: "pencil") { onEdit(host) }
                Button("删除主机", systemImage: "trash", role: .destructive) { onDelete(host) }
            } else {
                Button("结束终端", systemImage: "xmark.circle", role: .destructive) {
                    Task { await hub.disconnect(host.id) }
                }
            }
        }
    }
    private func itemGrid(_ list: [LaunchItem]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(list) { item in
                Button {
                    if connections.contains(where: { $0.id == item.hostID }) { pendingRun = item }
                    else { editing = item }
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(2)
                        Text(connections.first(where: { $0.id == item.hostID })?.displayName ?? "未设置主机")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Label(item.isProject ? item.directory : item.command, systemImage: item.isProject ? "folder" : "terminal")
                            .font(.caption).foregroundStyle(.blue).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 108, alignment: .leading).padding(17)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
                .contextMenu {
                    Button("编辑", systemImage: "pencil") { editing = item }
                    Button("删除", systemImage: "trash", role: .destructive) { persist(items.filter { $0.id != item.id }) }
                }
            }
        }
    }
    private func empty(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: "plus.circle").font(.headline).foregroundStyle(.blue)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(cardFill, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
}

private struct LaunchItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: LaunchItem
    let connections: [ServerConnection]
    let onSave: (LaunchItem) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $item.name).accessibilityIdentifier("launch-item-name")
                    Picker("主机", selection: $item.hostID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(connections) { host in Text(host.displayName).tag(Optional(host.id)) }
                    }.pickerStyle(.menu).accessibilityIdentifier("launch-item-host")
                }
                Section(item.isProject ? "项目目录与启动命令" : "执行内容") {
                    TextField("绝对目录（可选）", text: $item.directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("命令，例如 codex", text: $item.command, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("launch-item-command")
                }
                Section { Text("运行时会打开独立 SSH 终端，不会向已有 Agent 会话注入命令。留空命令可仅进入项目目录。") }
            }.navigationTitle(item.isProject ? "项目" : "快捷操作").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { onSave(item); dismiss() }
                            .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.hostID == nil || (item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.directory.isEmpty))
                    }
                }
        }.preferredColorScheme(.dark)
    }
}
