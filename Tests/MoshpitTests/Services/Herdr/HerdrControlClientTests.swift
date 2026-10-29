import Foundation
import Testing
@testable import Moshpit

/// Drives the whole control client against an in-memory runner: what commands
/// it sends, and what it does with what comes back.
@Suite("herdr control client")
@MainActor
struct HerdrControlClientTests {

    /// Records every command and replies with whatever the test queued.
    final class FakeRunner: HerdrCommandRunner, @unchecked Sendable {
        /// Per-command behaviour for tests that speak more than one command.
        enum Scripted { case reply(String), delayedReply(String), hang, fail }

        private let lock = NSLock()
        private var _commands: [String] = []
        private var _inputs: [Data] = []
        private var _socketResponse = #"{"socket":"/tmp/herdr-review.sock"}"# + "\n__moshpit_rc=0"
        private var _response: String
        private var _failNext = false
        private var _script: (@Sendable (String) -> Scripted)?

        init(response: String = "") { _response = response }

        var commands: [String] { lock.withLock { _commands } }
        var inputs: [Data] { lock.withLock { _inputs } }
        var inputObjects: [[String: Any]] { inputs.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        func setResponse(_ value: String) { lock.withLock { _response = value } }
        func setSocketResponse(_ value: String) { lock.withLock { _socketResponse = value } }
        func failNext() { lock.withLock { _failNext = true } }
        /// Route each command to its own behaviour — the single-response
        /// fields above cover the older single-command tests.
        func setScript(_ script: @escaping @Sendable (String) -> Scripted) {
            lock.withLock { _script = script }
        }

        func run(_ command: String, standardInput: Data) async throws -> String {
            lock.withLock { _inputs.append(standardInput) }
            let response = try await run(command)
            guard let request = try JSONSerialization.jsonObject(with: standardInput) as? [String: Any],
                  let id = request["id"] as? String else { return response }
            let object: [String: Any]
            switch response {
            case "__moshpit_rc=0": object = ["id": id, "result": [:]]
            case "__moshpit_rc=1": object = ["id": id, "error": ["code": "pane_not_found"]]
            case "unknown-input-method", "unknown-input-method-empty-id":
                object = ["id": response.hasSuffix("empty-id") ? "" : id, "error": ["code": "invalid_request", "message":
                    "invalid request: unknown variant `pane.send_input`, expected one of `pane.send_text`, `pane.send_keys` at line 1 column 98"]]
            case "invalid-input-params":
                object = ["id": id, "error": ["code": "invalid_request", "message":
                    "invalid request: missing field `pane_id` at line 1 column 98"]]
            case "invalid-key-variant":
                object = ["id": id, "error": ["code": "invalid_request", "message":
                    "invalid request: unknown variant `enter`, expected one of `up`, `down` at line 1 column 98"]]
            default: return response
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        func run(_ command: String) async throws -> String {
            let action: Scripted = lock.withLock {
                _commands.append(command)
                if command.contains("status server --json") { return .reply(_socketResponse) }
                if let script = _script { return script(command) }
                if _failNext {
                    _failNext = false
                    return .fail
                }
                return .reply(_response)
            }
            switch action {
            case .reply(let text):
                return text
            case .delayedReply(let text):
                try await Task.sleep(for: .milliseconds(50))
                return text
            case .fail:
                throw SSHError.sessionClosed
            case .hang:
                // "Never returns" as far as any sane budget is concerned;
                // honours cancellation so the test process doesn't linger.
                try await Task.sleep(for: .seconds(60))
                throw SSHError.sessionClosed
            }
        }
    }

    @Test("Delayed text, arrows and composer submits keep acknowledged FIFO order")
    func inputOrderingAcrossKinds() async throws {
        let runner = FakeRunner()
        runner.setScript { _ in .delayedReply("__moshpit_rc=0") }
        let client = HerdrControlClient(runner: runner)
        client.sendBytes(Data("abc".utf8), paneId: "w1:p1")
        client.sendKey("left", paneId: "w1:p1")
        client.sendBytes(Data("中文".utf8), paneId: "w1:p1")
        try await client.submitLine("draft", paneId: "w1:p1")
        let commands = runner.commands.filter { !$0.contains("api snapshot") && !$0.contains("status server --json") }
        #expect(commands.count == 4)
        #expect(runner.inputObjects[0]["method"] as? String == "pane.send_text")
        #expect((runner.inputObjects[0]["params"] as? [String: String])?["text"] == "abc")
        #expect(commands[1].contains("pane send-keys 'w1:p1' 'left'"))
        #expect((runner.inputObjects[1]["params"] as? [String: String])?["text"] == "中文")
        #expect(runner.inputObjects[2]["method"] as? String == "pane.send_input")
        client.stop()
    }

    @Test("An unconfirmed earlier input stops subsequent keys instead of replaying a partial command")
    func failedInputStopsFollowingKeys() async {
        let runner = FakeRunner(response: "__moshpit_rc=1")
        let client = HerdrControlClient(runner: runner)
        client.sendBytes(Data("abc".utf8), paneId: "w1:p1")
        client.sendKey("up", paneId: "w1:p1")
        do { try await client.flushInput(); Issue.record("must fail") } catch {}
        #expect(runner.commands.filter { !$0.contains("status server --json") }.count == 1)
        client.stop()
    }

    @Test("Composer submits text and Enter as one acknowledged server operation")
    func submitsOneOperation() async throws {
        let runner = FakeRunner(response: "__moshpit_rc=0")
        let client = HerdrControlClient(runner: runner)
        let text = "hello 'quoted'\nsecond line"
        try await client.submitLine(text, paneId: "w1:p2")
        #expect(runner.inputs.count == 1)
        let params = runner.inputObjects[0]["params"] as? [String: Any]
        #expect(params?["text"] as? String == text)
        #expect(params?["keys"] as? [String] == ["enter"])
        #expect(!runner.commands.joined().contains(text))
        client.stop()
    }

    @Test("Failed or unacknowledged submissions never report success or retry")
    func rejectsUnconfirmedSend() async {
        for reply in ["__moshpit_rc=1", "missing acknowledgement"] {
            let runner = FakeRunner(response: reply)
            let client = HerdrControlClient(runner: runner)
            do {
                try await client.submitLine("test", paneId: "w1:p2", timeout: 0.1)
                Issue.record("must retain draft when the command is not confirmed")
            } catch {}
            #expect(runner.inputs.count == 1)
            client.stop()
        }
    }

    @Test("A hung send returns an unknown result within its deadline without resending")
    func submissionDeadline() async {
        let runner = FakeRunner()
        runner.setScript { _ in .hang }
        let client = HerdrControlClient(runner: runner)
        let began = Date()
        do {
            try await client.submitLine("test", paneId: "w1:p2", timeout: 0.02)
            Issue.record("a hung command cannot be acknowledged")
        } catch {}
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(runner.commands.filter { !$0.contains("status server --json") }.count == 1)
        client.stop()
    }

    @Test("New input recovers after failure without replaying already-queued Enter")
    func freshInputAfterFailure() async throws {
        let runner = FakeRunner(response: "__moshpit_rc=1")
        let client = HerdrControlClient(runner: runner)
        client.sendBytes(Data("failed text".utf8), paneId: "w1:p1")
        client.sendKey("enter", paneId: "w1:p1")
        do { try await client.flushInput(); Issue.record("must reject") } catch {}
        runner.setResponse("__moshpit_rc=0")
        try await client.submitLine("new command", paneId: "w2:p1")
        #expect(runner.inputs.count == 2)
        #expect(!runner.commands.contains { $0.contains("send-keys") })
        #expect(client.inputError == nil)
        client.stop()
    }

    @Test("Keyboard bytes use terminal stdin even on hosts without Python")
    func keyboardUsesRawWriter() async throws {
        let runner = FakeRunner(response: "MOSHPIT_PRIVATE_INPUT_UNAVAILABLE\n")
        let client = HerdrControlClient(runner: runner)
        var written = Data()
        client.rawInputWriter = { bytes, _ in written.append(bytes) }
        let secret = Data([0, 0xff]) + Data("password with ' quotes".utf8)
        client.sendBytes(secret, paneId: "w1:p1")
        try await client.flushInput()
        #expect(written == secret)
        #expect(runner.commands.isEmpty)
        client.stop()
    }

    @Test("A known missing Python safely falls back once, but an uncertain reply never does")
    func privateSubmitFallback() async throws {
        for response in ["MOSHPIT_PRIVATE_INPUT_UNAVAILABLE\n", "missing acknowledgement"] {
            let runner = FakeRunner(response: response)
            let client = HerdrControlClient(runner: runner)
            var fallback: [String] = []
            client.rawSubmitWriter = { text, _ in fallback.append(text) }
            do { try await client.submitLine("secret-value", paneId: "w1:p1") }
            catch { #expect(response == "missing acknowledgement") }
            #expect(fallback.count == (response.hasPrefix("MOSHPIT_PRIVATE") ? 1 : 0))
            #expect(!runner.commands.joined().contains("secret-value"))
            #expect(runner.inputs.count == 1)
            client.stop()
        }
    }

    @Test("Only an explicit missing method permits private input fallback",
          arguments: ["unknown-input-method", "unknown-input-method-empty-id", "invalid-input-params", "invalid-key-variant"])
    func oldServerMethodFallback(response: String) async throws {
        let runner = FakeRunner(response: response)
        let client = HerdrControlClient(runner: runner)
        var fallback: [String] = []
        client.rawSubmitWriter = { text, _ in fallback.append(text) }
        do { try await client.submitLine("sensitive draft", paneId: "w1:p1") }
        catch { #expect(!response.hasPrefix("unknown-input-method")) }
        #expect(fallback.count == (response.hasPrefix("unknown-input-method") ? 1 : 0))
        #expect(runner.inputs.count == 1)
        #expect(!runner.commands.joined().contains("sensitive draft"))
        client.stop()
    }

    @Test("Private input discovers the configured herdr endpoint and caches it")
    func privateInputUsesConfiguredEndpoint() async throws {
        let runner = FakeRunner(response: "__moshpit_rc=0")
        let socket = "/tmp/custom session's herdr.sock"
        runner.setSocketResponse("{\"socket\":\"\(socket)\"}\n__moshpit_rc=0")
        let client = HerdrControlClient(runner: runner, customPath: "/opt/custom-herdr --session work")
        try await client.submitLine("first secret", paneId: "w1:p1")
        try await client.submitLine("second secret", paneId: "w1:p1")
        let discovery = runner.commands.filter { $0.contains("status server --json") }
        #expect(discovery.count == 1)
        #expect(discovery[0].contains("/opt/custom-herdr --session work status server --json"))
        let bridges = runner.commands.filter { $0.contains("python3 -c") }
        #expect(bridges.count == 2)
        #expect(bridges.allSatisfy { $0.contains(HerdrLaunch.quote(socket)) })
        #expect(!bridges.joined().contains(".config/herdr/herdr.sock"))
        #expect(!runner.commands.joined().contains("secret"))
        client.stop()
    }

    @Test("No discoverable endpoint falls back without touching a default server")
    func missingEndpointUsesTerminal() async throws {
        let runner = FakeRunner(response: "__moshpit_rc=0")
        runner.setSocketResponse("unsupported command\n__moshpit_rc=1")
        let client = HerdrControlClient(runner: runner, customPath: "/opt/old-herdr")
        var written: [String] = []
        client.rawSubmitWriter = { text, _ in written.append(text) }
        try await client.submitLine("private draft", paneId: "w1:p1")
        #expect(written == ["private draft"])
        #expect(runner.inputs.isEmpty)
        #expect(!runner.commands.contains { $0.contains("python3") })
        client.stop()
    }

    @Test("Raw submit rejects an unknown paste mode before creating input bytes")
    func rawSubmitRejectsUnknownMode() {
        #expect(throws: HerdrControlClient.SubmissionError.pasteUnavailable) {
            try HerdrControlClient.rawSubmitPayload("retained draft", bracketedPasteMode: nil)
        }
    }

    @Test("Raw submit preserves multiline text and appends one Enter using the known remote mode",
          arguments: [true, false])
    func rawSubmitUsesKnownMode(bracketed: Bool) throws {
        let text = "第一行\nsecond 'quoted' line"
        let payload = try HerdrControlClient.rawSubmitPayload(text, bracketedPasteMode: bracketed)
        let expected = bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~\r" : text + "\r"
        #expect(payload == Data(expected.utf8))
        #expect(payload.filter { $0 == 0x0d }.count == 1)
    }

    @Test("An unknown frame paste mode stops fallback before any terminal write")
    func framePasteFallbackPreservesDraft() async {
        let runner = FakeRunner(response: "unknown-input-method")
        let client = HerdrControlClient(runner: runner)
        var attempts = 0
        var written = Data()
        client.rawSubmitWriter = { text, _ in
            attempts += 1
            written.append(try HerdrControlClient.rawSubmitPayload(text, bracketedPasteMode: nil))
        }
        do {
            try await client.submitLine("retained draft", paneId: "w1:p1")
            Issue.record("a frame-only client must not report an unsafe paste as accepted")
        } catch {
            #expect(error as? HerdrControlClient.SubmissionError == .pasteUnavailable)
        }
        #expect(attempts == 1)
        #expect(written.isEmpty)
        #expect(runner.inputObjects.count == 1)
        #expect(runner.inputObjects.first?["method"] as? String == "pane.send_input")
        #expect(!runner.commands.contains { $0.contains("send-keys") })
        #expect(client.inputError == HerdrControlClient.SubmissionError.pasteUnavailable.errorDescription)
        client.stop()
    }

    @Test("Unavailable paste without a mode-aware writer gives an actionable error")
    func unavailablePasteWithoutFallback() async {
        let runner = FakeRunner(response: "__moshpit_rc=0")
        runner.setSocketResponse("unsupported command\n__moshpit_rc=1")
        let client = HerdrControlClient(runner: runner)
        do {
            try await client.submitLine("retained draft", paneId: "w1:p1")
            Issue.record("undiscoverable endpoint cannot accept a draft")
        } catch {
            #expect(error as? HerdrControlClient.SubmissionError == .pasteUnavailable)
        }
        #expect(runner.inputs.isEmpty)
        #expect(client.inputError?.contains("python3") == true)
        client.stop()
    }

    nonisolated private static let twoWorkspaces = """
    {"id":"cli:api:snapshot","result":{"snapshot":{
      "workspaces":[{"workspace_id":"w1","label":"~","focused":true},
                    {"workspace_id":"w2","label":"api","focused":false}],
      "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"focused":true,"pane_count":2}],
      "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","focused":false},
               {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","focused":true}],
      "layouts":[],
      "focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p2"}}}
    """

    /// Let the client's async work drain. Its poll/send hop through `Task`,
    /// so tests need a yield point rather than a fixed sleep — and a busy CI
    /// runner can take longer than a dozen bare yields to schedule that hop
    /// (the dead-socket test went red there once), so each yield also gives
    /// up the actor for a few milliseconds. A caller that can name the effect
    /// it waits for passes it and gets up to two seconds of patience.
    private func settle(_ times: Int = 12, until done: (@MainActor () -> Bool)? = nil) async {
        for _ in 0..<times {
            await Task.yield()
            if let done, done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let done else { return }
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func started(_ runner: FakeRunner, customPath: String? = nil) async -> HerdrControlClient {
        let client = HerdrControlClient(runner: runner, customPath: customPath)
        client.start()
        await settle()
        return client
    }

    // MARK: - Reading

    @Test("Hook observation time advances only for verified snapshots or a stopped server")
    func hookObservationRequiresVerifiedRead() async throws {
        let runner = FakeRunner(response: "shell noise")
        let client = HerdrControlClient(runner: runner)
        defer { client.stop() }
        #expect(client.agentHooksObservedAt == nil)
        await client.pollNowForTesting()
        #expect(client.agentHooksObservedAt == nil)

        runner.setResponse(Self.twoWorkspaces)
        await client.pollNowForTesting()
        let first = try #require(client.agentHooksObservedAt)
        let beforeFailures = client.snapshot
        runner.failNext()
        await client.pollNowForTesting()
        #expect(client.agentHooksObservedAt == first)
        runner.setResponse("{\"workspaces\":[")
        await client.pollNowForTesting()
        #expect(client.agentHooksObservedAt == first)
        #expect(client.snapshot == beforeFailures)

        // A complete stdout payload with a failed exit still cannot certify
        // freshness. A later identical successful observation can.
        runner.setResponse(Self.twoWorkspaces + "\n__moshpit_rc=1")
        await client.pollNowForTesting()
        #expect(client.agentHooksObservedAt == first)
        runner.setResponse(Self.twoWorkspaces)
        await client.pollNowForTesting()
        let renewed = try #require(client.agentHooksObservedAt)
        #expect(renewed > first)

        runner.setResponse("{\"error\":{\"code\":\"server_not_running\"}}")
        await client.pollNowForTesting()
        #expect(client.snapshot.sessions.isEmpty)
        #expect(try #require(client.agentHooksObservedAt) > renewed)
    }

    @Test("First poll populates the tree")
    func firstPollPopulates() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        #expect(client.snapshot.sessions.count == 2)
        #expect(client.snapshot.activePaneId == "w1:p2")
        #expect(client.snapshot.isAttached)
        #expect(runner.commands.first?.contains("api snapshot") == true)
    }

    @Test("A custom binary path is used verbatim for control commands too")
    func customPathUsed() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        _ = await started(runner, customPath: "/opt/herdr/bin/herdr")
        #expect(runner.commands.first?.hasPrefix("/opt/herdr/bin/herdr api snapshot") == true)
    }

    @Test("Without a custom path the PATH prefix rides along")
    func defaultPathPrefix() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        _ = await started(runner)
        #expect(runner.commands.first?.contains("$HOME/.local/bin") == true)
    }

    @Test("A failed read keeps the last good tree instead of blanking the UI")
    func failureKeepsLastTree() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        #expect(client.snapshot.sessions.count == 2)

        runner.failNext()
        client.refresh()
        await settle()
        #expect(client.snapshot.sessions.count == 2)   // unchanged
    }

    @Test("Garbage output also keeps the last good tree")
    func garbageKeepsLastTree() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)

        runner.setResponse("bash: herdr: command not found")
        client.refresh()
        await settle()
        #expect(client.snapshot.sessions.count == 2)
    }

    @Test("server_not_running empties the tree — that's real information")
    func serverNotRunningEmpties() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)

        runner.setResponse("""
        {"error":{"code":"server_not_running","message":"no herdr server is running"},"id":"cli:api:snapshot"}
        """)
        client.refresh()
        await settle()
        #expect(client.snapshot.sessions.isEmpty)
        #expect(client.serverNotRunning)
        // …but we remember that we HAD been attached, so the home card shows an
        // empty session list rather than a stuck "Attaching…" spinner.
        #expect(client.snapshot.everAttached)
    }

    /// The regression that shipped: herdr 0.7.3 prints a bare Rust error for a
    /// dead socket instead of the structured `server_not_running` JSON that
    /// 0.8.0 (which the design was read from) prints. Matching on the text
    /// missed it entirely — the tree stayed empty, `serverNotRunning` stayed
    /// false, and the terminal showed a black screen with no empty state and
    /// no error. The exit status is 1 in both versions, so that's what decides.
    @Test("A dead socket is detected by exit status, not by error wording")
    func deadSocketDetectedByExitCode() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        #expect(!client.serverNotRunning)

        runner.setResponse("""
        Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }
        \(HerdrControlClient.exitCodeMarker)1
        """)
        client.refresh()
        await settle(until: { client.serverNotRunning })
        #expect(client.serverNotRunning)
        #expect(client.snapshot.sessions.isEmpty)
    }

    @Test("A zero exit with junk output is 'no new information', not 'no server'")
    func junkWithSuccessKeepsTree() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)

        runner.setResponse("some unrelated chatter\n\(HerdrControlClient.exitCodeMarker)0")
        client.refresh()
        await settle()
        #expect(!client.serverNotRunning)
        #expect(client.snapshot.sessions.count == 2)   // last good tree kept
    }

    /// The second half of the black-screen report: herdr's direct attach is
    /// exclusive per terminal, so another client attaching with `--takeover`
    /// evicts ours — with the focused pane completely unchanged. Reporting the
    /// focus only on change meant the frame channel could never re-attach and
    /// the app stayed blank forever. Every poll must re-assert it.
    @Test("The focused pane is reported on every poll, not only when it changes")
    func focusReportedEveryPoll() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = HerdrControlClient(runner: runner)
        var reports: [String] = []
        client.onFocusedPaneChanged = { reports.append($0) }
        client.start()
        await settle()
        #expect(reports == ["w1:p2"])

        // Same tree, same focus — still re-asserted, which is what lets the
        // frame channel recover after being evicted.
        client.refresh()
        await settle()
        #expect(reports == ["w1:p2", "w1:p2"])
    }

    // MARK: - Poll cadence

    /// Each poll is a whole SSH exec channel. An idle session — an agent
    /// thinking, a shell at a prompt — is the common case, and paying 30 of
    /// them a minute for an unchanging answer is real battery and cellular
    /// data. herdr's CLI offers no general event subscription to replace it
    /// (`herdr wait` is per-pane and per-status), so the poll eases off
    /// instead.
    @Test("An unchanging tree eases the poll off the fast cadence")
    func idleBackoff() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        #expect(client.pollInterval == HerdrControlClient.fastPollInterval)

        // Drive identical reads until the cadence relaxes. `quicken()` polls
        // and resets, so use it once then let repeated reads accumulate.
        for _ in 0...HerdrControlClient.idlePollThreshold {
            await client.pollNowForTesting()
        }
        #expect(client.pollInterval == HerdrControlClient.idlePollInterval)
    }

    @Test("Any change snaps the cadence back immediately")
    func changeResetsCadence() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        for _ in 0..<6 { await client.pollNowForTesting() }
        #expect(client.pollInterval == HerdrControlClient.idlePollInterval)

        // Focus moved — that's activity.
        runner.setResponse(Self.twoWorkspaces.replacingOccurrences(
            of: #""focused_pane_id":"w1:p2""#, with: #""focused_pane_id":"w1:p1""#))
        await client.pollNowForTesting()
        #expect(client.pollInterval == HerdrControlClient.fastPollInterval)
    }

    @Test("quicken() drops back to fast — the frame channel's recovery rides on it")
    func quickenResetsCadence() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        for _ in 0..<6 { await client.pollNowForTesting() }
        #expect(client.pollInterval == HerdrControlClient.idlePollInterval)

        client.quicken()
        await settle()
        #expect(client.pollInterval == HerdrControlClient.fastPollInterval)
    }

    @Test("Losing the server also returns to the fast cadence")
    func serverLossResetsCadence() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        for _ in 0..<6 { await client.pollNowForTesting() }
        #expect(client.pollInterval == HerdrControlClient.idlePollInterval)

        runner.setResponse("Error: Os { code: 2 }\n\(HerdrControlClient.exitCodeMarker)1")
        await client.pollNowForTesting()
        #expect(client.serverNotRunning)
        #expect(client.pollInterval == HerdrControlClient.fastPollInterval)
    }

    @Test("Every command carries the exit-status trailer")
    func commandsCarryExitTrailer() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        _ = await started(runner)
        #expect(runner.commands.first?.contains(HerdrControlClient.exitCodeMarker) == true)
    }

    @Test("Exit-status parsing splits the trailer off the output")
    func parseExitTrailer() {
        let withCode = HerdrControlClient.parse("payload\n\(HerdrControlClient.exitCodeMarker)7\n")
        #expect(withCode.exitCode == 7)
        #expect(withCode.failed)
        #expect(withCode.output.trimmingCharacters(in: .whitespacesAndNewlines) == "payload")

        let ok = HerdrControlClient.parse("payload\n\(HerdrControlClient.exitCodeMarker)0")
        #expect(ok.exitCode == 0)
        #expect(!ok.failed)

        // No trailer (a shell that died before echoing) → unknown, not failed:
        // blanking the tree on a truncated read would be worse than keeping it.
        let missing = HerdrControlClient.parse("payload only")
        #expect(missing.exitCode == nil)
        #expect(!missing.failed)
    }

    // MARK: - Commands

    /// Everything the sheets can trigger, and the herdr CLI call it becomes.
    @Test("Sheet actions map to the right herdr subcommands")
    func commandMapping() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)

        func lastCommand(_ action: () -> Void) async -> String {
            let before = runner.commands.count
            action()
            await settle()
            // [command, then the refresh poll that follows it]
            return runner.commands.count > before ? runner.commands[before] : ""
        }

        #expect(await lastCommand { client.selectSession("w2") }.contains("workspace focus 'w2'"))
        #expect(await lastCommand { client.selectWindow("w1:t1") }.contains("tab focus 'w1:t1'"))
        #expect(await lastCommand { client.killSession("w2") }.contains("workspace close 'w2'"))
        #expect(await lastCommand { client.killWindow("w1:t1") }.contains("tab close 'w1:t1'"))
        #expect(await lastCommand { client.killPane("w1:p1") }.contains("pane close 'w1:p1'"))
        #expect(await lastCommand { client.renameSession("w1", to: "api") }
            .contains("workspace rename 'w1' 'api'"))
        #expect(await lastCommand { client.renameWindow("w1:t1", to: "logs") }
            .contains("tab rename 'w1:t1' 'logs'"))
        #expect(await lastCommand { client.newSession(named: "build") }
            .contains("workspace create --focus --label 'build'"))
        #expect(await lastCommand { client.newWindow(named: nil) }
            .contains("tab create --focus"))
        // Splits the FOCUSED pane, taken from the snapshot — `--current` would
        // mean the pane our own SSH channel runs in, which is none of them.
        #expect(await lastCommand { client.newPane() }
            .contains("pane split 'w1:p2' --direction right --focus"))
    }

    @Test("Focusing a pane tries agent focus, with the zoom-bounce fallback in the same exec")
    func selectPaneUsesAgentFocus() async throws {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let before = runner.commands.count

        client.selectPane("w1:p1")
        await settle()

        // `herdr pane focus` is directional-only in every released version.
        // `agent focus` is the fast path — but current herdr fails it
        // OUTRIGHT on a plain shell pane (the old errors-but-moves behavior
        // is gone), so the same exec carries the fallback: a zoom bounce,
        // which moves focus on --on and keeps it through --off.
        let sent = runner.commands[before]
        #expect(sent.contains("agent focus 'w1:p1' 2>/dev/null || {"))
        #expect(sent.contains("pane zoom --pane 'w1:p1' --on"))
        #expect(sent.contains("pane zoom --pane 'w1:p1' --off"))
        // --on before --off, or the bounce un-zooms panes that were zoomed.
        let on = try #require(sent.range(of: "--on"))
        let off = try #require(sent.range(of: "--off"))
        #expect(on.lowerBound < off.lowerBound)
    }

    // MARK: - Semantic keys

    @Test("Arrow keys ride pane send-keys with no trailing snapshot poll")
    func sendKeyIsQuiet() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let before = runner.commands.count

        client.sendKey("up", paneId: "w1:p1")
        await settle()

        let sent = Array(runner.commands[before...])
        #expect(sent.contains { $0.contains("pane send-keys 'w1:p1' 'up'") })
        // Keystroke-rate traffic must not drag a snapshot read behind every
        // keypress — a cursor move changes nothing the sheets care about.
        #expect(!sent.contains { $0.contains("api snapshot") })
    }

    @Test("Only a lone arrow sequence maps to a key name — both DECCKM variants")
    func arrowKeyNameMapping() {
        typealias S = SessionHub.ActiveSession
        #expect(S.arrowKeyName(Data([0x1B, 0x5B, 0x41])) == "up")      // ESC[A
        #expect(S.arrowKeyName(Data([0x1B, 0x4F, 0x42])) == "down")    // ESC OB
        #expect(S.arrowKeyName(Data([0x1B, 0x5B, 0x43])) == "right")
        #expect(S.arrowKeyName(Data([0x1B, 0x4F, 0x44])) == "left")
        // Not arrows: plain text, batched sequences, other CSI.
        #expect(S.arrowKeyName(Data("A".utf8)) == nil)
        #expect(S.arrowKeyName(Data([0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x41])) == nil)
        #expect(S.arrowKeyName(Data([0x1B, 0x5B, 0x48])) == nil)       // Home
    }

    // MARK: - Immersive zoom (the mosh renderer)

    @Test("Immersive mode: picking a pane zooms it — focus and fill in one command")
    func immersiveSelectPaneZooms() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        client.immersiveZoom = true
        let before = runner.commands.count

        client.selectPane("w1:p1")
        await settle()

        // `pane zoom --on` is an idempotent SET that also moves focus
        // (verified live: zooming B while A is zoomed transfers both), so
        // immersive mode never needs `agent focus` and its error noise.
        let sent = Array(runner.commands[before...])
        #expect(sent.contains { $0.contains("pane zoom --pane 'w1:p1' --on 2>/dev/null || true") })
        #expect(!sent.contains { $0.contains("agent focus") })
    }

    @Test("Immersive mode: a tab switch zooms whatever pane the next snapshot names")
    func immersiveWindowSwitchZoomsFocusedPane() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        client.immersiveZoom = true
        let before = runner.commands.count

        client.selectWindow("w1:t1")
        await settle()
        await settle()   // zoom rides the poll AFTER the focus command

        let sent = Array(runner.commands[before...])
        #expect(sent.contains { $0.contains("tab focus 'w1:t1'") })
        // The fixture's focused pane is w1:p2 — the zoom follows the
        // snapshot's answer, not a guess made before the switch landed.
        #expect(sent.contains { $0.contains("pane zoom --pane 'w1:p2' --on") })
    }

    @Test("Without immersive mode, zooms only ever come as a bounce — never left on")
    func nonImmersiveNeverLeavesZoomOn() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let before = runner.commands.count

        client.selectPane("w1:p1")
        client.selectWindow("w1:t1")
        await settle()
        await settle()

        let sent = Array(runner.commands[before...])
        // The immersive zoom-follow's shape (a lone --on, mosh renderer only)
        // must never appear on the SSH path — it restyles the desktop.
        #expect(!sent.contains { $0.contains("--on 2>/dev/null || true") })
        // The focus fallback's bounce is fine, but every --on must carry its
        // --off in the same exec.
        for command in sent where command.contains("--on") {
            #expect(command.contains("--off"), "a bounce without its --off leaves the desktop zoomed")
        }
    }

    @Test("Focusing a pane retargets the renderer without waiting for the round trip")
    func selectPaneRetargetsBeforeTheExec() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        // Wedge the focus command. If the retarget rode `agent focus` — or the
        // poll queued behind it — nothing below would ever fire, which is
        // exactly the delay this behaviour exists to remove.
        runner.setScript { $0.contains("agent focus") ? .hang : .reply(Self.twoWorkspaces) }

        final class Box: @unchecked Sendable { var seen: [String] = [] }
        let box = Box()
        client.onFocusedPaneChanged = { box.seen.append($0) }

        client.selectPane("w1:p1")

        // Synchronously, on the same turn as the tap.
        #expect(box.seen == ["w1:p1"])
        #expect(client.snapshot.activePaneId == "w1:p1")
    }

    @Test("Every mutation re-reads immediately instead of waiting for the tick")
    func mutationsRefresh() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let before = runner.commands.count

        client.selectSession("w2")
        await settle()

        #expect(runner.commands.count >= before + 2)
        #expect(runner.commands.last?.contains("api snapshot") == true)
    }

    @Test("Labels from the server are shell-quoted, not interpolated raw")
    func labelsAreQuoted() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let before = runner.commands.count

        client.renameSession("w1", to: "it's; rm -rf ~")
        await settle()

        let sent = runner.commands[before]
        let quotedLabel = #"'it'\''s; rm -rf ~'"#
        #expect(sent.contains("workspace rename 'w1' " + quotedLabel))
        // The `;` stays INSIDE the quoted argument: the only thing following
        // the label is our own exit-status trailer, so nothing the label
        // contains can start a second command.
        let afterLabel = (sent.components(separatedBy: quotedLabel).last ?? "")
            .trimmingCharacters(in: .whitespaces)
        #expect(afterLabel.hasPrefix("; echo \"\(HerdrControlClient.exitCodeMarker)"))
    }

    @Test("newPane with no known panes sends nothing rather than a bad target")
    func newPaneWithoutTarget() async {
        let runner = FakeRunner(response: "{}")
        let client = await started(runner)
        let before = runner.commands.count

        client.newPane()
        await settle()

        #expect(runner.commands.count == before)
    }

    // MARK: - Agent tasks

    private static let worktreeCreated = """
    {"id":"cli:worktree:create","result":{
      "type":"worktree_created",
      "workspace":{"workspace_id":"w4","label":"fix-scroll","focused":true},
      "root_pane":{"pane_id":"w4:p1","cwd":"/Users/dev/.herdr/worktrees/moshpit/fix-scroll"}}}
    """

    private func taskRequest(prompt: String = "") -> AgentTaskRequest {
        AgentTaskRequest(repoPath: "/Users/dev/code/moshpit", branch: "fix-scroll",
                         agent: "claude", prompt: prompt)
    }

    @Test("A task creates the worktree, then types the agent into its own pane")
    func startAgentTaskChain() async {
        let runner = FakeRunner(response: Self.worktreeCreated)
        let client = await started(runner)
        let before = runner.commands.count

        let error = await client.startAgentTask(taskRequest())
        #expect(error == nil)

        let sent = Array(runner.commands[before...])
        #expect(sent.contains { $0.contains("worktree create --cwd '/Users/dev/code/moshpit'") })
        #expect(sent.contains { $0.contains("--branch 'fix-scroll'") && $0.contains("--focus") })
        // The agent goes into the pane `worktree create` already put in the
        // checkout — `agent start` would land in the CLI's own directory.
        #expect(sent.contains { $0.contains("pane run 'w4:p1' 'claude'") })
        #expect(!sent.contains { $0.contains("agent start") })
    }

    @Test("An empty prompt sends nothing extra")
    func noPromptNoSend() async {
        let runner = FakeRunner(response: Self.worktreeCreated)
        let client = await started(runner)
        let before = runner.commands.count
        _ = await client.startAgentTask(taskRequest())
        #expect(!Array(runner.commands[before...]).contains { $0.contains("agent send") })
    }

    @Test("Invalid input never reaches the host")
    func validationShortCircuits() async {
        let runner = FakeRunner(response: Self.worktreeCreated)
        let client = await started(runner)
        let before = runner.commands.count

        var bad = taskRequest(); bad.branch = "two words"
        let error = await client.startAgentTask(bad)
        #expect(error != nil)
        #expect(runner.commands.count == before)   // nothing sent
    }

    /// herdr returns a structured error for the things that actually go wrong
    /// (branch already exists, dirty repo). Showing its own words beats
    /// inventing ours.
    @Test("herdr's own error text is what the user sees")
    func surfacesHerdrError() async {
        let runner = FakeRunner(response: Self.worktreeCreated)
        let client = await started(runner)
        runner.setResponse("""
        {"error":{"code":"worktree_create_failed","message":"branch 'fix-scroll' already exists"},"id":"cli:worktree:create"}
        """)
        let error = await client.startAgentTask(taskRequest())
        #expect(error == "branch 'fix-scroll' already exists")
    }

    private static let panesInRepos = """
    {"id":"x","result":{"snapshot":{
      "workspaces":[{"workspace_id":"w1","label":"~","focused":true}],
      "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"focused":true,"pane_count":2}],
      "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","foreground_cwd":"/Users/dev/code/moshpit/Moshpit"},
               {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","cwd":"/Users/dev/code/other"}],
      "layouts":[],"focused_pane_id":"w1:p1"}}}
    """

    /// Two commands ON PURPOSE: the pane resolve is small and reliable, the
    /// `$HOME` walk is neither — fused into one exec (the first version), a
    /// hung walk took the pane repos down with it and the form offered
    /// nothing but "Other…". (Seen for real against the high-RTT host.)
    @Test("Repo discovery: panes' own repos first, host scan appended")
    func gitReposFromPanesAndScan() async {
        let runner = FakeRunner(response: Self.panesInRepos)
        let client = await started(runner)
        let before = runner.commands.count

        runner.setScript { command in
            if command.hasPrefix("for d in") {
                return .reply("/Users/dev/code/moshpit\n/Users/dev/code/other\n")
            }
            return .reply("/Users/dev/code/scanned\n/Users/dev/code/moshpit\n")
        }
        let repos = await client.gitRepos()

        #expect(runner.commands.count == before + 2)
        let resolve = runner.commands.first { $0.hasPrefix("for d in") } ?? ""
        #expect(resolve.contains("rev-parse --show-toplevel"))
        let scan = runner.commands.first { $0.contains("-name .git -print") } ?? ""
        // Follows symlinks — "~/code is a symlink onto the big disk" is a
        // normal dev-host layout and a plain find walks right past it.
        #expect(scan.hasPrefix("find -L"))
        // Hidden directories are pruned or the list fills with .vim/.oh-my-zsh;
        // media libraries are pruned or an iCloud-backed home stalls the walk.
        #expect(scan.contains("! -name .git -prune"))
        #expect(scan.contains("-name Library"))
        #expect(scan.contains("-name Pictures"))
        // Pane repos lead (that's "resume what I was doing"), scan fills in,
        // duplicates collapse.
        #expect(repos == ["/Users/dev/code/moshpit", "/Users/dev/code/other",
                          "/Users/dev/code/scanned"])
    }

    @Test("With no panes to go on, the form still gets the scan — one command")
    func gitReposWithoutPanes() async {
        let runner = FakeRunner(response: "{}")
        let client = await started(runner)
        let before = runner.commands.count
        runner.setResponse("/Users/dev/code/moshpit\n")
        let repos = await client.gitRepos()
        #expect(repos == ["/Users/dev/code/moshpit"])
        #expect(runner.commands.count == before + 1)
    }

    /// The regression this split exists for: the walk hangs (huge or
    /// iCloud-backed home, dying link) and the form must still get the pane
    /// repos — promptly, not after some transport timeout.
    @Test("A hung host scan misses its budget; pane repos arrive anyway")
    func scanBudgetDropsTheSlowHalf() async {
        let runner = FakeRunner(response: Self.panesInRepos)
        let client = await started(runner)
        runner.setScript { command in
            command.hasPrefix("for d in") ? .reply("/Users/dev/code/moshpit\n") : .hang
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let repos = await client.gitRepos(scanBudget: .milliseconds(120))
        #expect(repos == ["/Users/dev/code/moshpit"])
        #expect(clock.now - startedAt < .seconds(5))
    }

    @Test("A dead link on the pane resolve falls back to the raw cwd guesses")
    func paneResolveFailureFallsBackToGuesses() async {
        let runner = FakeRunner(response: Self.panesInRepos)
        let client = await started(runner)
        runner.setScript { command in
            command.hasPrefix("for d in") ? .fail : .reply("")
        }
        let repos = await client.gitRepos()
        // Raw cwds, sorted — the server validates the path at worktree-create
        // time, and a tappable guess beats an empty menu on a bad link.
        #expect(repos == ["/Users/dev/code/moshpit/Moshpit", "/Users/dev/code/other"])
    }

    @Test("Agent names come from herdr's own manifest list")
    func agentNamesFromManifests() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        runner.setResponse("""
        [{"agent":"pi","active_version":"1"},{"agent":"claude","active_version":"2"},{"agent":"codex"}]
        """)
        let names = await client.agentNames()
        #expect(names == ["claude", "codex", "pi"])
    }

    // MARK: - Worktree removal

    @Test("Only a workspace herdr made from a repo counts as a worktree")
    func worktreeMarking() async {
        let runner = FakeRunner(response: """
        {"result":{"snapshot":{
          "workspaces":[
            {"workspace_id":"w1","label":"~","focused":true},
            {"workspace_id":"w4","label":"fix-scroll",
             "worktree":{"is_linked_worktree":true,"repo_name":"moshpit",
                         "checkout_path":"/Users/x/.herdr/worktrees/moshpit/fix-scroll"}}],
          "tabs":[],"panes":[],"layouts":[]}}}
        """)
        let client = await started(runner)
        #expect(client.worktreeRepo(for: "w4") == "moshpit")
        #expect(client.worktreeRepo(for: "w1") == nil)
    }

    /// The safety property this whole two-step flow exists for: the first
    /// attempt never forces, so a checkout with uncommitted work survives it.
    @Test("A dirty checkout comes back as needsForce, never silently forced")
    func dirtyWorktreeNeedsForce() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        runner.setResponse("""
        {"error":{"code":"dirty_worktree_requires_force","message":"fatal: contains modified or untracked files, use --force to delete it"},"id":"cli:worktree:remove"}
        """)
        let before = runner.commands.count
        let outcome = await client.removeWorktree(sessionId: "w4")
        #expect(outcome == .needsForce)
        #expect(runner.commands[before].contains("worktree remove --workspace 'w4'"))
        #expect(!runner.commands[before].contains("--force"))
    }

    @Test("Forcing is explicit and only happens when asked for")
    func forcedRemoval() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        runner.setResponse("""
        {"id":"cli:worktree:remove","result":{"type":"worktree_removed","forced":true,"workspace_id":"w4"}}
        """)
        let before = runner.commands.count
        let outcome = await client.removeWorktree(sessionId: "w4", force: true)
        #expect(outcome == .removed)
        #expect(runner.commands[before].contains("--force"))
    }

    @Test("Any other failure carries herdr's own message")
    func removalFailureMessage() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        runner.setResponse("""
        {"error":{"code":"not_found","message":"workspace w9 not found"},"id":"cli:worktree:remove"}
        """)
        #expect(await client.removeWorktree(sessionId: "w9") == .failed("workspace w9 not found"))
    }

    // MARK: - Lifecycle

    /// Explicitly releases replies, including after cancellation, to model
    /// slow SSH exec futures without relying on wall-clock sleeps or a host.
    final class HeldSnapshotRunner: HerdrCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var inFlight = 0
        private var peak = 0
        private var replies: [Int: CheckedContinuation<String, Error>] = [:]
        var count: Int { lock.withLock { calls } }
        var maximumInFlight: Int { lock.withLock { peak } }

        func run(_ command: String) async throws -> String {
            guard command.contains("api snapshot") else { return "__moshpit_rc=0" }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    let index = calls
                    calls += 1
                    inFlight += 1
                    peak = max(peak, inFlight)
                    replies[index] = continuation
                }
            }
        }

        func complete(_ index: Int, with result: Result<String, Error>) {
            let continuation = lock.withLock {
                let continuation = replies.removeValue(forKey: index)
                if continuation != nil { inFlight -= 1 }
                return continuation
            }
            continuation?.resume(with: result)
        }

        func finishAll() {
            let pending = lock.withLock {
                let pending = Array(replies.values)
                replies.removeAll()
                inFlight = 0
                return pending
            }
            for reply in pending { reply.resume(throwing: SSHError.sessionClosed) }
        }
    }

    @Test("Slow snapshots coalesce push bursts into one trailing refresh and retain awaited completion")
    func slowSnapshotsCoalesce() async {
        let runner = HeldSnapshotRunner()
        let client = HerdrControlClient(runner: runner)
        defer { client.stop(); runner.finishAll() }
        var firstFinished = false
        let first = Task { await client.pollNowForTesting(); firstFinished = true }
        await settle(until: { runner.count == 1 })

        for _ in 0..<30 { client.quicken() }
        var trailingFinished = false
        let trailing = Task { await client.pollNowForTesting(); trailingFinished = true }
        await settle()
        #expect(runner.count == 1)
        #expect(runner.maximumInFlight == 1)
        #expect(!firstFinished && !trailingFinished)

        runner.complete(0, with: .success(Self.twoWorkspaces))
        await settle(until: { runner.count == 2 })
        #expect(firstFinished, "the first caller need not wait for a newer requested refresh")
        #expect(!trailingFinished, "a refresh requested during a read must wait for its trailing read")
        let updated = Self.twoWorkspaces.replacingOccurrences(of: #""focused_pane_id":"w1:p2""#,
                                                              with: #""focused_pane_id":"w1:p1""#)
        runner.complete(1, with: .success(updated))
        await first.value
        await trailing.value
        await settle()
        #expect(runner.count == 2)
        #expect(runner.maximumInFlight == 1)
        #expect(client.snapshot.activePaneId == "w1:p1")
    }

    @Test("Events during the trailing read get one later read without overlapping SSH channels")
    func eventsDuringTrailingReadAreNotLost() async {
        let runner = HeldSnapshotRunner()
        let client = HerdrControlClient(runner: runner)
        defer { client.stop(); runner.finishAll() }
        client.quicken()
        await settle(until: { runner.count == 1 })
        client.quicken()
        await settle()
        runner.complete(0, with: .success(Self.twoWorkspaces))
        await settle(until: { runner.count == 2 })
        for _ in 0..<10 { client.quicken() }
        await settle()
        #expect(runner.count == 2)
        runner.complete(1, with: .failure(SSHError.sessionClosed))
        await settle(until: { runner.count == 3 })
        #expect(client.snapshot.activePaneId == "w1:p2", "a failed read keeps the last tree")
        runner.complete(2, with: .success(Self.twoWorkspaces))
        await settle()
        #expect(runner.count == 3)
        #expect(runner.maximumInFlight == 1)
    }

    @Test("Stopping releases refresh waiters and rejects a late old reply after restart")
    func stoppedSnapshotCannotOverwriteRestart() async {
        let runner = HeldSnapshotRunner()
        let client = HerdrControlClient(runner: runner)
        defer { client.stop(); runner.finishAll() }
        var firstFinished = false
        var trailingFinished = false
        var focused: [String] = []
        client.onFocusedPaneChanged = { focused.append($0) }
        let first = Task { await client.pollNowForTesting(); firstFinished = true }
        await settle(until: { runner.count == 1 })
        let trailing = Task { await client.pollNowForTesting(); trailingFinished = true }
        await settle()

        client.stop()
        await settle(until: { firstFinished && trailingFinished })
        #expect(firstFinished && trailingFinished, "stop must not wait for an uncooperative SSH future")
        client.quicken()
        client.refresh()
        await settle()
        #expect(runner.count == 1)
        #expect(!client.isRefreshing)
        client.start()
        await settle(until: { runner.count == 2 })
        let updated = Self.twoWorkspaces.replacingOccurrences(of: #""focused_pane_id":"w1:p2""#,
                                                              with: #""focused_pane_id":"w1:p1""#)
        runner.complete(1, with: .success(updated))
        await settle(until: { client.snapshot.activePaneId == "w1:p1" })
        let successfulPoll = client.lastSuccessfulPoll
        runner.complete(0, with: .success(Self.twoWorkspaces))
        await first.value
        await trailing.value
        await settle()
        #expect(client.snapshot.activePaneId == "w1:p1")
        #expect(focused == ["w1:p1"])
        #expect(client.lastSuccessfulPoll == successfulPoll)
        #expect(runner.count == 2)
    }

    @Test("stop() ends the polling")
    func stopEndsPolling() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        client.stop()
        let after = runner.commands.count
        await settle(20)
        #expect(runner.commands.count == after)
    }

    @Test("start() twice doesn't double up the poller")
    func startIsIdempotent() async {
        let runner = FakeRunner(response: Self.twoWorkspaces)
        let client = await started(runner)
        let after = runner.commands.count
        client.start()
        await settle()
        // A second start must not add a second in-flight poll.
        #expect(runner.commands.count == after)
    }
}
