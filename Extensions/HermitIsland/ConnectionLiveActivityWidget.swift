import ActivityKit
import MoshpitKit
import SwiftUI
import WidgetKit

private struct ActivityPresentation {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    var historical: Bool { isStale || state.isBackground == true || state.connectionState == .background }
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
        if historical { return .secondary }
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
                        .foregroundStyle(presentation.historical ? Color.secondary : Color.orange)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(state.headlineName ?? "Hermit").truncationMode(.middle)
                } icon: {
                    Image(systemName: "terminal").foregroundStyle(.cyan)
                }
                .font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(state.connectionCount) connections")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: Capsule())
                    .fixedSize()
            }
            ConnectionActivityDetails(state: state, isStale: isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-live-activity-card")
    }
}

private struct ConnectionActivityDetails: View {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    private var presentation: ActivityPresentation { .init(state: state, isStale: isStale) }

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
            HStack(spacing: 8) {
                Text(presentation.historical ? String(localized: "Last known status") : String(localized: "State as of"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(state.statusDate, format: .dateTime.hour().minute())
                    .monospacedDigit().fixedSize()
            }
            .font(.caption2).foregroundStyle(.secondary)
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
