import Foundation
import MoshpitKit
import UIKit
import UserNotifications

/// Local events and foreground pushes make the same presentation decision.
/// A missing/dismissed/unrelated activity always falls back to a notification.
@MainActor
final class AgentTaskNotificationRouter {
    private let settings: AppSettings
    private let isVisible: @MainActor (UUID, String) -> Bool
    private let presentActivity: @MainActor (AgentTaskEvent, UNNotificationContent, Bool) async -> Bool
    private let deliver: (UNNotificationRequest) -> Void
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
         deliver: @escaping (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) },
         remove: @escaping ([String]) -> Void = { ids in
             UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
             UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
         }) {
        self.settings = settings
        self.isVisible = isVisible
        self.presentActivity = presentActivity
        self.deliver = deliver
        self.remove = remove
    }

    func submit(_ request: UNNotificationRequest) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self, self.settings.notificationsEnabled else { return }
            if await self.consume(request.content) { return }
            guard self.settings.notificationsEnabled,
                  let fallback = request.content.mutableCopy() as? UNMutableNotificationContent else { return }
            fallback.userInfo[AgentTaskEvent.fallbackKey] = true
            self.deliver(.init(identifier: request.identifier, content: fallback, trigger: request.trigger))
        }
    }

    /// true only when the pane is visible or the matching activity was updated.
    func consume(_ content: UNNotificationContent) async -> Bool {
        guard let event = AgentTaskEvent(userInfo: content.userInfo) else { return false }
        let visible = isVisible(event.connectionID, event.paneID)
        let covered = settings.liveActivityEnabled
            ? await presentActivity(event, content, !visible && settings.notificationsEnabled) : false
        if visible || covered {
            var ids = ["moshpit.done.\(event.connectionID.uuidString).\(event.paneID)"]
            if PushStanding.standing(conn: event.connectionID.uuidString).allSatisfy({ $0.pane == event.paneID }) {
                ids.append("moshpit.attention.\(event.connectionID.uuidString)")
            }
            remove(ids)
            return true
        }
        return false
    }

    func waitForPendingDelivery() async { await tail?.value }
}
