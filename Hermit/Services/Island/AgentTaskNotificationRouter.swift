import Foundation
import MoshpitKit
import UIKit
import UserNotifications

/// Local events and legacy foreground pushes only update an existing activity.
/// Missing, dismissed or unresolved cards never produce an ordinary notification.
@MainActor
final class AgentTaskNotificationRouter {
    private let settings: AppSettings
    private let isVisible: @MainActor (UUID, String) -> Bool
    private let presentActivity: @MainActor (AgentTaskEvent, UNNotificationContent, Bool) async -> Bool
    private let remove: ([String]) -> Void
    private var tail: Task<Void, Never>?

    init(settings: AppSettings,
         isVisible: @escaping @MainActor (UUID, String) -> Bool = { connection, pane in
             UIApplication.shared.applicationState == .active
                && AgentControlBridge.shared.isPaneVisible?(connection, pane) == true
         },
         presentActivity: @escaping @MainActor (AgentTaskEvent, UNNotificationContent, Bool) async -> Bool = {
             await TaskActivityDelivery.present($0, notification: $1, alert: $2)
         },
         remove: @escaping ([String]) -> Void = { ids in
             UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
             UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
         }) {
        self.settings = settings
        self.isVisible = isVisible
        self.presentActivity = presentActivity
        self.remove = remove
    }

    func submit(_ request: UNNotificationRequest) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            _ = await self.consume(request.content)
        }
    }

    /// true only when the pane is visible or the matching activity was updated.
    func consume(_ content: UNNotificationContent) async -> Bool {
        guard let event = AgentTaskEvent(userInfo: content.userInfo) else { return false }
        let visible = isVisible(event.connectionID, event.paneID)
        let covered = settings.liveActivityEnabled
            ? await presentActivity(event, content, false) : false
        // Withdraw legacy task notices regardless of whether a card is available.
        var ids = ["moshpit.done.\(event.connectionID.uuidString).\(event.paneID)"]
        if PushStanding.standing(conn: event.connectionID.uuidString).allSatisfy({ $0.pane == event.paneID }) {
            ids.append("moshpit.attention.\(event.connectionID.uuidString)")
        }
        remove(ids)
        if visible || covered {
            Log.island.info("task delivery: state=\(event.state.rawValue, privacy: .public) presentation=\(visible ? "visible-pane" : "activity", privacy: .public)")
            return true
        }
        Log.island.info("task delivery: no activity available — no notification")
        return false
    }

    func waitForPendingDelivery() async { await tail?.value }
}
