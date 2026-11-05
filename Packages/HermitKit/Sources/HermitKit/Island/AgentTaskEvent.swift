import Foundation
import CryptoKit

/// One explicit remote transition, shared by notification and activity delivery.
/// Observation time is separate from the host's episode timestamp: receiving a
/// delayed completion must not make unrelated task rows look newly verified.
public struct AgentTaskEvent: Equatable, Sendable {
    public enum State: String, Sendable { case attention, done }
    public let connectionID: UUID
    public let paneID: String
    public let state: State
    public let occurredAt: Date
    public let receivedAt: Date

    public var taskID: String { connectionID.uuidString + ":" + paneID }
    public var id: String {
        let key = taskID + ":" + state.rawValue + ":" + String(Int(occurredAt.timeIntervalSince1970))
        return SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public init(connectionID: UUID, paneID: String, state: State,
                occurredAt: Date, receivedAt: Date = Date()) {
        self.connectionID = connectionID
        self.paneID = paneID
        self.state = state
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
    }

    public static let timestampKey = "hermitTaskTimestamp"
    /// Local fallbacks have already attempted activity delivery. Their later
    /// willPresent callback must not attempt it again and swallow the fallback.
    public static let fallbackKey = "hermitNotificationFallback"

    public var userInfo: [AnyHashable: Any] {
        [AgentNotifications.connectionKey: connectionID.uuidString,
         AgentNotifications.paneKey: paneID,
         PushRemoteNotification.stateKey: state.rawValue,
         Self.timestampKey: occurredAt.timeIntervalSince1970]
    }

    public init?(userInfo: [AnyHashable: Any], now: Date = Date()) {
        guard let connection = userInfo[AgentNotifications.connectionKey] as? String,
              let connectionID = UUID(uuidString: connection),
              let pane = userInfo[AgentNotifications.paneKey] as? String, !pane.isEmpty,
              pane.utf8.count <= 256,
              let raw = userInfo[PushRemoteNotification.stateKey] as? String,
              let state = State(rawValue: raw),
              let seconds = userInfo[Self.timestampKey] as? Double, seconds.isFinite,
              seconds <= now.timeIntervalSince1970 + 60,
              now.timeIntervalSince1970 - seconds <= PushRemoteNotification.lifetime(forState: raw)
        else { return nil }
        self.init(connectionID: connectionID, paneID: pane, state: state,
                  occurredAt: Date(timeIntervalSince1970: seconds), receivedAt: now)
    }
}
