import Foundation
import UserNotifications

/// Live Activities are the only task presentation. Keep legacy notification taps
/// routable during upgrades, but never present ordinary banners or sounds.
public enum AgentNotifications {
    /// `userInfo` keys identifying which pane a notification targets.
    public static let connectionKey = "connectionId"
    public static let paneKey = "paneId"

    /// Ordinary APNs alerts are disabled independently of old persisted preferences.
    public static let ordinaryNotificationsEnabled = false

    public static func configure(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// Notification-center delegate. A tapped notification resolves its target pane
/// from `userInfo` and asks `AgentControlBridge` to open it. That is the only
/// interaction — the tapped-ACTION branch that used to sit here, turning Allow /
/// Deny / Reply into keystrokes, went with the buttons.
///
/// Deliberately the completion-HANDLER delegate variants, not the async ones.
/// The async variants read cleaner, but the ObjC bridge invokes their
/// auto-generated completion on the concurrency pool's thread — and
/// UNUserNotificationCenter's own completion for `didReceive` runs UIKit
/// state-restoration/snapshot work (`_updateStateRestorationArchive…`) that
/// NSAsserts the main thread. Tapping a notification while Hermit was
/// backgrounded crashed on exactly that assert (TestFlight 344, thread 17
/// SIGABRT). Here every completion is invoked from a `@MainActor` task, so
/// UIKit's continuation runs where it insists on running.
public final class AgentNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    /// (connectionId, paneId) out of a notification's userInfo, or nil for
    /// notifications that aren't ours.
    private func target(of info: [AnyHashable: Any]) -> (UUID, String)? {
        guard let cidString = info[AgentNotifications.connectionKey] as? String,
              let connectionId = UUID(uuidString: cidString),
              let paneId = info[AgentNotifications.paneKey] as? String
        else { return nil }
        return (connectionId, paneId)
    }

    /// A pairing self-test's nonce, when this notification is one — nil for
    /// everything else. Pure and static so a test can pin it: this recognition
    /// was DESTROYED once, silently, in an unrelated rewrite of the delegate,
    /// and from that day every "send a test notification" timed out with "the
    /// host sent one, but this screen never saw it arrive" — the push chain was
    /// perfect and the last inch was gone. Nothing failed loudly, because the
    /// closure it feeds is optional and nobody was left to call it.
    public static func selfTestNonce(in info: [AnyHashable: Any]) -> String? {
        guard info[PushRemoteNotification.agentKey] as? String
                == PushRemoteNotification.selfTestAgent else { return nil }
        return info[PushRemoteNotification.detailKey] as? String ?? ""
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        // A pairing self-test is plumbing, not news: hand its nonce to the
        // sheet that is waiting on it and show nothing.
        if let nonce = Self.selfTestNonce(in: notification.request.content.userInfo) {
            Task { @MainActor in
                AgentControlBridge.shared.pushSelfTest?(nonce)
                completionHandler([])
            }
            return
        }
        let content = notification.request.content
        Task { @MainActor in
            _ = await AgentControlBridge.shared.presentTaskNotification?(content)
            completionHandler([])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        // Everything needed is extracted HERE, on the delegate's queue —
        // UNNotificationResponse isn't Sendable and shouldn't cross into the
        // main-actor task.
        let target = target(of: response.notification.request.content.userInfo)
        let actionIdentifier = response.actionIdentifier

        Task { @MainActor in
            defer { completionHandler() }
            guard let (connectionId, paneId) = target else { return }
            Log.island.info("land: notification tap conn=\(connectionId.uuidString, privacy: .public) pane=\(paneId, privacy: .public) action=\(actionIdentifier, privacy: .public)")
            // A body tap, or the system's "open". Nothing else can arrive: with
            // no categories registered there are no action identifiers to send.
            guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            AgentControlBridge.shared.open(connectionId: connectionId, paneId: paneId)
        }
    }
}
