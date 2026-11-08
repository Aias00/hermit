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
                "an unrepresented pane cannot update this activity")
    }

    @Test("cross-server events preserve overview scope and legacy row provenance")
    func crossServerOverviewPreservesHostNames() throws {
        let other = UUID()
        var state = snapshot()
        state.connectionCount = 2
        state.headlineName = "Mac mini"
        state.tasks?[1].hostName = "MacBook"
        state.tasks?[1].id = "\(other.uuidString):w1:p2"
        state.tasks?[1].deepLink = AgentDeepLink.string(connectionId: other, paneId: "w1:p2")
        let prompt = AgentTaskEvent(connectionID: other, paneID: "w1:p2", state: .attention,
            occurredAt: now.addingTimeInterval(1), receivedAt: now.addingTimeInterval(2))
        let changed = try #require(TaskActivityPresentation.applying(prompt, to: state)).content
        #expect(changed.headlineName == "MacBook" && changed.cardTitle == state.cardTitle)
        #expect(changed.tasks?.first(where: { $0.id.hasPrefix(connection.uuidString) })?.hostName == "Mac mini")
        #expect(changed.tasks?.first?.hostName == "MacBook")
        #expect(AgentDeepLink.parse(changed.deepLink)?.connectionId == other)
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

    @Test("A completion outside the first three rows is merged using the complete model without double-counting")
    func hiddenCompletionUsesExistingCard() throws {
        let contexts = (1...14).map { index in
            ConnectionActivityContext(workspaceName: "work-\(index)", programName: "Codex",
                taskState: "working", paneID: "w1:p\(index)", taskDetail: "task \(index)")
        }
        var entry = ConnectionActivityEntry(id: connection, name: "Host", state: .connected,
            working: 14, observedAt: now, tasks: contexts)
        let before = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now))
        let signal = AgentTaskEvent(connectionID: connection, paneID: "w1:p14", state: .done,
            occurredAt: now.addingTimeInterval(1), receivedAt: now.addingTimeInterval(2))
        #expect(before.tasks?.contains(where: { $0.id == signal.taskID }) == false)
        #expect(TaskActivityPresentation.applying(signal, to: before) == nil,
                "this was the previous path to an ordinary notification")
        entry.working = 13
        entry.done = 1
        entry.tasks[13].taskState = "done"
        entry.observedAt = now.addingTimeInterval(1)
        let refreshed = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now.addingTimeInterval(1),
            recentCompletionID: signal.taskID))
        let update = try #require(TaskActivityPresentation.applying(signal, to: before, refreshedSnapshot: refreshed))
        #expect(update.content.tasks?.first?.id == signal.taskID)
        #expect(AgentDeepLink.parse(update.content.deepLink)?.paneId == signal.paneID)
        #expect(update.content.tasks?.count == 3 && update.content.totalTaskCount == 14)
        #expect(update.content.doneCount == 1 && update.content.workingCount == 13)
        #expect(TaskActivityPresentation.applying(signal, to: update.content, refreshedSnapshot: refreshed)?.isRepeat == true)
        var newer = before
        newer.updatedAt = now.addingTimeInterval(10)
        #expect(TaskActivityPresentation.applying(signal, to: newer, refreshedSnapshot: refreshed) == nil,
                "a snapshot captured before a queued update must not replace newer state")
        let privateState = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: false, now: now, recentCompletionID: signal.taskID))
        #expect(privateState.tasks?.first?.workspaceName == nil && privateState.tasks?.first?.detail == nil)
        entry.tasks[0].taskState = "attention"
        let waiting = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now, recentCompletionID: signal.taskID))
        #expect(waiting.tasks?.first?.state == .attention)
        #expect(waiting.tasks?.contains(where: { $0.id == signal.taskID }) == true,
                "a completion gets a row while urgent prompts retain precedence")
        entry.tasks[0].taskState = "working"
        entry.tasks[13].taskState = "working"
        entry.done = 0
        entry.working = 14
        let newTurn = try #require(ConnectionActivitySnapshot.make(entries: [entry], preferredID: nil,
            foreground: true, showHostNames: true, now: now, recentCompletionID: signal.taskID))
        #expect(newTurn.tasks?.contains(where: { $0.id == signal.taskID }) == false,
                "an old completion cannot pin a pane that started working again")
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

    @Test("Task events only update cards, silently, regardless of legacy notification preference")
    func localRouting() async throws {
        let suite = "test.taskrouter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = false
        var covered = true
        var alertFlags: [Bool] = []
        var removed: [String] = []
        let router = AgentTaskNotificationRouter(settings: settings,
            isVisible: { _, _ in false }, presentActivity: { _, _, alert in
                alertFlags.append(alert); return covered
            }, remove: { removed += $0 })
        for state in [AgentTaskEvent.State.done, .attention] {
            let content = UNMutableNotificationContent()
            content.userInfo = AgentTaskEvent(connectionID: connection, paneID: "w1:p1", state: state,
                                             occurredAt: Date()).userInfo
            #expect(await router.consume(content))
            covered = false
            #expect(await router.consume(content) == false)
            settings.notificationsEnabled = true
            router.submit(.init(identifier: "no-card", content: content, trigger: nil))
            await router.waitForPendingDelivery()
            covered = true
        }
        #expect(alertFlags == Array(repeating: false, count: 6))
        #expect(removed.contains("moshpit.done.\(connection.uuidString).w1:p1"))
        settings.liveActivityEnabled = false
        let content = UNMutableNotificationContent()
        content.userInfo = AgentTaskEvent(connectionID: connection, paneID: "w1:p1", state: .done,
                                         occurredAt: Date()).userInfo
        #expect(await router.consume(content) == false)
        #expect(alertFlags.count == 6, "disabled cards must not attempt presentation")
        #expect(!AgentNotifications.ordinaryNotificationsEnabled)
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
        let router = AgentTaskNotificationRouter(settings: settings, isVisible: { _, _ in false },
            presentActivity: { _, _, _ in
                calls += 1
                if calls == 1 { await withCheckedContinuation { gate = $0 } }
                return false
            }, remove: { _ in })
        let content = UNMutableNotificationContent()
        content.userInfo = AgentTaskEvent(connectionID: connection, paneID: "w1:p1", state: .attention,
                                         occurredAt: Date()).userInfo
        router.submit(.init(identifier: "first", content: content, trigger: nil))
        router.submit(.init(identifier: "second", content: content, trigger: nil))
        for _ in 0..<100 where gate == nil { await Task.yield() }
        #expect(calls == 1)
        gate?.resume()
        await router.waitForPendingDelivery()
        #expect(calls == 2)
    }
}
