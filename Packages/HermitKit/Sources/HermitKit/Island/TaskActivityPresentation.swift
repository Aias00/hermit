import Foundation
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit

/// Pure state reconciliation for both the running app and the push extension.
public enum TaskActivityPresentation {
    public struct Update {
        public let content: ConnectionActivityAttributes.ContentState
        public let isRepeat: Bool
    }

    public static func applying(_ event: AgentTaskEvent,
                                to original: ConnectionActivityAttributes.ContentState) -> Update? {
        guard var rows = original.tasks,
              let index = rows.firstIndex(where: { $0.id == event.taskID }) else { return nil }
        let previous = rows[index]
        if previous.eventID == event.id || previous.eventAt.map({ $0 > event.occurredAt }) == true {
            return Update(content: original, isRepeat: true)
        }
        let next = ConnectionActivityAttributes.TaskState(rawValue: event.state.rawValue)!
        // A remote read newer than this event already reports the current turn.
        // Clock skew gets five seconds of headroom; never overwrite a new turn.
        if previous.state != next,
           previous.observedAt.map({ $0 > event.occurredAt.addingTimeInterval(5) }) == true {
            return nil
        }
        var result = original
        rows[index].state = next
        rows[index].observedAt = event.receivedAt
        rows[index].eventID = event.id
        rows[index].eventAt = event.occurredAt
        rows[index].eventPresentation = nil
        rows.sort { $0.state.priority < $1.state.priority }
        result.tasks = rows
        result.updatedAt = event.receivedAt
        if previous.state != next {
            switch previous.state {
            case .working: result.workingCount = max(0, result.workingCount - 1)
            case .attention: result.attentionCount = max(0, result.attentionCount - 1)
            case .done: result.doneCount = max(0, result.doneCount - 1)
            case .idle: break
            }
            if next == .attention { result.attentionCount += 1 }
            else { result.doneCount += 1 }
        }
        let headline = AgentDeepLink.parse(result.deepLink)
        if next == .attention {
            // The card's body tap must open the prompt that just became urgent,
            // even when a different pane was the previous headline.
            if headline?.connectionId != event.connectionID {
                result.headlineName = previous.hostName
                result.transportName = nil
                result.connectionState = .background
            }
            result.deepLink = previous.deepLink
            result.workspaceName = previous.workspaceName
            result.programName = previous.programName
            result.taskState = next
            result.observedAt = event.receivedAt
        } else if headline?.connectionId == event.connectionID, headline?.paneId == event.paneID {
            result.taskState = next
            result.observedAt = event.receivedAt
        }
        return Update(content: result, isRepeat: false)
    }

    /// A timer may have captured old hooks immediately before an event. Keep
    /// the event until a subsequent real remote observation supersedes it.
    public static func reconciling(_ snapshot: ConnectionActivityAttributes.ContentState,
                                   with delivered: ConnectionActivityAttributes.ContentState)
        -> ConnectionActivityAttributes.ContentState {
        var result = snapshot
        for row in delivered.tasks ?? [] {
            guard let stamp = row.eventAt, row.eventID != nil, let observed = row.observedAt,
                  let index = result.tasks?.firstIndex(where: { $0.id == row.id }),
                  let incoming = result.tasks?[index],
                  let target = AgentDeepLink.parse(row.deepLink), let pane = target.paneId,
                  let state = AgentTaskEvent.State(rawValue: row.state.rawValue) else { continue }
            if incoming.state == row.state {
                // Polling the same finished episode renews its observation,
                // not its licence to alert again when a push copy arrives.
                result.tasks?[index].eventID = row.eventID
                result.tasks?[index].eventAt = row.eventAt
                result.tasks?[index].eventPresentation = row.eventPresentation
                continue
            }
            guard incoming.observedAt.map({ $0 <= observed }) ?? true else { continue }
            let event = AgentTaskEvent(connectionID: target.connectionId, paneID: pane,
                                      state: state, occurredAt: stamp, receivedAt: observed)
            if let update = applying(event, to: result) {
                result = update.content
                if let restored = result.tasks?.firstIndex(where: { $0.id == row.id }) {
                    result.tasks?[restored].eventPresentation = row.eventPresentation
                }
            }
        }
        result.updatedAt = max(snapshot.updatedAt, result.updatedAt)
        return result
    }
}

/// One queue per process prevents polling updates racing event alerts. The
/// extension only updates an existing activity; it never requests a new one.
@MainActor
public enum TaskActivityDelivery {
    private static var tail: Task<Void, Never>?

    public static func update(_ activity: Activity<ConnectionActivityAttributes>,
                              snapshot: ConnectionActivityAttributes.ContentState) async {
        let previous = tail
        let work = Task {
            await previous?.value
            guard activity.activityState == .active || activity.activityState == .stale else { return }
            let reconciled = TaskActivityPresentation.reconciling(snapshot, with: activity.content.state)
            await activity.update(ActivityContent(state: reconciled, staleDate: reconciled.staleDate))
        }
        tail = work
        await work.value
    }

    public static func present(_ event: AgentTaskEvent, notification: UNNotificationContent?,
                               alert: Bool, externalNotification: Bool = false) async -> Bool {
        let previous = tail
        let work = Task { () -> Bool in
            await previous?.value
            for activity in Activity<ConnectionActivityAttributes>.activities {
                guard activity.activityState == .active || activity.activityState == .stale,
                      let update = TaskActivityPresentation.applying(event, to: activity.content.state) else { continue }
                // An NSE updates silently before the ordinary push is handed
                // to willPresent. If the app is foreground, replace that still
                // pending alert with an ActivityKit alert instead of losing it.
                let receipt = update.content.tasks?.first(where: { $0.id == event.taskID })
                let replacesPendingPush = notification?.userInfo[PushRemoteNotification.envelopeKey] != nil
                    && receipt?.eventID == event.id && receipt?.eventPresentation == "notification"
                if update.isRepeat && !replacesPendingPush { return true }
                var state = update.content
                if let index = state.tasks?.firstIndex(where: { $0.id == event.taskID }) {
                    state.tasks?[index].eventPresentation = externalNotification ? "notification" : (alert ? "activity" : "observed")
                }
                let configuration: AlertConfiguration?
                if alert, let notification, notification.interruptionLevel != .passive {
                    configuration = AlertConfiguration(title: "\(notification.title)", body: "\(notification.body)",
                        sound: notification.sound == nil ? .named("hermit-silent.wav") : .default)
                } else { configuration = nil }
                await activity.update(ActivityContent(state: state, staleDate: state.staleDate),
                                      alertConfiguration: configuration)
                return activity.activityState == .active || activity.activityState == .stale
            }
            return false
        }
        tail = Task { _ = await work.value }
        return await work.value
    }
}
#endif
