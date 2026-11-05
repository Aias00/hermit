import Foundation
import MoshpitKit
import Testing
import UserNotifications
@testable import Moshpit

@Suite("Unified task presentation", .serialized) @MainActor
struct AgentTaskPresentationTests {
    private let connection = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot() -> ConnectionActivityAttributes.ContentState {
        let link = AgentDeepLink.string(connectionId: connection, paneId: "w1:p1")
        return .init(connectionCount: 1, headlineName: "MacBook", connectionState: .connected,
            workingCount: 2, attentionCount: 0, doneCount: 0, deepLink: link, updatedAt: now,
            isBackground: true, taskState: .working, observedAt: now,
            tasks: [
                .init(id: connection.uuidString + ":w1:p1", workspaceName: "project", programName: "Codex",
                    detail: "task one", state: .working, deepLink: link, observedAt: now),
                .init(id: connection.uuidString + ":w1:p2", workspaceName: "other", programName: "Codex",
                    state: .working, deepLink: AgentDeepLink.string(connectionId: connection, paneId: "w1:p2"), observedAt: now)
            ], totalTaskCount: 2)
    }

    private func event(_ state: AgentTaskEvent.State = .done, offset: TimeInterval = 1) -> AgentTaskEvent {
        .init(connectionID: connection, paneID: "w1:p1", state: state,
              occurredAt: now.addingTimeInterval(offset), receivedAt: now.addingTimeInterval(offset + 1))
    }

    @Test("A completion updates only its row and counts; duplicate events cannot alert again")
    func completionAndDeduplication() throws {
        let signal = event()
        let result = try #require(TaskActivityPresentation.applying(signal, to: snapshot()))
        #expect(!result.isRepeat)
        #expect(result.content.taskState == .done)
        #expect(result.content.doneCount == 1 && result.content.workingCount == 1)
        #expect(result.content.tasks?.first(where: { $0.id == signal.taskID })?.state == .done)
        #expect(result.content.tasks?.first(where: { $0.state == .working })?.observedAt == now,
                "an event is not a fresh read of the other tasks")
        let repeated = try #require(TaskActivityPresentation.applying(signal, to: result.content))
        #expect(repeated.isRepeat && repeated.content == result.content)
        let anotherPane = AgentTaskEvent(connectionID: connection, paneID: "w9:p9", state: .attention,
                                        occurredAt: now)
        #expect(TaskActivityPresentation.applying(anotherPane, to: snapshot()) == nil,
                "an unrepresented pane must retain its normal notification fallback")
    }

    @Test("An older poll cannot undo an event, but a newer remote turn supersedes it")
    func reconcilePollingAndNewTurn() throws {
        let signal = event()
        var completed = try #require(TaskActivityPresentation.applying(signal, to: snapshot())).content
        let completedIndex = try #require(completed.tasks?.firstIndex(where: { $0.id == signal.taskID }))
        completed.tasks?[completedIndex].eventPresentation = "notification"
        let reconciled = TaskActivityPresentation.reconciling(snapshot(), with: completed)
        #expect(reconciled.taskState == .done && reconciled.doneCount == 1)
        #expect(reconciled.tasks?.first(where: { $0.id == signal.taskID })?.eventPresentation == "notification")
        var fresh = snapshot()
        fresh.tasks?[0].observedAt = now.addingTimeInterval(10)
        fresh.observedAt = now.addingTimeInterval(10)
        let newTurn = TaskActivityPresentation.reconciling(fresh, with: completed)
        #expect(newTurn.taskState == .working && newTurn.tasks?[0].eventID == nil)
        #expect(TaskActivityPresentation.applying(signal, to: newTurn) == nil,
                "a delayed completion cannot replace a verified newer working turn")
        fresh.tasks?[0].state = .done
        let donePoll = TaskActivityPresentation.reconciling(fresh, with: completed)
        #expect(donePoll.tasks?[0].observedAt == now.addingTimeInterval(10))
        #expect(TaskActivityPresentation.applying(signal, to: donePoll)?.isRepeat == true)
    }

    @Test("Attention rises to the top, and an old event cannot undo a later event")
    func attentionPriorityAndOrder() throws {
        let completed = try #require(TaskActivityPresentation.applying(event(), to: snapshot())).content
        let attention = event(.attention, offset: 5)
        let waiting = try #require(TaskActivityPresentation.applying(attention, to: completed)).content
        #expect(waiting.tasks?.first?.id == attention.taskID)
        #expect(waiting.attentionCount == 1 && waiting.doneCount == 0 && waiting.workingCount == 1)
        #expect(TaskActivityPresentation.applying(event(), to: waiting)?.isRepeat == true)
        let otherPane = AgentTaskEvent(connectionID: connection, paneID: "w1:p2", state: .attention,
                                      occurredAt: now.addingTimeInterval(7), receivedAt: now.addingTimeInterval(8))
        let otherPrompt = try #require(TaskActivityPresentation.applying(otherPane, to: snapshot())).content
        #expect(AgentDeepLink.parse(otherPrompt.deepLink)?.paneId == "w1:p2")
        #expect(otherPrompt.taskState == .attention && otherPrompt.workspaceName == "other")
    }

    @Test("Event identity survives serialization; stale, malformed and unrelated notifications cannot patch activities")
    func eventValidation() throws {
        let signal = event()
        let decoded = try #require(AgentTaskEvent(userInfo: signal.userInfo, now: signal.receivedAt))
        #expect(decoded.id == signal.id && decoded.taskID == signal.taskID)
        #expect(decoded.id.utf8.count == 24)
        #expect(AgentTaskEvent(userInfo: signal.userInfo, now: now.addingTimeInterval(86_400)) == nil)
        #expect(AgentTaskEvent(userInfo: [:]) == nil)
        var malformed = signal.userInfo
        malformed[AgentTaskEvent.timestampKey] = Double.nan
        #expect(AgentTaskEvent(userInfo: malformed) == nil)
        malformed[AgentTaskEvent.timestampKey] = now.addingTimeInterval(500).timeIntervalSince1970
        #expect(AgentTaskEvent(userInfo: malformed, now: now) == nil)
    }

    @Test("Activity receipts remain within the ActivityKit payload budget")
    func payloadBudget() throws {
        var value = snapshot()
        value.tasks = (0..<3).map { i in
            .init(id: connection.uuidString + ":w1:p\(i)", workspaceName: String(repeating: "项", count: 26),
                hostName: String(repeating: "机", count: 26), programName: "Claude Code",
                detail: String(repeating: "字", count: 60), state: .working,
                deepLink: AgentDeepLink.string(connectionId: connection, paneId: "w1:p\(i)"), observedAt: now)
        }
        for i in 0..<3 {
            let signal = AgentTaskEvent(connectionID: connection, paneID: "w1:p\(i)", state: .done,
                                       occurredAt: now, receivedAt: now)
            value = try #require(TaskActivityPresentation.applying(signal, to: value)).content
        }
        #expect(try JSONEncoder().encode(value).count < 4096)
    }

    @Test("Matching activities consume local notifications; unavailable activities keep a marked fallback")
    func localRouting() async throws {
        let suite = "test.taskrouter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = true
        var shown: [UNNotificationRequest] = []
        var visible = false, covered = true
        var alertFlags: [Bool] = []
        let router = AgentTaskNotificationRouter(settings: settings,
            isVisible: { _, _ in visible }, presentActivity: { _, _, alert in
                alertFlags.append(alert); return covered
            }, deliver: { shown.append($0) }, remove: { _ in })
        let content = UNMutableNotificationContent()
        content.userInfo = AgentTaskEvent(connectionID: connection, paneID: "w1:p1", state: .done,
                                         occurredAt: Date()).userInfo
        let request = UNNotificationRequest(identifier: "fixture", content: content, trigger: nil)
        router.submit(request)
        await router.waitForPendingDelivery()
        #expect(shown.isEmpty && alertFlags == [true])
        covered = false
        router.submit(request)
        await router.waitForPendingDelivery()
        #expect(shown.count == 1)
        #expect(shown[0].content.userInfo[AgentTaskEvent.fallbackKey] as? Bool == true)
        visible = true
        router.submit(request)
        await router.waitForPendingDelivery()
        #expect(shown.count == 1 && alertFlags.last == false)
        visible = false
        settings.liveActivityEnabled = false
        let previousAttempts = alertFlags.count
        router.submit(request)
        await router.waitForPendingDelivery()
        #expect(shown.count == 2 && alertFlags.count == previousAttempts)
        settings.notificationsEnabled = false
        router.submit(request)
        await router.waitForPendingDelivery()
        #expect(shown.count == 2)
    }

    @Test("Queued delivery remains ordered while a previous activity update is suspended")
    func routingIsSerialized() async throws {
        let suite = "test.taskrouter.queue.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = true
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        var fallback: [String] = []
        let router = AgentTaskNotificationRouter(settings: settings, isVisible: { _, _ in false },
            presentActivity: { _, _, _ in
                calls += 1
                if calls == 1 { await withCheckedContinuation { gate = $0 } }
                return false
            }, deliver: { fallback.append($0.identifier) }, remove: { _ in })
        let content = UNMutableNotificationContent()
        content.userInfo = AgentTaskEvent(connectionID: connection, paneID: "w1:p1", state: .attention,
                                         occurredAt: Date()).userInfo
        router.submit(.init(identifier: "first", content: content, trigger: nil))
        router.submit(.init(identifier: "second", content: content, trigger: nil))
        for _ in 0..<100 where gate == nil { await Task.yield() }
        #expect(calls == 1 && fallback.isEmpty)
        gate?.resume()
        await router.waitForPendingDelivery()
        #expect(fallback == ["first", "second"])
    }
}
