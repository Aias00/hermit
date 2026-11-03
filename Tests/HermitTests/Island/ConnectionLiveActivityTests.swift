import Foundation
import MoshpitKit
import SwiftUI
import Testing
@testable import Moshpit

@Suite("Connection Live Activity")
@MainActor
struct ConnectionLiveActivityTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func content(state: ConnectionActivityAttributes.ConnectionState = .connected,
                         at: Date? = nil) -> ConnectionActivityAttributes.ContentState {
        .init(connectionCount: 1, headlineName: nil, connectionState: state,
              workingCount: 0, attentionCount: 0, doneCount: 0,
              deepLink: "moshpit://connection/00000000-0000-0000-0000-000000000001",
              updatedAt: at ?? now)
    }

    @Test("no sessions means no activity")
    func noSessions() {
        #expect(ConnectionActivitySnapshot.make(entries: [], preferredID: nil,
            foreground: true, showHostNames: false, now: now) == nil)
    }

    @Test("background marks the snapshot paused and preserves last reported tasks")
    func backgroundPreservesReportedState() throws {
        let entry = ConnectionActivityEntry(id: UUID(), name: "private-host", state: .connected,
                                            working: 2, attention: 1, done: 3,
                                            transportName: "Tailscale", workspaceName: "private-workspace",
                                            programName: "Codex", taskState: .attention)
        let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: false, showHostNames: false, now: now))
        #expect(value.connectionState == .connected)
        #expect(value.isBackground == true)
        #expect(value.programName == "Codex" && value.taskState == .attention)
        #expect(value.transportName == "Tailscale" && value.workspaceName == nil)
        #expect(value.workingCount == 2 && value.attentionCount == 1 && value.doneCount == 3)
        #expect(value.headlineName == nil)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!encoded.contains("private-host"))
        #expect(!encoded.contains("private-workspace"))
    }

    @Test("a plain SSH activity tap is accepted by the app router without a pane")
    func plainConnectionDeepLink() throws {
        let entry = ConnectionActivityEntry(id: UUID(), name: "", state: .connected)
        let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now))
        #expect(value.headlineName == nil)
        #expect(value.deepLink.hasPrefix("hermit://connection/"))
        let router = DeepLinkRouter()
        router.handle(try #require(URL(string: value.deepLink)))
        #expect(router.paneRequest?.connectionId == entry.id)
        #expect(router.paneRequest?.paneId == nil)
    }

    @Test("a waiting task takes priority and deep-links to the exact pane")
    func attentionWins() throws {
        let current = ConnectionActivityEntry(id: UUID(), name: "current", state: .connected)
        let waiting = ConnectionActivityEntry(id: UUID(), name: "waiting", state: .connected,
                                              attention: 1, paneID: "%12")
        let value = try #require(ConnectionActivitySnapshot.make(entries: [current, waiting],
            preferredID: current.id, foreground: true, showHostNames: true, now: now))
        #expect(value.headlineName == "waiting")
        let target = try #require(AgentDeepLink.parse(value.deepLink))
        #expect(target.connectionId == waiting.id)
        #expect(target.paneId == "%12")
    }

    @Test("disconnected hosts cannot contribute cached task counts")
    func offlineCountsAreIgnored() throws {
        let entry = ConnectionActivityEntry(id: UUID(), name: "host", state: .offline,
                                            working: 100, attention: 50, done: 10)
        let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: false, now: now))
        #expect(value.connectionState == .offline)
        #expect(value.workingCount == 0 && value.attentionCount == 0 && value.doneCount == 0)
    }

    @Test("task stamps from a returned shell and self-test do not report attention")
    func explicitTaskStatesOnly() {
        let hooks: [String: AgentHook] = [
            "%1": .init(state: "attention", agent: "codex", command: "zsh"),
            "%2": .init(state: "attention", agent: PushRemoteNotification.selfTestAgent),
            "%3": .init(state: "working", agent: "codex"),
            "%4": .init(state: "unknown", agent: "other"),
            "%5": .init(state: "done", agent: "claude"),
        ]
        let counts = ConnectionActivitySnapshot.taskCounts(hooks)
        #expect(counts.attention == 0)
        #expect(counts.working == 1 && counts.done == 1)
        #expect(counts.paneID == "%3")
    }

    @Test("alias payload is bounded even with very long host names")
    func payloadIsBounded() throws {
        let entry = ConnectionActivityEntry(id: UUID(), name: String(repeating: "服务器", count: 500),
                                            state: .connected)
        let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now))
        #expect(value.headlineName?.count == 80)
        #expect(try JSONEncoder().encode(value).count < 4096)
    }

    private final class Backend: ConnectionActivityBackend {
        enum Event: Equatable {
            case update(ConnectionActivityAttributes.ConnectionState, Bool)
            case end
        }
        var events: [Event] = []
        var pauseNext = false
        var waiting: CheckedContinuation<Void, Never>?
        func update(_ state: ConnectionActivityAttributes.ContentState, canStart: Bool) async {
            if pauseNext {
                pauseNext = false
                await withCheckedContinuation { waiting = $0 }
            }
            events.append(.update(state.connectionState, canStart))
        }
        func end() async { events.append(.end) }
    }

    private func withController(_ body: (ConnectionLiveActivity, Backend, AppSettings) async -> Void) async {
        let name = "test.connectionActivity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let backend = Backend()
        let controller = ConnectionLiveActivity(settings: settings,
            hub: SessionHub(metrics: SessionMetricsRegistry()), backend: backend)
        await body(controller, backend, settings)
    }

    @Test("steady snapshots are coalesced but their stale deadline is renewed")
    func renewFreshnessWithoutFlooding() async {
        await withController { controller, backend, _ in
            controller.submit(content(), canStart: true)
            await controller.waitForPendingDelivery()
            controller.submit(content(at: now.addingTimeInterval(2)), canStart: true)
            await controller.waitForPendingDelivery()
            #expect(backend.events.count == 1)
            controller.submit(content(at: now.addingTimeInterval(21)), canStart: true)
            await controller.waitForPendingDelivery()
            #expect(backend.events.count == 2)
            controller.submit(content(state: .reconnecting, at: now.addingTimeInterval(22)), canStart: true)
            await controller.waitForPendingDelivery()
            #expect(backend.events.last == .update(.reconnecting, true))
        }
    }

    @Test("disabling while an update is suspended ends the activity after that update")
    func serializedDisable() async {
        await withController { controller, backend, settings in
            backend.pauseNext = true
            controller.submit(content(), canStart: true)
            for _ in 0..<100 where backend.waiting == nil { await Task.yield() }
            #expect(backend.waiting != nil)
            settings.liveActivityEnabled = false
            controller.refresh(force: true)
            backend.waiting?.resume()
            backend.waiting = nil
            await controller.waitForPendingDelivery()
            #expect(backend.events == [.update(.connected, true), .end])
        }
    }

    @Test("background updates do not request a new activity")
    func backgroundCannotStart() async {
        await withController { controller, backend, _ in
            controller.submit(content(state: .background), canStart: false)
            await controller.waitForPendingDelivery()
            #expect(backend.events == [.update(.background, false)])
        }
    }

    @Test("host aliases default on and an explicit privacy choice is preserved")
    func privacyDefaults() async {
        await withController { _, _, settings in
            #expect(settings.liveActivityEnabled)
            #expect(settings.liveActivityShowHostNames)
            settings.liveActivityShowHostNames = false
            #expect(!settings.liveActivityShowHostNames)
            #expect(AppSettings.agentNotificationsAvailable)
        }
    }

    @Test("connection activity fits the lock screen at phone and tablet widths",
          arguments: [320.0, 360.0, 600.0])
    func lockScreenFits(width: Double) {
        var long = content()
        long.headlineName = String(repeating: "long-host-", count: 8)
        long.attentionCount = 10
        long.workingCount = 10
        long.programName = "Claude Code"
        long.workspaceName = String(repeating: "workspace-", count: 8)
        long.transportName = "Cloudflare"
        long.taskState = .attention
        var working = content()
        working.headlineName = "Mac mini"
        working.programName = "Codex"
        working.workspaceName = "Hermit · main"
        working.transportName = "Relay"
        working.taskState = .working
        working.workingCount = 2
        var plain = content()
        plain.headlineName = "Mac mini"
        plain.transportName = "SSH"
        var failed = working
        failed.programName = "Shell"
        failed.taskState = .done
        failed.workingCount = 0
        failed.doneCount = 1
        failed.commandExitCode = 127
        var reconnecting = plain
        reconnecting.connectionState = .reconnecting
        let variants = [("long-attention", long), ("working", working),
                        ("plain-ssh", plain), ("command-failed", failed), ("reconnecting", reconnecting)]
        for (name, value) in variants {
            for stale in [false, true] {
                let renderer = ImageRenderer(content: ConnectionActivityLockScreen(state: value, isStale: stale)
                    .environment(\.colorScheme, .dark)
                    .background(Color.black))
                // Propose the system card width instead of forcing an outer
                // frame that could conceal an intrinsically narrow layout.
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                let image = renderer.uiImage
                let height = image?.size.height ?? .infinity
                #expect(height > 20 && height <= 160, "\(name) must fit the system card")
                #expect(image?.size.width == CGFloat(width), "\(name) must use the available card width")
                if let directory = ProcessInfo.processInfo.environment["MOSHPIT_ACTIVITY_LAYOUT_OUTPUT"],
                   let png = image?.pngData() {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try? png.write(to: output.appendingPathComponent("\(name)-\(Int(width))-\(stale ? "stale" : "live").png"))
                }
            }
        }
    }

    @Test("running activities from the previous version remain decodable")
    func legacyPayload() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(content())) as? [String: Any])
        for key in ["isBackground", "transportName", "workspaceName", "programName", "taskState", "observedAt", "tasks", "totalTaskCount"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(ConnectionActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.connectionState == .connected && decoded.programName == nil)
        #expect(decoded.tasks == nil && decoded.totalTaskCount == nil)
    }

    @Test("ordinary SSH retains useful context without inventing task progress")
    func plainSSHContext() throws {
        let entry = ConnectionActivityEntry(id: UUID(), name: "Mac mini\n Lab", state: .connected,
                                            transportName: "SSH")
        let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: false, showHostNames: true, now: now))
        #expect(value.headlineName == "Mac mini Lab")
        #expect(value.transportName == "SSH" && value.connectionState == .connected)
        #expect(value.taskState == nil && value.isBackground == true)
    }

    @Test("renewal and backgrounding cannot freshen a cached remote task")
    func cachedTaskKeepsObservationTime() throws {
        let observation = now.addingTimeInterval(-120)
        let entry = ConnectionActivityEntry(id: UUID(), name: "Mini", state: .connected,
            working: 1, programName: "Codex", taskState: .working, observedAt: observation)
        for foreground in [true, false] {
            let value = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
                foreground: foreground, showHostNames: true, now: now))
            #expect(value.statusDate == observation)
            #expect(value.statusDate.addingTimeInterval(45) < now)
            #expect(value.updatedAt == now && value.taskState == .working)
        }
    }
    @Test("task rows are bounded, urgency ordered, privacy filtered and pane linked")
    func taskRows() throws {
        let id = UUID()
        let contexts = (0..<13).map { index in
            ConnectionActivityContext(workspaceName: "private-workspace-\(index)", programName: "Codex",
                taskState: index == 12 ? "attention" : "working", paneID: "w1:p\(index)",
                taskDetail: "private-task-\(index)")
        }
        let entry = ConnectionActivityEntry(id: id, name: "private-host", state: .connected,
            working: 12, attention: 1, observedAt: now.addingTimeInterval(-100), tasks: contexts)
        let offline = ConnectionActivityEntry(id: UUID(), name: "offline", state: .offline, tasks: contexts)
        let privateState = try #require(ConnectionActivitySnapshot.make(entries: [entry, offline], preferredID: id,
            foreground: false, showHostNames: false, now: now, showTaskDetails: false))
        let rows = try #require(privateState.tasks)
        #expect(rows.count == 3 && privateState.totalTaskCount == 13)
        #expect(rows.first?.state == .attention)
        #expect(rows.first?.id == "\(id.uuidString):w1:p12")
        #expect(privateState.statusDate == now.addingTimeInterval(-100))
        let rowLink = try #require(rows.first?.deepLink)
        let target = try #require(AgentDeepLink.parse(rowLink))
        #expect(target.connectionId == id && target.paneId == "w1:p12")
        let encoded = String(decoding: try JSONEncoder().encode(privateState), as: UTF8.self)
        #expect(!encoded.contains("private-"))
        let shared = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: id,
            foreground: true, showHostNames: true, now: now, showTaskDetails: true))
        #expect(shared.tasks?.first?.workspaceName == "private-workspace-12")
        #expect(shared.tasks?.first?.detail == "private-task-12")
    }

    @Test("three Unicode rows and long aliases remain below ActivityKit's payload budget")
    func unicodeTaskPayload() throws {
        let id = UUID()
        let task = ConnectionActivityContext(workspaceName: String(repeating: "🔐工作区", count: 300),
            programName: "Claude Code", taskState: "working", paneID: "w1:p1",
            taskDetail: String(repeating: "👨‍👩‍👧‍👦中文任务\n", count: 300))
        let entries = (0..<5).map { _ in ConnectionActivityEntry(id: UUID(),
            name: String(repeating: "服务器", count: 200), state: .connected, tasks: [task]) }
        let state = try #require(ConnectionActivitySnapshot.make(entries: entries, preferredID: id,
            foreground: true, showHostNames: true, now: now, showTaskDetails: true))
        #expect(state.tasks?.count == 3 && state.totalTaskCount == 5)
        #expect(try JSONEncoder().encode(state).count < 4096)
        #expect(state.tasks?.allSatisfy { ($0.detail?.utf8.count ?? 0) <= 180 } == true)
    }

    @Test("reference task list fits the card at phone and mini widths and larger type",
          arguments: [320.0, 360.0, 600.0])
    func referenceLayout(width: Double) throws {
        var state = content()
        state.headlineName = "Mac mini"
        state.isBackground = true
        state.totalTaskCount = 13
        state.tasks = [
            .init(id: "1", workspaceName: "stream-agent", programName: "Codex",
                  detail: "分析当前工程架构", state: .done, deepLink: state.deepLink),
            .init(id: "2", workspaceName: "toy", programName: "Claude Code",
                  detail: "设计基于 ESP32 开源方案的软硬件交互玩具", state: .working, deepLink: state.deepLink),
            .init(id: "3", workspaceName: "idea", programName: "Codex",
                  detail: "检查当前 SSH 客户端", state: .working, deepLink: state.deepLink)
        ]
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility5] {
            for stale in [false, true] {
                let renderer = ImageRenderer(content: ConnectionActivityLockScreen(state: state, isStale: stale)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.locale, Locale(identifier: "zh-Hans"))
                    .environment(\.colorScheme, .dark).background(Color(white: 0.12)))
                renderer.proposedSize = .init(width: width, height: nil)
                let image = try #require(renderer.uiImage)
                #expect(image.size.height > 50 && image.size.height <= 160,
                        "\(width) / \(size) / stale=\(stale): \(image.size.height)pt")
                #expect(image.size.width == CGFloat(width))
                if let directory = ProcessInfo.processInfo.environment["MOSHPIT_ACTIVITY_LAYOUT_OUTPUT"] {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try image.pngData()?.write(to: output.appendingPathComponent(
                        "reference-\(Int(width))-\(size)-\(stale ? "stale" : "live").png"))
                }
            }
        }
    }

}
