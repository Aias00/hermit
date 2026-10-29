import AVFoundation
import Foundation
import Testing
@testable import Moshpit

/// The Whisper engine's own contract, against a scripted transcriber — no
/// model, no Neural Engine, no network. What's pinned here is the behaviour
/// that differs from the streaming engines: audio is buffered and re-read,
/// previews are advisory, and the pass that produces the final transcript is
/// the one in `finishAudio()`.
@Suite("Whisper dictation engine")
struct WhisperDictationEngineTests {

    /// Holds work even after cancellation, like a CoreML operation already
    /// running. Releasing before entry is also safe for test failure cleanup.
    actor WorkBarrier {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        private(set) var followingCalls = 0

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { self.continuation = continuation }
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }

        func following() { followingCalls += 1 }
    }

    actor SuspendedTranscriber: WhisperTranscribing {
        let barrier = WorkBarrier()
        private(set) var calls = 0
        private(set) var cancellationObserved = false

        func warmUp(variant: String) async throws {}

        func transcribe(samples: [Float], language: String?, variant: String) async throws -> String {
            calls += 1
            let call = calls
            if call == 1 {
                await withTaskCancellationHandler {
                    await barrier.wait()
                } onCancel: {
                    Task { await self.observeCancellation() }
                }
            }
            return call == 1 ? "preview" : "final"
        }

        private func observeCancellation() { cancellationObserved = true }
        func release() async { await barrier.release() }
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("A cancelled queued transcription never enters the model")
    func gateRemovesCancelledWaiter() async throws {
        let gate = WhisperTranscriptionGate()
        let barrier = WorkBarrier()
        let active = Task {
            try await gate.withPermit {
                await barrier.wait()
                return 1
            }
        }
        #expect(await eventually { await barrier.entered })
        let queued = Task {
            try await gate.withPermit {
                await barrier.following()
                return 2
            }
        }
        #expect(await eventually { await gate.waitingCount == 1 })
        queued.cancel()
        // Removal must not depend on the active operation returning.
        #expect(await eventually { await gate.waitingCount == 0 })
        await barrier.release()
        #expect(try await active.value == 1)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await barrier.followingCalls == 0)
    }

    @Test("Cancelling active decoding does not let a retry overlap its model use")
    func gateKeepsCancelledActivePermitUntilReturn() async throws {
        let gate = WhisperTranscriptionGate()
        let barrier = WorkBarrier()
        let active = Task {
            try await gate.withPermit {
                await barrier.wait()
                return 1
            }
        }
        #expect(await eventually { await barrier.entered })
        active.cancel()
        let retry = Task {
            try await gate.withPermit {
                await barrier.following()
                return 2
            }
        }
        #expect(await eventually { await gate.waitingCount == 1 })
        #expect(await barrier.followingCalls == 0)
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await active.value }
        #expect(try await retry.value == 2)
        #expect(await barrier.followingCalls == 1)
    }

    @Test("Final decoding waits for a cancelled preview to actually return")
    func finalWaitsForUncooperativePreview() async throws {
        let store = SuspendedTranscriber()
        let engine = WhisperDictationEngine(store: store, variant: "test", language: "zh", label: "test")
        try await engine.start()
        engine.append(try buffer(frames: 48_000))
        #expect(await eventually { await store.calls == 1 })
        let finish = Task { await engine.finishAudio() }
        #expect(await eventually { await store.cancellationObserved })
        #expect(await store.calls == 1)
        await store.release()
        await finish.value
        var updates: [DictationUpdate] = []
        for try await update in engine.updates { updates.append(update) }
        #expect(await store.calls == 2)
        #expect(updates == [DictationUpdate(finalizedText: "final", volatileText: "")])
    }

    @Test("Cancel drops late audio and an in-flight final result")
    func cancelDropsLateBuffersAndFinal() async throws {
        let store = SuspendedTranscriber()
        let engine = WhisperDictationEngine(store: store, variant: "test", language: "zh", label: "test")
        try await engine.start()
        engine.append(try buffer(frames: 16_000))
        let finish = Task { await engine.finishAudio() }
        #expect(await eventually { await store.calls == 1 })
        engine.cancel()
        for _ in 0 ..< 30 { engine.append(try buffer(frames: 16_000)) }
        // The duration-derived budget also proves late buffers were not kept.
        #expect(engine.finalizeTimeout == .seconds(20))
        await store.release()
        await finish.value
        var updates: [DictationUpdate] = []
        for try await update in engine.updates { updates.append(update) }
        #expect(updates.isEmpty)
        #expect(await store.calls == 1)
    }

    /// Records what it was asked to transcribe and replays scripted answers.
    actor ScriptedTranscriber: WhisperTranscribing {
        /// Answers handed out in order; the last one repeats once exhausted.
        private var answers: [String]
        private var index = 0
        private(set) var warmUps: [String] = []
        /// Sample counts each `transcribe` call saw, in order.
        private(set) var sampleCounts: [Int] = []
        private(set) var languages: [String?] = []
        private var warmUpError: Error?
        /// Delay before each answer, to keep a preview in flight.
        private var latency: Duration = .zero

        init(answers: [String], warmUpError: Error? = nil) {
            self.answers = answers
            self.warmUpError = warmUpError
        }

        func setLatency(_ value: Duration) { latency = value }

        func warmUp(variant: String) async throws {
            warmUps.append(variant)
            if let warmUpError { throw warmUpError }
        }

        func transcribe(samples: [Float], language: String?, variant _: String) async throws -> String {
            sampleCounts.append(samples.count)
            languages.append(language)
            if latency != .zero { try? await Task.sleep(for: latency) }
            guard !answers.isEmpty else { return "" }
            let answer = answers[min(index, answers.count - 1)]
            index += 1
            return answer
        }
    }

    /// A buffer of `frames` at 16 kHz mono, filled with quiet noise so it
    /// isn't optimized away as empty.
    private func buffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0 ..< Int(frames) { channel[i] = Float(i % 32) / 1000 }
        }
        return buffer
    }

    private func makeEngine(_ store: ScriptedTranscriber,
                            language: String? = "zh") -> WhisperDictationEngine {
        WhisperDictationEngine(store: store, variant: "openai_whisper-small",
                               language: language, label: "Small · Chinese")
    }

    @Test("Final pass reads every sample appended, and lands as finalized text")
    func finalPassSeesEverything() async throws {
        let store = ScriptedTranscriber(answers: ["把这个 commit rebase 到 main"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()

        // Three seconds of audio in three chunks.
        for _ in 0 ..< 3 { engine.append(try buffer(frames: 16_000)) }
        await engine.finishAudio()

        var updates: [DictationUpdate] = []
        for try await update in engine.updates { updates.append(update) }

        let final = try #require(updates.last)
        #expect(final.finalizedText == "把这个 commit rebase 到 main")
        #expect(final.volatileText.isEmpty)
        // The pass that produced it saw all 48 000 samples, not just the last
        // chunk — that whole-utterance context is the entire point.
        let counts = await store.sampleCounts
        #expect(counts.last == 48_000)
    }

    @Test("The configured language reaches the model")
    func languagePassedThrough() async throws {
        let store = ScriptedTranscriber(answers: ["ok"])
        let engine = makeEngine(store, language: "zh")
        try await engine.prepare { _ in }
        try await engine.start()
        engine.append(try buffer(frames: 16_000))
        await engine.finishAudio()
        for try await _ in engine.updates {}

        let languages = await store.languages
        #expect(languages.allSatisfy { $0 == "zh" })
    }

    @Test("Auto-detect sends nil rather than a guessed language")
    func autoDetectSendsNil() async throws {
        let store = ScriptedTranscriber(answers: ["ok"])
        let engine = makeEngine(store, language: nil)
        try await engine.prepare { _ in }
        try await engine.start()
        engine.append(try buffer(frames: 16_000))
        await engine.finishAudio()
        for try await _ in engine.updates {}

        let languages = await store.languages
        #expect(languages.allSatisfy { $0 == nil })
    }

    @Test("Buffers arriving in a foreign format are resampled, not dropped")
    func resamplesForeignFormat() async throws {
        let store = ScriptedTranscriber(answers: ["ok"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()

        // 48 kHz stereo — what an actual iPhone mic tap hands over.
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        input.frameLength = 48_000
        for channel in 0 ..< 2 {
            if let data = input.floatChannelData?[channel] {
                for i in 0 ..< 48_000 { data[i] = Float(i % 64) / 1000 }
            }
        }
        engine.append(input)
        await engine.finishAudio()
        for try await _ in engine.updates {}

        // One second in at 48 kHz stereo must arrive as ~one second of 16 kHz
        // mono — a third of the frames, not all of them and not none.
        let counts = await store.sampleCounts
        let seen = try #require(counts.last)
        #expect(seen > 15_000 && seen < 17_000)
    }

    @Test("Too little audio is never sent to the model")
    func silenceFloor() async throws {
        let store = ScriptedTranscriber(answers: ["hallucinated phrase"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()
        // 0.2 s — below the floor that keeps Whisper from inventing text.
        engine.append(try buffer(frames: 3_200))
        await engine.finishAudio()

        var updates: [DictationUpdate] = []
        for try await update in engine.updates { updates.append(update) }

        #expect(updates.last?.finalizedText.isEmpty == true)
    }

    @Test("A missing model reports as the setup problem it is")
    func missingModelFailure() async throws {
        let store = ScriptedTranscriber(
            answers: [], warmUpError: WhisperModelFailure.notInstalled("Small"))
        let engine = makeEngine(store)

        await #expect(throws: DictationFailure.noWhisperModel) {
            try await engine.prepare { _ in }
        }
    }

    @Test("prepare reports loading, never downloading")
    func prepareReportsLoading() async throws {
        let store = ScriptedTranscriber(answers: ["ok"])
        let engine = makeEngine(store)
        // The mic key must never kick off a several-hundred-megabyte
        // transfer; downloads belong to Settings alone.
        nonisolated(unsafe) var steps: [DictationPreparation] = []
        try await engine.prepare { steps.append($0) }

        #expect(steps == [.loading])
        let warmUps = await store.warmUps
        #expect(warmUps == ["openai_whisper-small"])
    }

    @Test("Finalize budget scales with how long the recording is")
    func finalizeBudgetScales() async throws {
        let store = ScriptedTranscriber(answers: ["ok"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()

        // Empty: the floor, which has to cover model load on a cold start.
        #expect(engine.finalizeTimeout >= .seconds(20))

        // 60 s of audio needs more than the 5 s a streaming engine gets, or
        // the controller would time out and discard the whole transcript.
        for _ in 0 ..< 60 { engine.append(try buffer(frames: 16_000)) }
        #expect(engine.finalizeTimeout >= .seconds(120))

        engine.cancel()
    }

    @Test("Cancel stops the session without emitting a transcript")
    func cancelIsSilent() async throws {
        let store = ScriptedTranscriber(answers: ["should not appear"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()
        engine.append(try buffer(frames: 16_000))
        engine.cancel()

        var updates: [DictationUpdate] = []
        for try await update in engine.updates { updates.append(update) }
        #expect(updates.isEmpty)
    }

    @Test("Live preview publishes a hypothesis while listening")
    func previewPublishesVolatileText() async throws {
        let store = ScriptedTranscriber(answers: ["部署 staging", "部署 staging 分支"])
        let engine = makeEngine(store)
        try await engine.prepare { _ in }
        try await engine.start()
        // Over the 2 s preview floor so the loop has something to chew on.
        for _ in 0 ..< 3 { engine.append(try buffer(frames: 16_000)) }

        // Preview arrives as volatile — replaceable, and never mistaken for
        // committed text the user could insert as final.
        let firstPreview = await withTaskGroup(of: DictationUpdate?.self) { group in
            group.addTask {
                do {
                    for try await update in engine.updates where !update.volatileText.isEmpty {
                        return update
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            // `next()` wraps the child's optional: flatten so the timer's nil
            // and an empty group both read as "no preview".
            let first = await group.next()
            group.cancelAll()
            return first?.flatMap { $0 }
        }

        let preview = try #require(firstPreview)
        #expect(preview.finalizedText.isEmpty)
        #expect(preview.volatileText == "部署 staging")
        engine.cancel()
    }
}
