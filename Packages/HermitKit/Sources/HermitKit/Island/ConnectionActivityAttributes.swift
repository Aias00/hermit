import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// A bounded snapshot shared by the app and its widget. Host/workspace aliases
/// follow the visibility setting; programs come from a fixed allowlist. Only
/// explicit task titles may appear, gated by the lock-screen detail preference.
/// Terminal output, connection addresses and command arguments are not sampled.
public struct ConnectionActivityAttributes: ActivityAttributes {
    /// Two 45s safety-net polls plus network and local sampling headroom.
    public static let foregroundFreshnessInterval: TimeInterval = 120
    public static let backgroundFreshnessInterval: TimeInterval = 45

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
        case working, attention, done, idle

        public var label: String {
            switch self {
            case .working: return String(localized: "Task in progress")
            case .attention: return String(localized: "Waiting for you")
            case .done: return String(localized: "Task completed")
            case .idle: return String(localized: "Idle")
            }
        }

        public var symbol: String {
            switch self {
            case .working: return "circle"
            case .attention: return "exclamationmark.circle"
            case .done: return "checkmark.circle"
            case .idle: return "pause.circle"
            }
        }

        public var priority: Int {
            switch self {
            case .attention: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
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
        /// Numeric result of an explicitly finished plain SSH shell command.
        /// Command text, arguments and paths never enter the activity payload.
        public var commandExitCode: Int?
        /// At most three rows; nil decodes activities created by older builds.
        public var tasks: [TaskSummary]?
        public var totalTaskCount: Int?

        public var statusDate: Date { observedAt ?? updatedAt }

        public var freshnessInterval: TimeInterval {
            isBackground == true || connectionState == .background
                ? ConnectionActivityAttributes.backgroundFreshnessInterval
                : ConnectionActivityAttributes.foregroundFreshnessInterval
        }

        /// The header describes its own host, never an unrelated row's poll.
        public func isHeadlineStale(at date: Date, systemIsStale: Bool) -> Bool {
            guard observedAt != nil else { return systemIsStale }
            return date >= statusDate.addingTimeInterval(freshnessInterval)
        }

        /// System-level staleness represents the whole snapshot being old.
        /// Each row also checks its own observation date whenever iOS renders.
        public var staleDate: Date {
            let newest = ([statusDate] + (tasks ?? []).compactMap(\.observedAt)).max() ?? statusDate
            return newest.addingTimeInterval(freshnessInterval)
        }

        public init(connectionCount: Int, headlineName: String?, connectionState: ConnectionState,
                    workingCount: Int, attentionCount: Int, doneCount: Int,
                    deepLink: String, updatedAt: Date, isBackground: Bool? = nil,
                    transportName: String? = nil, workspaceName: String? = nil,
                    programName: String? = nil, taskState: TaskState? = nil,
                    observedAt: Date? = nil, commandExitCode: Int? = nil,
                    tasks: [TaskSummary]? = nil, totalTaskCount: Int? = nil) {
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
            self.commandExitCode = commandExitCode
            self.tasks = tasks
            self.totalTaskCount = totalTaskCount
        }
    }

    public struct TaskSummary: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var workspaceName: String?
        public var hostName: String?
        public var programName: String?
        public var detail: String?
        public var state: TaskState
        public var deepLink: String
        public var observedAt: Date?

        public func isStale(at date: Date, maximumAge: TimeInterval, fallback: Bool) -> Bool {
            guard let observedAt else { return fallback }
            return date >= observedAt.addingTimeInterval(maximumAge)
        }

        public init(id: String, workspaceName: String? = nil, hostName: String? = nil,
                    programName: String? = nil, detail: String? = nil, state: TaskState,
                    deepLink: String, observedAt: Date? = nil) {
            self.id = id
            self.workspaceName = workspaceName
            self.hostName = hostName
            self.programName = programName
            self.detail = detail
            self.state = state
            self.deepLink = deepLink
            self.observedAt = observedAt
        }
    }

    public var schemaVersion: Int
    public init(schemaVersion: Int = 1) { self.schemaVersion = schemaVersion }
}
#endif
