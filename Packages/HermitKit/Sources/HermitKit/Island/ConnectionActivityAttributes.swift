import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// A bounded snapshot shared by the app and its widget. Host/workspace aliases
/// follow the visibility setting; programs come from a fixed allowlist. No
/// terminal output, addresses, usernames, arguments or task titles are included.
public struct ConnectionActivityAttributes: ActivityAttributes {
    public enum ConnectionState: String, Codable, Hashable, Sendable {
        case connecting, connected, reconnecting, offline, background

        public var label: String {
            switch self {
            case .connecting: return String(localized: "Connecting")
            case .connected: return String(localized: "Connected")
            case .reconnecting: return String(localized: "Reconnecting")
            case .offline: return String(localized: "Disconnected")
            case .background: return String(localized: "Open Hermit to refresh")
            }
        }

        public var symbol: String {
            switch self {
            case .connecting: return "ellipsis.circle"
            case .connected: return "network"
            case .reconnecting: return "arrow.triangle.2.circlepath"
            case .offline: return "network.slash"
            case .background: return "pause.circle"
            }
        }
    }

    public enum TaskState: String, Codable, Hashable, Sendable {
        case working, attention, done

        public var label: String {
            switch self {
            case .working: return String(localized: "Task in progress")
            case .attention: return String(localized: "Waiting for you")
            case .done: return String(localized: "Task completed")
            }
        }

        public var symbol: String {
            switch self {
            case .working: return "gearshape.2"
            case .attention: return "exclamationmark.bubble"
            case .done: return "checkmark.circle"
            }
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var connectionCount: Int
        public var headlineName: String?
        public var connectionState: ConnectionState
        public var workingCount: Int
        public var attentionCount: Int
        public var doneCount: Int
        public var deepLink: String
        public var updatedAt: Date
        // Optional additions preserve decoding of an activity already running
        // when this app/widget is upgraded.
        public var isBackground: Bool?
        public var transportName: String?
        public var workspaceName: String?
        public var programName: String?
        public var taskState: TaskState?
        /// Last successful remote context read. Activity delivery/renewal must
        /// never make a cached remote task look newly verified.
        public var observedAt: Date?

        public var statusDate: Date { observedAt ?? updatedAt }

        public init(connectionCount: Int, headlineName: String?, connectionState: ConnectionState,
                    workingCount: Int, attentionCount: Int, doneCount: Int,
                    deepLink: String, updatedAt: Date, isBackground: Bool? = nil,
                    transportName: String? = nil, workspaceName: String? = nil,
                    programName: String? = nil, taskState: TaskState? = nil,
                    observedAt: Date? = nil) {
            self.connectionCount = connectionCount
            self.headlineName = headlineName
            self.connectionState = connectionState
            self.workingCount = workingCount
            self.attentionCount = attentionCount
            self.doneCount = doneCount
            self.deepLink = deepLink
            self.updatedAt = updatedAt
            self.isBackground = isBackground
            self.transportName = transportName
            self.workspaceName = workspaceName
            self.programName = programName
            self.taskState = taskState
            self.observedAt = observedAt
        }
    }

    public var schemaVersion: Int
    public init(schemaVersion: Int = 1) { self.schemaVersion = schemaVersion }
}
#endif
