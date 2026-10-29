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
    var label: String { task?.label ?? state.connectionState.label }
    var symbol: String { task?.symbol ?? state.connectionState.symbol }
    var color: Color {
        if historical { return .secondary }
        if task == .attention || state.connectionState == .reconnecting { return .orange }
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
                    Label(context.state.headlineName ?? "Moshpit", systemImage: "terminal")
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
                Label(state.headlineName ?? "Moshpit", systemImage: "terminal")
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(state.connectionCount) connections")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ConnectionActivityDetails(state: state, isStale: isStale)
        }
        .foregroundStyle(.white)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-live-activity-card")
    }
}

private struct ConnectionActivityDetails: View {
    let state: ConnectionActivityAttributes.ContentState
    let isStale: Bool
    private var presentation: ActivityPresentation { .init(state: state, isStale: isStale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let program = state.programName {
                    Text(verbatim: program).fontWeight(.semibold)
                    Text("·").foregroundStyle(.secondary)
                }
                Label(presentation.label, systemImage: presentation.symbol)
                    .foregroundStyle(presentation.color)
            }
            .font(.subheadline).lineLimit(1).minimumScaleFactor(0.85)
            let context = [state.transportName, state.workspaceName].compactMap { $0 }.joined(separator: " · ")
            if !context.isEmpty {
                Text(verbatim: context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if state.attentionCount > 0 {
                    Label("\(state.attentionCount) need attention", systemImage: "exclamationmark.circle")
                        .foregroundStyle(presentation.historical ? Color.secondary : Color.orange)
                }
                if state.workingCount > 0 {
                    Label("\(state.workingCount) working", systemImage: "gearshape.2")
                }
                if state.doneCount > 0 && state.attentionCount == 0 && state.workingCount == 0 {
                    Label("\(state.doneCount) completed", systemImage: "checkmark.circle")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Text(presentation.historical ? String(localized: "Last known status") : String(localized: "State as of"))
                Text(state.statusDate, format: .dateTime.hour().minute())
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
