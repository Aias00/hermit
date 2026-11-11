import SwiftUI
import UIKit

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
    let inbox: AgentInbox
    let selectSession: (String) -> Void
    let selectPane: (String) -> Void
    let sendEscape: (String) -> Void
    let manage: () -> Void
    let create: () -> Void
    let collapse: () -> Void
    var menu: ((HerdrMenuResource, UIView, CGPoint) -> Bool)? = nil

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
    private var orderedAgents: [PaneInfo] {
        let ordered = agents
        return ordered.filter { inbox.isPinned($0.id) } + ordered.filter { !inbox.isPinned($0.id) }
    }
    private func workspaceID(of pane: PaneInfo) -> String? { snapshot.windows[pane.windowId]?.sessionId }
    private func isUnread(in session: SessionInfo) -> Bool {
        agents.contains { workspaceID(of: $0) == session.id && inbox.isUnread($0.id) }
    }
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
    private func selectedLine(_ title: String, state: String?, selected: Bool,
                              unread: Bool = false, pinned: Bool = false) -> some View {
        HStack(spacing: 6) {
            dot(state)
            Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(muted)
                    .accessibilityHidden(true)
            }
            if unread {
                Circle().fill(Color(red: 0.54, green: 0.71, blue: 0.97))
                    .frame(width: 6, height: 6).accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? TerminalChrome.foreground : foreground)
        .padding(.horizontal, 10).frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(TerminalChrome.selectedTab)
                    .frame(width: 3).padding(.vertical, 8)
            }
        }
    }
    private func sectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            Text(count, format: .number).monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(muted).padding(.horizontal, 10).padding(.vertical, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            // One scroll surface leaves the lists usable when the keyboard or
            // landscape orientation makes a fixed split too short for a row.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sectionHeader("Workspaces", count: sessions.count)
                    ForEach(sessions) { session in
                        ContextListButton(menu: menu.map { show in { source, point in show(.workspace(session.id), source, point) } },
                                          action: { selectSession(session.id) }) {
                            selectedLine(session.name, state: state(in: session), selected: snapshot.activeSessionId == session.id,
                                         unread: isUnread(in: session))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("workspace-\(session.id)")
                        .accessibilityAddTraits(snapshot.activeSessionId == session.id ? [.isSelected] : [])
                    }
                    if !agents.isEmpty {
                        Rectangle().fill(muted.opacity(0.18)).frame(height: 1)
                            .padding(.horizontal, 10).padding(.top, 8)
                        sectionHeader("Agents", count: agents.count)
                        ForEach(orderedAgents) { pane in
                            let hook = hooks[pane.id]
                            let workspace = workspaceID(of: pane)
                            let name = workspace.flatMap { snapshot.sessions[$0]?.name } ?? pane.displayCommand
                            let siblings = agents.filter { workspaceID(of: $0) == workspace }
                            let ordinal = (siblings.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1
                            AgentInboxRow(paneID: pane.id, inbox: inbox, muted: muted,
                                          menu: menu.map { show in { source, point in show(.pane(pane.id), source, point) } },
                                          select: { selectPane(pane.id) }, sendEscape: { sendEscape(pane.id) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    selectedLine(name + (siblings.count > 1 ? " · \(ordinal)" : ""),
                                        state: hook?.state, selected: snapshot.activePaneId == pane.id,
                                        unread: inbox.isUnread(pane.id), pinned: inbox.isPinned(pane.id))
                                    Text(hook?.agent ?? pane.displayCommand)
                                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                                        .lineLimit(1).padding(.leading, 22).padding(.trailing, 10).padding(.bottom, 8)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("agent-\(pane.id)")
                            .accessibilityAddTraits(snapshot.activePaneId == pane.id ? [.isSelected] : [])
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.never)
            .accessibilityIdentifier("conversation-workspace-list")
            Rectangle().fill(muted.opacity(0.18)).frame(height: 1)
            HStack(spacing: 0) {
                Button(action: create) {
                    Label("New workspace", systemImage: "plus").labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("conversation-workspace-create")
                Button(action: manage) {
                    Label("Manage workspaces", systemImage: "ellipsis").labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("conversation-workspace-manage")
                Button(action: collapse) {
                    Label("Collapse workspaces", systemImage: "chevron.left.2").labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("conversation-sidebar-collapse")
            }
            .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(foreground)
        }
        .font(.system(size: 14)).foregroundStyle(foreground)
        .background(TerminalChrome.background)
        .overlay(alignment: .trailing) { Rectangle().fill(muted.opacity(0.18)).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-workspaces")
    }
}

/// Each agent owns its swipe state so reordering pins keeps gestures with the pane.
private struct AgentInboxRow<Label: View>: View {
    let paneID: String
    let inbox: AgentInbox
    let muted: Color
    let menu: ((UIView, CGPoint) -> Bool)?
    let select: () -> Void
    let sendEscape: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var offset: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var crossedThreshold = false
    @GestureState private var isDragging = false

    private var inboxValue: Text {
        if inbox.isUnread(paneID), inbox.isPinned(paneID) { return Text("Unread, pinned") }
        if inbox.isUnread(paneID) { return Text("Unread") }
        if inbox.isPinned(paneID) { return Text("Pinned") }
        return Text(verbatim: "")
    }

    private func togglePin() {
        inbox.togglePin(paneID)
        inbox.markRead(paneID)
    }

    private func resetSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
        dragAxis = nil
        crossedThreshold = false
    }

    var body: some View {
        ZStack {
            HStack {
                if offset > 0 {
                    Image(systemName: inbox.isPinned(paneID) ? "pin.slash" : "pin.fill")
                        .font(.system(size: 16))
                }
                Spacer(minLength: 0)
                if offset < 0 {
                    Text("esc").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(muted.opacity(0.18), in: Capsule())
                }
            }
            .foregroundStyle(muted).padding(.horizontal, 14)
            .allowsHitTesting(false).accessibilityHidden(true)

            ContextListButton(menu: menu, action: select, label: label)
                .background(TerminalChrome.background)
                .offset(x: offset)
                .accessibilityValue(inboxValue)
                .accessibilityActions {
                    Button("Send Esc", action: sendEscape)
                    Button(action: togglePin) {
                        if inbox.isPinned(paneID) { Text("Unpin") }
                        else { Text("Pin") }
                    }
                    if inbox.isUnread(paneID) {
                        Button("Mark as Read") { inbox.markRead(paneID) }
                    }
                }
        }
        .clipped()
        .simultaneousGesture(DragGesture(minimumDistance: 16)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) <= 1.5 * abs(dy) {
                    dragAxis = .vertical
                    offset = 0
                    crossedThreshold = false
                } else if dragAxis == nil {
                    dragAxis = .horizontal
                }
                guard dragAxis == .horizontal else { return }
                offset = min(90, max(-90, dx))
                let crossed = abs(offset) > 56
                if crossed, !crossedThreshold {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                crossedThreshold = crossed
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dragAxis == .horizontal, abs(dx) > 1.5 * abs(dy), abs(dx) > 56 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if dx < 0 { sendEscape() }
                    else { togglePin() }
                }
                resetSwipe()
            })
        .onChange(of: isDragging) { _, dragging in
            // Gesture cancellation (including scrolling) need not call onEnded.
            if !dragging { resetSwipe() }
        }
    }
}
