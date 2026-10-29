import SwiftUI

/// Saved SSH hosts and the controls needed to manage them.
/// SessionHub continues to own transports and live sessions.
struct LaunchpadView: View {
    let connections: [ServerConnection]
    let hub: SessionHub
    @Binding var searchText: String
    let onAdd: () -> Void
    let onEdit: (ServerConnection) -> Void
    let onOpen: (UUID) -> Void
    let onDelete: (ServerConnection) -> Void
    let onDisconnect: (ServerConnection) -> Void
    let disconnectingIds: Set<UUID>
    let onSettings: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if connections.isEmpty {
                    Button(action: onAdd) {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("还没有主机", systemImage: "plus.circle")
                                .font(.headline).foregroundStyle(.blue)
                            Text("添加 SSH 主机，开始远程工作")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-add-empty")
                }
                if !connections.isEmpty && visibleConnections.isEmpty {
                    ContentUnavailableView {
                        Label("No matching hosts", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search by name, address, username, or transport.")
                    } actions: {
                        Button("Clear search") { searchText = "" }
                            .accessibilityIdentifier("home-clear-search")
                    }
                    // Keep identifiers on actionable children. An identifier
                    // on ContentUnavailableView propagates to its actions and
                    // masks the clear button in the accessibility hierarchy.
                }
                ForEach(visibleConnections) { host in hostCard(host) }
            }
            .padding(.horizontal, 20).padding(.vertical, 22)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.071))
        .foregroundStyle(.white)
        .navigationTitle("SSH 主机")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search hosts"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置")
                    .accessibilityIdentifier("home-settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAdd) { Image(systemName: "plus") }
                    .accessibilityLabel("添加主机")
                    .accessibilityIdentifier("home-add")
            }
        }
    }

    private let cardFill = Color.white.opacity(0.045)

    private var visibleConnections: [ServerConnection] {
        HostListPresentation.filtered(connections, query: searchText)
    }

    private func hostCard(_ host: ServerConnection) -> some View {
        Button { onOpen(host.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer").font(.system(size: 21)).foregroundStyle(.blue)
                    .frame(width: 40, height: 40).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(host.displayName).font(.headline).foregroundStyle(.white)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        connectionStatus(host)
                    }
                    Text(HostListPresentation.endpoint(for: host))
                        .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { route(host); sessionMode(host) }
                        VStack(alignment: .leading, spacing: 5) { route(host); sessionMode(host) }
                    }
                }
            }.padding(16).background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
        .disabled(disconnectingIds.contains(host.id))
        .accessibilityIdentifier("connection-card-\(host.displayName)")
        .contextMenu {
            Button("编辑主机", systemImage: "pencil") { onEdit(host) }
            if hub.session(for: host) != nil {
                Button("断开连接", systemImage: "bolt.slash") { onDisconnect(host) }
                    .accessibilityIdentifier("disconnect-host-\(host.id)")
            }
            Button("删除主机", systemImage: "trash", role: .destructive) { onDelete(host) }
        }
    }

    private func route(_ host: ServerConnection) -> some View {
        Label(HostListPresentation.routeLabel(for: host), systemImage: HostListPresentation.routeSymbol(for: host))
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.055), in: Capsule())
            .fixedSize()
    }

    private func sessionMode(_ host: ServerConnection) -> some View {
        Text(HostListPresentation.sessionLabel(for: host))
            .font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder private func connectionStatus(_ host: ServerConnection) -> some View {
        if disconnectingIds.contains(host.id) {
            ProgressView().accessibilityLabel("正在断开连接")
        } else {
            let status = statusPresentation(for: host)
            Label {
                Text(status.label)
            } icon: {
                Circle().fill(status.color).frame(width: 5, height: 5)
            }
            .font(.caption2).foregroundStyle(status.color).fixedSize()
        }
    }

    private func statusPresentation(for host: ServerConnection) -> (label: String, color: Color) {
        guard let session = hub.session(for: host) else {
            return (String(localized: "Not connected"), .secondary)
        }
        switch session.viewModel.connState {
        case .live: return (String(localized: "Connected"), .green)
        case .connecting: return (String(localized: "Connecting"), .blue)
        case .reconnecting: return (String(localized: "Reconnecting"), .orange)
        case .offline: return (String(localized: "Disconnected"), .secondary)
        }
    }
}
