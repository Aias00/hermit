import ActivityKit
import Foundation
import MoshpitKit
import UIKit

/// Immutable input to the activity. Only explicit agent stamps count as tasks;
/// output becoming quiet is not evidence that a task has completed.
struct ConnectionActivityEntry: Equatable {
    var id: UUID
    var name: String
    var state: ConnectionActivityAttributes.ConnectionState
    var working = 0
    var attention = 0
    var done = 0
    var paneID: String?
    var transportName: String?
    var workspaceName: String?
    var programName: String?
    var taskState: ConnectionActivityAttributes.TaskState?
    var observedAt: Date?
}

enum ConnectionActivitySnapshot {
    static func make(entries: [ConnectionActivityEntry], preferredID: UUID?,
                     foreground: Bool, showHostNames: Bool, now: Date)
        -> ConnectionActivityAttributes.ContentState? {
        guard !entries.isEmpty else { return nil }
        // A remote prompt takes precedence over the screen currently visible.
        let ordered = entries.sorted {
            let firstNeedsAttention = $0.state == .connected && $0.attention > 0
            let secondNeedsAttention = $1.state == .connected && $1.attention > 0
            if firstNeedsAttention != secondNeedsAttention { return firstNeedsAttention }
            if ($0.id == preferredID) != ($1.id == preferredID) { return $0.id == preferredID }
            return $0.id.uuidString < $1.id.uuidString
        }
        let headline = ordered[0]
        let live = entries.filter { $0.state == .connected }
        let paneID = headline.state == .connected ? headline.paneID : nil
        let link = paneID.map {
            AgentDeepLink.string(connectionId: headline.id, paneId: $0)
        } ?? "\(AgentDeepLink.scheme)://connection/\(headline.id.uuidString)"
        return .init(connectionCount: entries.count,
                     headlineName: showHostNames ? boundedAlias(headline.name) : nil,
                     connectionState: headline.state,
                     workingCount: live.reduce(0) { $0 + $1.working },
                     attentionCount: live.reduce(0) { $0 + $1.attention },
                     doneCount: live.reduce(0) { $0 + $1.done },
                     deepLink: link, updatedAt: now, isBackground: !foreground,
                     transportName: headline.transportName,
                     workspaceName: showHostNames ? boundedAlias(headline.workspaceName) : nil,
                     programName: headline.programName,
                     taskState: headline.state == .connected ? headline.taskState : nil,
                     observedAt: headline.state == .connected ? headline.observedAt : nil)
    }

    private static func boundedAlias(_ name: String?) -> String? {
        guard let name else { return nil }
        let singleLine = String(String.UnicodeScalarView(name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return singleLine.isEmpty ? nil : String(singleLine.prefix(80))
    }

    static func transportName(for connection: ServerConnection) -> String? {
        switch connection.transport {
        case .direct: return connection.connectionProtocol.label
        case .socks5: return "SOCKS5"
        case .cloudflareSSH: return "Cloudflare"
        case .tailscale: return "Tailscale"
        case .tailcat: return "Tailcat"
        case nil: return nil
        }
    }

    /// A shell behind an old hook means the recorded agent is gone. Never
    /// resurrect its old "needs you" or infer a successful completion.
    static func taskCounts(_ hooks: [String: AgentHook])
        -> (working: Int, attention: Int, done: Int, paneID: String?) {
        let valid = hooks.sorted { $0.key < $1.key }.filter {
            ConnectionActivityContext.reportedState($0.value) != nil
        }
        return (valid.filter { $0.value.state == "working" }.count,
                valid.filter { $0.value.state == "attention" }.count,
                valid.filter { $0.value.state == "done" }.count,
                valid.first { $0.value.state == "attention" }?.key
                    ?? valid.first { $0.value.state == "working" }?.key)
    }
}

@MainActor
protocol ConnectionActivityBackend: AnyObject {
    func update(_ state: ConnectionActivityAttributes.ContentState, canStart: Bool) async
    func end() async
}

/// Owns only the connection activity type, so old agent activities cannot be
/// accidentally adopted as connection activities during an app upgrade.
@MainActor
final class SystemConnectionActivityBackend: ConnectionActivityBackend {
    private var activity: Activity<ConnectionActivityAttributes>?
    private var dismissed = false
    private var lastErrorLogged = false

    func update(_ state: ConnectionActivityAttributes.ContentState, canStart: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await end()
            return
        }
        if let activity, activity.activityState == .dismissed {
            // Honor a swipe-away until all sessions end or the user toggles the
            // feature. Polling must not recreate a card every two seconds.
            self.activity = nil
            dismissed = true
        } else if activity?.activityState == .ended {
            activity = nil
        }
        guard !dismissed else { return }
        if activity == nil {
            let existing = Activity<ConnectionActivityAttributes>.activities
            activity = existing.first { $0.activityState == .active || $0.activityState == .stale }
            for extra in existing where extra.id != activity?.id {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        }
        let content = ActivityContent(state: state,
                                      staleDate: state.statusDate.addingTimeInterval(45))
        if let activity {
            await activity.update(content)
        } else if canStart && UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity.request(attributes: ConnectionActivityAttributes(),
                                                content: content, pushType: nil)
                lastErrorLogged = false
                Log.island.info("connection activity: started")
            } catch {
                // No addresses, host aliases, task text or OS error userInfo.
                if !lastErrorLogged {
                    let code = (error as NSError).code
                    Log.island.error("connection activity: request rejected by system code=\(code, privacy: .public)")
                    lastErrorLogged = true
                }
            }
        }
    }

    func end() async {
        for current in Activity<ConnectionActivityAttributes>.activities {
            await current.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        dismissed = false
        lastErrorLogged = false
    }
}

/// Foreground-only sampling; Live Activities do not extend SSH background
/// execution. The background snapshot and staleDate make that limit visible.
@MainActor
final class ConnectionLiveActivity {
    private let settings: AppSettings
    private let hub: SessionHub
    private let backend: any ConnectionActivityBackend
    private var timer: Timer?
    private var foreground = false
    private var lastHookPoll: Date = .distantPast
    private var lastSubmitted: ConnectionActivityAttributes.ContentState?
    private var desired: ConnectionActivityAttributes.ContentState?
    private var desiredCanStart = false
    private var revision = 0
    private var delivery: Task<Void, Never>?

    init(settings: AppSettings, hub: SessionHub,
         backend: (any ConnectionActivityBackend)? = nil) {
        self.settings = settings
        self.hub = hub
        self.backend = backend ?? SystemConnectionActivityBackend()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        timer?.invalidate()
        timer = nil
        refresh(force: true)
        if active {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh(force: Bool = false, now: Date = Date()) {
        let entries: [ConnectionActivityEntry]
        if settings.liveActivityEnabled {
            let shouldPoll = foreground && now.timeIntervalSince(lastHookPoll) >= 10
            if shouldPoll { lastHookPoll = now }
            entries = hub.sessions.values.map { session in
                let state: ConnectionActivityAttributes.ConnectionState
                switch session.viewModel.connState {
                case .live: state = .connected
                case .connecting: state = .connecting
                case .reconnecting: state = .reconnecting
                case .offline: state = .offline
                }
                let controller: (any MultiplexerControlling)?
                if let herdr = session.herdrControl { controller = herdr }
                else { controller = session.tmuxControl }
                if shouldPoll && state == .connected { controller?.pollAgentHooks() }
                let observedAt = controller?.agentHooksObservedAt
                let context = controller.flatMap {
                    guard observedAt != nil else { return nil as ConnectionActivityContext? }
                    return ConnectionActivityContext.make(snapshot: $0.snapshot, hooks: $0.agentHooks,
                                                          hooksLoaded: $0.agentHooksLoaded)
                } ?? ConnectionActivityContext()
                let hooks = controller.map { control in
                    control.agentHooksLoaded && observedAt != nil ? control.agentHooks.filter {
                        control.snapshot.panes[$0.key] != nil
                    } : [:]
                } ?? [:]
                let tasks = ConnectionActivitySnapshot.taskCounts(hooks)
                return ConnectionActivityEntry(id: session.connection.id,
                    name: session.connection.name, state: state,
                    working: state == .connected ? tasks.working : 0,
                    attention: state == .connected ? tasks.attention : 0,
                    done: state == .connected ? tasks.done : 0,
                    paneID: state == .connected ? context.paneID : nil,
                    transportName: ConnectionActivitySnapshot.transportName(for: session.connection),
                    workspaceName: context.workspaceName, programName: context.programName,
                    taskState: context.taskState.flatMap(ConnectionActivityAttributes.TaskState.init(rawValue:)),
                    observedAt: observedAt)
            }
        } else { entries = [] }
        let content = ConnectionActivitySnapshot.make(entries: entries,
            preferredID: hub.visibleSession?.connection.id, foreground: foreground,
            showHostNames: settings.liveActivityShowHostNames, now: now)
        submit(content, canStart: foreground, force: force)
    }

    /// Coalesce steady state (including its timestamps), but periodically renew
    /// staleDate. One delivery worker serializes update/end so an old update can
    /// never arrive after disabling the setting or disconnecting the last host.
    func submit(_ content: ConnectionActivityAttributes.ContentState?, canStart: Bool,
                force: Bool = false) {
        if !force, var comparison = content, let lastSubmitted {
            comparison.updatedAt = lastSubmitted.updatedAt
            if comparison == lastSubmitted,
               content!.updatedAt.timeIntervalSince(lastSubmitted.updatedAt) < 20 { return }
        } else if !force, content == nil, lastSubmitted == nil { return }
        lastSubmitted = content
        desired = content
        desiredCanStart = canStart
        revision += 1
        guard delivery == nil else { return }
        delivery = Task { [weak self] in
            guard let self else { return }
            while true {
                let current = self.revision
                if let state = self.desired {
                    await self.backend.update(state, canStart: self.desiredCanStart)
                } else { await self.backend.end() }
                if current == self.revision { break }
            }
            self.delivery = nil
        }
    }

    func waitForPendingDelivery() async { await delivery?.value }
}
