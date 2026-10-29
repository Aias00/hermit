import Foundation
import MoshpitKit
import Testing
@testable import Moshpit

@Suite("Plain SSH shell lifecycle", .serialized)
@MainActor
struct PlainSSHShellIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func connection() -> ServerConnection {
        var value = ServerConnection(name: "private-host", host: "192.0.2.1", port: 22,
                                     username: "tester", authMethod: .password)
        value.multiplexer = .none
        return value
    }

    private final class Backend: ConnectionActivityBackend {
        var last: ConnectionActivityAttributes.ContentState?
        func update(_ state: ConnectionActivityAttributes.ContentState, canStart: Bool) async { last = state }
        func end() async { last = nil }
    }

    @Test("only the current stream can update a session and stop invalidates partial markers")
    func generations() async {
        let session = SessionHub.ActiveSession(connection: connection())
        let old = session.beginPlainSSHObservation()
        session.observePlainSSHOutput(Data("\u{1B}]133;C\u{07}\u{1B}]133;D;".utf8), generation: old, now: now)
        #expect(session.plainSSHCommand?.phase == .running)
        let fresh = session.beginPlainSSHObservation()
        #expect(session.plainSSHCommand == nil)
        session.observePlainSSHOutput(Data("0\u{07}\u{1B}]133;C\u{07}".utf8), generation: old)
        #expect(session.plainSSHCommand == nil)
        session.observePlainSSHOutput(Data("0\u{07}".utf8), generation: fresh)
        #expect(session.plainSSHCommand == nil)
        session.observePlainSSHOutput(Data("\u{1B}]133;C\u{07}".utf8), generation: fresh, now: now)
        #expect(session.plainSSHCommand?.phase == .running)
        await session.stop(forReconnect: true)
        session.observePlainSSHOutput(Data("\u{1B}]133;D;0\u{07}".utf8), generation: fresh)
        #expect(session.plainSSHCommand == nil)
    }

    @Test("plain SSH events reach the activity without private command lines or paths")
    func activityEndToEnd() async throws {
        let defaultsName = "test.shellActivity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AppSettings(defaults: defaults)
        settings.liveActivityShowHostNames = false
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let config = connection()
        let session = hub.prepare(config)
        session.viewModel.markConnected()
        let backend = Backend()
        let activity = ConnectionLiveActivity(settings: settings, hub: hub, backend: backend)
        let generation = session.beginPlainSSHObservation()

        activity.refresh(force: true, now: now)
        await activity.waitForPendingDelivery()
        #expect(backend.last?.taskState == nil && backend.last?.programName == nil)
        session.observePlainSSHOutput(Data("\u{1B}]7;file://remote/private/project\u{07}\u{1B}]633;E;curl --token secret;nonce\u{07}\u{1B}]633;C\u{07}".utf8), generation: generation, now: now)
        activity.refresh(force: true, now: now.addingTimeInterval(2))
        await activity.waitForPendingDelivery()
        #expect(backend.last?.taskState == .working && backend.last?.workingCount == 1)
        #expect(backend.last?.programName == "Shell" && backend.last?.observedAt == now)

        let finished = now.addingTimeInterval(5)
        session.observePlainSSHOutput(Data("\u{1B}]633;D;7\u{07}\u{1B}]633;A\u{07}".utf8), generation: generation, now: finished)
        activity.refresh(force: true, now: finished.addingTimeInterval(120))
        await activity.waitForPendingDelivery()
        let value = try #require(backend.last)
        #expect(value.taskState == .done && value.commandExitCode == 7)
        #expect(value.workingCount == 0 && value.doneCount == 0 && value.attentionCount == 0)
        #expect(value.statusDate == finished)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for privateText in ["private-host", "/private/project", "secret", "curl", "192.0.2.1"] {
            #expect(!encoded.contains(privateText))
        }
        session.viewModel.resetForReconnect()
        activity.refresh(force: true, now: finished)
        await activity.waitForPendingDelivery()
        #expect(backend.last?.taskState == nil && backend.last?.commandExitCode == nil)
        await hub.disconnect(config.id)
    }
}
