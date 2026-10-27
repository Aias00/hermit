import SwiftUI

enum TerminalChrome {
    static let background = Color(red: 13.0 / 255, green: 27.0 / 255, blue: 40.0 / 255)
    static let control = Color(red: 34.0 / 255, green: 48.0 / 255, blue: 62.0 / 255)
    static let foreground = Color(red: 186.0 / 255, green: 197.0 / 255, blue: 210.0 / 255)
    static let selectedTab = Color(red: 138.0 / 255, green: 180.0 / 255, blue: 248.0 / 255)
}

/// Native workspace controls with the compact hierarchy of herdr's sidebar.
struct ConversationWorkspaceSidebar: View {
    let snapshot: TmuxSnapshot
    let hooks: [String: AgentHook]
    let selectSession: (String) -> Void
    let selectPane: (String) -> Void
    let manage: () -> Void
    let create: () -> Void
    let collapse: () -> Void

    private let foreground = Color(red: 157.0 / 255, green: 166.0 / 255, blue: 190.0 / 255)
    private let muted = Color(red: 111.0 / 255, green: 122.0 / 255, blue: 143.0 / 255)
    private let selection = Color(red: 33.0 / 255, green: 30.0 / 255, blue: 49.0 / 255)
    private var sessions: [SessionInfo] {
        snapshot.sessions.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    private var agents: [PaneInfo] {
        snapshot.panes.values.filter { hooks[$0.id] != nil }.sorted {
            let left = snapshot.windows[$0.windowId]?.sessionId ?? ""
            let right = snapshot.windows[$1.windowId]?.sessionId ?? ""
            return left == right ? $0.index < $1.index : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
    private func workspaceID(of pane: PaneInfo) -> String? { snapshot.windows[pane.windowId]?.sessionId }
    private func state(in session: SessionInfo) -> String? {
        let states = agents.filter { workspaceID(of: $0) == session.id }.compactMap { hooks[$0.id]?.state }
        return ["attention", "working", "done"].first { states.contains($0) }
    }
    private func dot(_ state: String?) -> some View {
        let active = state == "working" || state == "attention" || state == "done"
        let color: Color = state == "working" ? Color(red: 0.93, green: 0.49, blue: 0.65)
            : state == "attention" ? Color(red: 0.96, green: 0.85, blue: 0.56)
            : Color(red: 0.56, green: 0.75, blue: 0.50)
        return Circle().fill(active ? color : .clear)
            .overlay { Circle().stroke(color, lineWidth: 0.7) }
            .frame(width: 6, height: 6).accessibilityHidden(true)
    }
    private func selectedLine(_ title: String, state: String?, selected: Bool) -> some View {
        HStack(spacing: 6) {
            dot(state)
            Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? TerminalChrome.foreground : foreground)
        .padding(.horizontal, 6).frame(minHeight: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? selection : .clear)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack { Text("spaces"); Spacer() }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(muted).padding(.horizontal, 6).padding(.vertical, 5)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(sessions) { session in
                                Button { selectSession(session.id) } label: {
                                    selectedLine(session.name, state: state(in: session), selected: snapshot.activeSessionId == session.id)
                                }.buttonStyle(.plain).accessibilityIdentifier("workspace-\(session.id)")
                            }
                        }.padding(.vertical, 2)
                    }
                    HStack {
                        Button("new", action: create).accessibilityLabel("新建工作区")
                        Spacer()
                        Button("menu", action: manage).accessibilityLabel("工作区管理")
                    }.buttonStyle(.plain).foregroundStyle(muted)
                        .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 8)
                }.frame(height: geometry.size.height * 0.46)
                Rectangle().fill(muted.opacity(0.18)).frame(height: 1).padding(.horizontal, 6)
                HStack { Text("agents"); Spacer(); Text("grouped") }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted).padding(.horizontal, 6).padding(.vertical, 7)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(agents) { pane in
                            let hook = hooks[pane.id]
                            let workspace = workspaceID(of: pane)
                            let name = workspace.flatMap { snapshot.sessions[$0]?.name } ?? pane.displayCommand
                            let siblings = agents.filter { workspaceID(of: $0) == workspace }
                            let ordinal = (siblings.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1
                            Button { selectPane(pane.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    selectedLine(name + (siblings.count > 1 ? " · \(ordinal)" : ""),
                                        state: hook?.state, selected: snapshot.activePaneId == pane.id)
                                    Text(hook?.agent ?? pane.displayCommand)
                                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                                        .lineLimit(1).padding(.leading, 18).padding(.trailing, 6)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("agent-\(pane.id)")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(action: collapse) { Image(systemName: "chevron.left.2").frame(width: 30, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel("收起工作区侧栏")
                        .accessibilityIdentifier("conversation-sidebar-collapse")
                }
            }
        }.font(.system(size: 13, design: .monospaced)).foregroundStyle(foreground)
            .background(TerminalChrome.background)
            .overlay(alignment: .trailing) { Rectangle().fill(muted.opacity(0.18)).frame(width: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation-workspaces")
    }
}
