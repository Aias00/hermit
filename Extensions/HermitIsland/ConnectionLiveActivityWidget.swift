import ActivityKit
import MoshpitKit
import SwiftUI
import WidgetKit

private struct ActivityPresentation {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    var now = Date()
    var isExpired: Bool { state.isHeadlineStale(at: now, systemIsStale: isStale) }
    var historical: Bool { isExpired || state.isBackground == true || state.connectionState == .background }
    var task: ConnectionActivityAttributes.TaskState? {
        state.connectionState == .connected ? state.taskState : nil
    }
    var shellFinished: Bool { task == .done && state.programName == "Shell" }
    var commandFailed: Bool { shellFinished && state.commandExitCode.map { $0 != 0 } == true }
    var label: String {
        if shellFinished {
            if let code = state.commandExitCode {
                return String(localized: "Command exited with status \(code)")
            }
            return String(localized: "Command finished")
        }
        return task?.label ?? state.connectionState.label
    }
    var symbol: String {
        if commandFailed { return "xmark.circle" }
        if shellFinished && state.commandExitCode == nil { return "terminal" }
        return task?.symbol ?? state.connectionState.symbol
    }
    var color: Color {
        // Completion remains the recorded outcome when observations go stale.
        // Keep the timestamp/history label instead of erasing that distinction.
        if task == .done, !commandFailed, !shellFinished || state.commandExitCode != nil { return .green }
        if isExpired || task == .idle { return .secondary }
        if commandFailed || task == .attention || state.connectionState == .reconnecting { return .orange }
        if shellFinished && state.commandExitCode == nil { return .cyan }
        if task == .done { return .green }
        return .cyan
    }
}

struct ConnectionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConnectionActivityAttributes.self) { context in
            ConnectionActivityLockScreen(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.state.deepLink))
        } dynamicIsland: { context in
            let presentation = ActivityPresentation(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.headlineName ?? "Hermit", systemImage: "terminal")
                        .font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.connectionCount)").monospacedDigit()
                        .accessibilityLabel(Text("\(context.state.connectionCount) connections"))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ConnectionActivityDetails(state: context.state, isStale: context.isStale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("connection-live-activity-expanded")
                }
            } compactLeading: {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.color)
                    .accessibilityLabel(presentation.label)
            } compactTrailing: {
                if context.state.attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(presentation.isExpired ? Color.secondary : Color.orange)
                        .accessibilityLabel(Text("Needs attention"))
                } else {
                    Text("\(context.state.connectionCount)").monospacedDigit()
                }
            } minimal: {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.color)
                    .accessibilityLabel(presentation.label)
            }
            .widgetURL(URL(string: context.state.deepLink))
            .keylineTint(.cyan)
        }
    }
}

struct ConnectionActivityLockScreen: View {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    var now = Date()
    @Environment(\.dynamicTypeSize) private var typeSize

    private var rows: [ConnectionActivityAttributes.TaskSummary] {
        // Leave room for larger accessibility text instead of silently clipping
        // the system's 160pt card. The footer counts every omitted task.
        Array((state.tasks ?? []).prefix(typeSize > .xxLarge ? 1 : (typeSize > .large ? 2 : 3)))
    }
    private var remaining: Int { max(0, (state.totalTaskCount ?? state.tasks?.count ?? 0) - rows.count) }
    private var historical: Bool {
        state.isHeadlineStale(at: now, systemIsStale: isStale)
            || state.isBackground == true || state.connectionState == .background
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.headlineName ?? "Hermit")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text("Updated at")
                    Text(state.statusDate, format: .dateTime.hour().minute()).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
            if rows.isEmpty {
                ConnectionActivityDetails(state: state, isStale: isStale, showTimestamp: false, now: now)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { task in
                        if let url = URL(string: task.deepLink) {
                            Link(destination: url) {
                                ConnectionActivityTaskRow(task: task, isStale: task.isStale(
                                    at: now, maximumAge: state.freshnessInterval, fallback: isStale),
                                    showsStaleLabel: !historical)
                            }
                            .accessibilityIdentifier("connection-live-activity-task-\(task.id)")
                        }
                    }
                }
                HStack(spacing: 8) {
                    if remaining > 0 {
                        Text("+\(remaining)").monospacedDigit()
                            .accessibilityLabel(Text("\(remaining) more tasks"))
                    }
                    Spacer(minLength: 0)
                    if historical { Text("Last known status") }
                    else if state.connectionCount > 1 { Text("\(state.connectionCount) connections") }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-live-activity-card")
    }
}

struct ConnectionActivityTaskStatus: View {
    let state: ConnectionActivityAttributes.TaskState
    let isStale: Bool

    var color: Color {
        if state == .done { return .green }
        if isStale { return .secondary }
        switch state {
        case .done: return .green
        case .attention, .working: return .orange
        case .idle: return .secondary
        }
    }
    var body: some View {
        Group {
            if state == .working {
                Circle().strokeBorder(lineWidth: 1.8).frame(width: 16, height: 16)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 16, weight: state == .done ? .semibold : .medium))
            }
        }
        .foregroundStyle(color).frame(width: 18)
        .accessibilityLabel(state.label)
    }
}

private struct ConnectionActivityTaskRow: View {
    let task: ConnectionActivityAttributes.TaskSummary
    let isStale: Bool
    let showsStaleLabel: Bool

    private var subtitle: String {
        let detail = task.state == .idle ? task.state.label : task.detail ?? task.state.label
        // The card footer already marks a historical snapshot. Keep individual
        // stale labels only when they distinguish an old row in a current card.
        return [isStale && showsStaleLabel ? String(localized: "Last known status") : nil, detail,
                task.programName, task.hostName].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ConnectionActivityTaskStatus(state: task.state, isStale: isStale)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: task.workspaceName ?? task.programName ?? String(localized: "Task"))
                    .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.workspaceName, task.programName, task.state.label,
                             task.state == .idle ? nil : task.detail, task.hostName,
                             isStale ? String(localized: "Last known status") : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

private struct ConnectionActivityDetails: View {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    var showTimestamp = true
    var now = Date()
    private var presentation: ActivityPresentation { .init(state: state, isStale: isStale, now: now) }

    private var context: String {
        // Plain SSH already uses the transport as its title.
        let transport = state.programName == nil ? nil : state.transportName
        return [transport, state.workspaceName].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: state.programName ?? state.transportName ?? "Hermit")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !context.isEmpty {
                        Text(verbatim: context)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 6) {
                    Label(presentation.label, systemImage: presentation.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(presentation.color)
                        .lineLimit(3).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(presentation.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    taskCounts
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if showTimestamp {
                HStack(spacing: 8) {
                    Text(presentation.historical ? String(localized: "Last known status") : String(localized: "State as of"))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(state.statusDate, format: .dateTime.hour().minute())
                        .monospacedDigit().fixedSize()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskCounts: some View {
        HStack(spacing: 10) {
            if state.attentionCount > 0 {
                Label("\(state.attentionCount)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(presentation.historical ? Color.secondary : Color.orange)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(state.attentionCount) need attention"))
            }
            if state.workingCount > 0 {
                Label("\(state.workingCount)", systemImage: "gearshape.2")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(state.workingCount) working"))
            }
            if state.doneCount > 0 && state.attentionCount == 0 && state.workingCount == 0 {
                Label("\(state.doneCount)", systemImage: "checkmark.circle")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(state.doneCount) completed"))
            }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }
}
