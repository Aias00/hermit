import AVFoundation
import Foundation
import Testing
@testable import Moshpit

/// The dictation state machine, held still with a scripted engine and a fake
/// mic — permission denial, model download, live volatile/final assembly,
/// insert vs. cancel, interruption, and engine failure, none of which need
/// audio hardware to be true.
@Suite("Voice dictation controller")
@MainActor
struct VoiceDictationControllerTests {

    // MARK: Fakes

    final class FakeEngine: DictationEngine {
        let updates: AsyncThrowingStream<DictationUpdate, Error>
        let continuation: AsyncThrowingStream<DictationUpdate, Error>.Continuation

        var prepareError: Error?
        /// Progress values `prepare` reports before returning.
        var downloadProgress: [Double] = []
        /// While true, `prepare` idles after reporting progress — lets a test
        /// observe the `.downloadingModel` phase instead of racing past it.
        var holdPrepare = false
        /// Report a `.loading` step after any download progress.
        var reportsLoading = false
        var label = "Fake · Test"
        var finalizeTimeout: Duration = .seconds(5)
        var finalUpdate: DictationUpdate?
        var finishError: Error?
        var leaveUpdatesOpenOnFinish = false
        var holdFinish = false
        var finishContinuation: CheckedContinuation<Void, Never>?

        private(set) var started = false
        private(set) var appended = 0
        private(set) var firstSamples: [Float] = []
        private(set) var finishAudioCalled = false
        private(set) var cancelCalled = false

        init() {
            (updates, continuation) = AsyncThrowingStream.makeStream()
        }

        func prepare(onProgress: @escaping @Sendable (DictationPreparation) -> Void) async throws {
            if let prepareError { throw prepareError }
            for value in downloadProgress { onProgress(.downloading(progress: value)) }
            if reportsLoading { onProgress(.loading) }
            while holdPrepare {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func start() async throws { started = true }
        func append(_ buffer: AVAudioPCMBuffer) {
            appended += 1
            if buffer.frameLength > 0, let sample = buffer.floatChannelData?[0][0] { firstSamples.append(sample) }
        }
        func finishAudio() async {
            finishAudioCalled = true
            if holdFinish {
                await withCheckedContinuation { finishContinuation = $0 }
            }
            if let finalUpdate { continuation.yield(finalUpdate) }
            if let finishError { continuation.finish(throwing: finishError) }
            else if !leaveUpdatesOpenOnFinish { continuation.finish() }
        }

        func cancel() {
            cancelCalled = true
            continuation.finish()
        }
    }

    final class FakeAudioSource: DictationAudioSource {
        var permission = true
        var holdPermission = false
        var startError: Error?
        private(set) var started = false
        private(set) var stopped = false
        private(set) var permissionRequests = 0
        private(set) var startCalls = 0
        var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onLevel: (@Sendable (Float) -> Void)?
        var onInterruption: (@Sendable () -> Void)?

        func requestPermission() async -> Bool {
            permissionRequests += 1
            while holdPermission { try? await Task.sleep(for: .milliseconds(5)) }
            return permission
        }

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                   onLevel: @escaping @Sendable (Float) -> Void,
                   onInterruption: @escaping @Sendable () -> Void) throws {
            startCalls += 1
            if let startError { throw startError }
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            self.onInterruption = onInterruption
            started = true
        }

        func stop() { stopped = true }
    }

    private func makeController(engine: FakeEngine,
                                audio: FakeAudioSource) -> VoiceDictationController {
        VoiceDictationController(engineFactory: { _, _ in [engine] }, audioSource: audio)
    }

    private func makeController(engines: [FakeEngine],
                                audio: FakeAudioSource) -> VoiceDictationController {
        VoiceDictationController(engineFactory: { _, _ in engines }, audioSource: audio)
    }

    /// Main-actor-friendly poll: updates arrive via tasks the controller
    /// spawns, so tests wait for the state to settle instead of assuming
    /// scheduling order.
    private func waitUntil(_ condition: @autoclosure () -> Bool,
                           timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func pcm(frames: AVAudioFrameCount = 160, rate: Double = 16_000,
                     channels: AVAudioChannelCount = 1, value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) { buffer.floatChannelData?[channel].initialize(repeating: value, count: Int(frames)) }
        return buffer
    }

    @Test("Recording cache copies tap-owned PCM, releases it, and rejects callbacks after sealing")
    func recordingCacheCopiesAndSeals() throws {
        let cache = DictationRecordingCache()
        let input = try pcm()
        var deliveries = 0
        cache.capture(input) { deliveries += 1 }
        input.floatChannelData?[0][0] = 0.9
        cache.seal()
        #expect(cache.buffer(at: 0)?.floatChannelData?[0][0] == 0.25)
        #expect(cache.status.count == 1 && cache.status.bytes == 640)
        cache.capture(input) { deliveries += 1 }
        #expect(deliveries == 1 && cache.status.count == 1)
        weak var retained = cache.buffer(at: 0)
        cache.clear()
        #expect(retained == nil && cache.status.bytes == 0)
        cache.capture(input) { deliveries += 1 }
        #expect(cache.status.count == 0 && deliveries == 1)
    }

    @Test("Crossing the 120-second bound drops the entire retry cache but continues live recognition")
    func recordingDurationLimitDropsEverything() throws {
        let cache = DictationRecordingCache()
        var deliveries = 0
        cache.capture(try pcm()) { deliveries += 1 }
        cache.capture(try pcm(frames: 120_000, rate: 1_000)) { deliveries += 1 }
        #expect(cache.status.unavailable == .limitExceeded)
        #expect(cache.status.count == 0 && cache.status.bytes == 0)
        cache.capture(try pcm()) { deliveries += 1 }
        cache.seal()
        #expect(deliveries == 3 && cache.buffer(at: 0) == nil)
    }

    @Test("Crossing 32 MiB drops all cached audio even when duration is under 120 seconds")
    func recordingByteLimitDropsEverything() throws {
        let cache = DictationRecordingCache()
        cache.capture(try pcm()) {}
        // Standard-format construction supports mono/stereo without an
        // explicit channel layout. Stereo Float32 crosses 32 MiB in 87.4 s.
        let large = try pcm(frames: 4_194_305, rate: 48_000, channels: 2)
        cache.capture(large) {}
        cache.seal()
        #expect(cache.status.unavailable == .limitExceeded)
        #expect(cache.status.count == 0 && cache.status.bytes == 0)
        #expect(cache.buffer(at: 0) == nil)
    }

    @Test("Review and language retry use copied audio and new engines without reopening the microphone")
    func reviewRetryUsesRecordingAndPreservesOriginal() async throws {
        let first = FakeEngine()
        first.finalUpdate = .init(finalizedText: "original words", volatileText: "")
        let second = FakeEngine()
        second.finalUpdate = .init(finalizedText: "new English words", volatileText: "")
        let audio = FakeAudioSource()
        var requests: [DictationRequest] = []
        let controller = VoiceDictationController(engineFactory: { request, _ in
            requests.append(request)
            return [requests.count == 1 ? first : second]
        }, audioSource: audio)
        await controller.start(DictationRequest())
        let input = try pcm()
        audio.onBuffer?(input)
        input.floatChannelData?[0][0] = 0.9
        await controller.stopForReview()
        #expect(controller.phase == .ready && controller.canRetryRecording)
        #expect(controller.originalTranscript == "original words")
        #expect(audio.stopped && audio.permissionRequests == 1 && audio.startCalls == 1)
        await controller.retry(DictationRequest(appleLocaleId: "en-US"))
        #expect(requests.map(\.appleLocaleId) == ["", "en-US"])
        #expect(second.started && second.firstSamples == [0.25])
        #expect(audio.permissionRequests == 1 && audio.startCalls == 1)
        #expect(controller.transcript == "new English words" && controller.originalTranscript == "original words")
        #expect(controller.currentRequest?.appleLocaleId == "en-US")
        controller.restoreOriginalTranscript()
        #expect(controller.transcript == "original words" && controller.currentRequest?.appleLocaleId == "")
        #expect(await controller.finish() == "original words")
        #expect(controller.phase == .idle && !controller.canRetryRecording && controller.originalTranscript.isEmpty)
        // A retained tap callback cannot repopulate the cache after insertion.
        audio.onBuffer?(input)
        #expect(!controller.canRetryRecording && first.appended == 1)
    }

    @Test("Failed and empty retries preserve the prior text and cannot overwrite the original")
    func failedAndEmptyRetriesPreserveText() async throws {
        let first = FakeEngine()
        first.label = "Original locale"
        first.finalUpdate = .init(finalizedText: "first result", volatileText: "")
        let preparationFailed = FakeEngine()
        preparationFailed.prepareError = DictationFailure.unsupportedLanguage("Unavailable locale")
        let failed = FakeEngine()
        failed.label = "Failed locale"
        failed.finalUpdate = .init(finalizedText: "must not replace", volatileText: "")
        failed.finishError = DictationFailure.engine("failure")
        let empty = FakeEngine()
        let success = FakeEngine()
        success.finalUpdate = .init(finalizedText: "successful retry", volatileText: "")
        var remaining = [first, preparationFailed, failed, empty, success]
        let audio = FakeAudioSource()
        let controller = VoiceDictationController(engineFactory: { _, _ in [remaining.removeFirst()] }, audioSource: audio)
        await controller.start(DictationRequest())
        audio.onBuffer?(try pcm())
        await controller.stopForReview()
        await controller.retry(DictationRequest(appleLocaleId: "unavailable"))
        #expect(controller.phase == .failed(.unsupportedLanguage("Unavailable locale")))
        #expect(controller.transcript == "first result" && controller.currentRequest?.appleLocaleId == "")
        #expect(controller.engineLabel == "Original locale" && controller.canRetryRecording)
        await controller.retry(DictationRequest(appleLocaleId: "en-US"))
        #expect(controller.phase == .failed(.finalizationFailed))
        #expect(controller.transcript == "first result" && controller.canRetryRecording)
        #expect(controller.currentRequest?.appleLocaleId == "")
        #expect(controller.engineLabel == "Original locale")
        await controller.retry(DictationRequest(appleLocaleId: "zh-CN"))
        #expect(controller.transcript == "first result" && controller.originalTranscript == "first result")
        #expect(controller.currentRequest?.appleLocaleId == "")
        if case .failed = controller.phase {} else { Issue.record("An empty retry must be explicit, not silently accepted") }
        await controller.retry(DictationRequest())
        #expect(controller.transcript == "successful retry" && controller.originalTranscript == "first result")
        controller.restoreOriginalTranscript()
        #expect(controller.transcript == "first result")
        controller.cancel()
    }

    @Test("Cancelling retry preparation clears the session and late preparation cannot open the microphone")
    func cancelRetryPreparation() async throws {
        let first = FakeEngine()
        first.finalUpdate = .init(finalizedText: "original", volatileText: "")
        let retry = FakeEngine()
        retry.holdPrepare = true
        retry.reportsLoading = true
        var attempts = 0
        let audio = FakeAudioSource()
        let controller = VoiceDictationController(engineFactory: { _, _ in
            defer { attempts += 1 }; return [attempts == 0 ? first : retry]
        }, audioSource: audio)
        await controller.start(DictationRequest())
        let input = try pcm()
        audio.onBuffer?(input)
        await controller.stopForReview()
        let replay = Task { await controller.retry(DictationRequest(appleLocaleId: "en-US")) }
        #expect(await waitUntil(controller.phase == .loadingModel))
        #expect(controller.isReplaying && !controller.canRetryRecording)
        controller.restoreOriginalTranscript()
        #expect(controller.phase == .loadingModel, "Restore is ignored while a retry is running")
        controller.cancel()
        audio.onBuffer?(input)
        retry.holdPrepare = false
        await replay.value
        #expect(!retry.started && retry.cancelCalled)
        #expect(controller.phase == .idle && controller.transcript.isEmpty && controller.originalTranscript.isEmpty)
        #expect(!controller.canRetryRecording && !controller.isReplaying && first.appended == 1)
        #expect(audio.permissionRequests == 1 && audio.startCalls == 1)
    }

    @Test("Retry timeout and a late final result cannot corrupt the next retry")
    func retryTimeoutAndLateResultIsolation() async throws {
        let first = FakeEngine()
        first.finalUpdate = .init(finalizedText: "original", volatileText: "")
        let delayed = FakeEngine()
        delayed.holdFinish = true
        delayed.finalUpdate = .init(finalizedText: "late result", volatileText: "")
        let next = FakeEngine()
        next.finalUpdate = .init(finalizedText: "new result", volatileText: "")
        var remaining = [first, delayed, next]
        let audio = FakeAudioSource()
        let controller = VoiceDictationController(engineFactory: { _, _ in [remaining.removeFirst()] },
            audioSource: audio, retryTimeoutOverride: .milliseconds(30))
        await controller.start(DictationRequest())
        audio.onBuffer?(try pcm())
        await controller.stopForReview()
        await controller.retry(DictationRequest(appleLocaleId: "en-US"))
        #expect(controller.phase == .failed(.finalizationTimedOut) && controller.transcript == "original")
        await controller.retry(DictationRequest(appleLocaleId: "zh-CN"))
        delayed.finishContinuation?.resume()
        delayed.finishContinuation = nil
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.phase == .ready && controller.transcript == "new result")
        #expect(controller.originalTranscript == "original")
        controller.cancel()
    }

    @Test("Slow-finalization hint is advisory and clears when the recognizer completes")
    func slowFinalizationHintDoesNotChangeDeadline() async {
        let engine = FakeEngine()
        engine.holdFinish = true
        engine.finalUpdate = .init(finalizedText: "complete result", volatileText: "")
        let controller = VoiceDictationController(engineFactory: { _, _ in [engine] },
            audioSource: FakeAudioSource(), slowWaitDelay: .milliseconds(10))
        await controller.start(DictationRequest())
        let finishing = Task { await controller.stopForReview() }
        #expect(await waitUntil(controller.isTakingLonger))
        #expect(controller.phase == .finishing)
        engine.finishContinuation?.resume()
        engine.finishContinuation = nil
        await finishing.value
        #expect(controller.phase == .ready && !controller.isTakingLonger)
        #expect(controller.transcript == "complete result")
        controller.cancel()
    }

    @Test("Buffered retry gets an utterance budget instead of the live recognizer's short tail budget")
    func retryHasWholeRecordingBudget() async throws {
        let first = FakeEngine()
        first.finalUpdate = .init(finalizedText: "original", volatileText: "")
        let replay = FakeEngine()
        replay.finalizeTimeout = .milliseconds(5)
        replay.holdFinish = true
        replay.finalUpdate = .init(finalizedText: "retry complete", volatileText: "")
        var attempts = 0
        let audio = FakeAudioSource()
        let controller = VoiceDictationController(engineFactory: { _, _ in
            defer { attempts += 1 }; return [attempts == 0 ? first : replay]
        }, audioSource: audio)
        await controller.start(DictationRequest())
        audio.onBuffer?(try pcm())
        await controller.stopForReview()
        let retrying = Task { await controller.retry(DictationRequest()) }
        #expect(await waitUntil(replay.finishAudioCalled))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .finishing && controller.transcript == "original")
        replay.finishContinuation?.resume()
        replay.finishContinuation = nil
        await retrying.value
        #expect(controller.phase == .ready && controller.transcript == "retry complete")
        controller.cancel()
    }

    // MARK: Tests

    @Test("Mic permission denied fails without touching capture")
    func micDenied() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        audio.permission = false
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())

        #expect(controller.phase == .failed(.microphoneDenied))
        #expect(!audio.started)
        #expect(!engine.started)
    }

    @Test("Happy path: volatile shimmers, finals accumulate, finish inserts")
    func happyPath() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        #expect(controller.phase == .listening)
        #expect(audio.started)

        engine.continuation.yield(DictationUpdate(finalizedText: "", volatileText: "deploy the"))
        #expect(await waitUntil(controller.volatileText == "deploy the"))
        #expect(controller.transcript == "deploy the")

        engine.continuation.yield(DictationUpdate(finalizedText: "deploy the staging branch", volatileText: ""))
        #expect(await waitUntil(controller.finalizedText == "deploy the staging branch"))

        let text = await controller.finish()
        #expect(text == "deploy the staging branch")
        #expect(engine.finishAudioCalled)
        #expect(audio.stopped)
        #expect(controller.phase == .idle)
    }

    @Test("Cancel discards the transcript and tears down")
    func cancelDiscards() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        engine.continuation.yield(DictationUpdate(finalizedText: "rm -rf", volatileText: ""))
        _ = await waitUntil(controller.finalizedText == "rm -rf")

        controller.cancel()

        #expect(engine.cancelCalled)
        #expect(audio.stopped)
        #expect(controller.phase == .idle)
    }

    @Test("Model download is visible as its own phase")
    func downloadPhase() async {
        let engine = FakeEngine()
        engine.downloadProgress = [0.4]
        engine.holdPrepare = true
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        let startTask = Task { await controller.start(DictationRequest()) }
        #expect(await waitUntil(controller.phase == .downloadingModel(progress: 0.4)))

        engine.holdPrepare = false
        await startTask.value
        #expect(controller.phase == .listening)
    }

    @Test("A dead first engine degrades to the next candidate")
    func engineFallback() async {
        let broken = FakeEngine()
        broken.prepareError = DictationFailure.engine("not subscribed to transcription.en")
        let working = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engines: [broken, working], audio: audio)

        await controller.start(DictationRequest())

        #expect(controller.phase == .listening)
        #expect(broken.cancelCalled)
        #expect(working.started)

        working.continuation.yield(DictationUpdate(finalizedText: "echo ok", volatileText: ""))
        let text = await controller.finish()
        #expect(text == "echo ok")
    }

    @Test("Speech-recognition denial stops the chain instead of re-asking")
    func denialStopsChain() async {
        let denied = FakeEngine()
        denied.prepareError = DictationFailure.speechRecognitionDenied
        let next = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engines: [denied, next], audio: audio)

        await controller.start(DictationRequest())

        #expect(controller.phase == .failed(.speechRecognitionDenied))
        #expect(!next.started)
    }

    @Test("Unsupported language surfaces as a failure")
    func unsupportedLanguage() async {
        let engine = FakeEngine()
        engine.prepareError = DictationFailure.unsupportedLanguage("Klingon")
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest(appleLocaleId: "tlh"))

        #expect(controller.phase == .failed(.unsupportedLanguage("Klingon")))
    }

    @Test("Finishing with nothing heard returns nil")
    func emptyFinish() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        let text = await controller.finish()

        #expect(text == nil)
        #expect(controller.phase == .idle)
    }

    @Test("Mic buffers are forwarded to the engine")
    func bufferForwarding() async throws {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        audio.onBuffer?(buffer)

        #expect(await waitUntil(engine.appended == 1))
        _ = controller // keep alive through the poll
    }

    @Test("Interruption keeps the transcript and parks in .interrupted")
    func interruptionKeepsTranscript() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        engine.continuation.yield(DictationUpdate(finalizedText: "tail the logs", volatileText: ""))
        _ = await waitUntil(controller.finalizedText == "tail the logs")

        audio.onInterruption?()
        #expect(await waitUntil(controller.phase == .interrupted))
        #expect(audio.stopped)

        let text = await controller.finish()
        #expect(text == "tail the logs")
    }

    @Test("Engine failure mid-listen surfaces and stops capture")
    func engineFailureSurfaces() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)

        await controller.start(DictationRequest())
        engine.continuation.finish(throwing: DictationFailure.engine("asset gone"))

        #expect(await waitUntil(controller.phase == .failed(.engine("asset gone"))))
        #expect(audio.stopped)
    }

    @Test("A recognizer that finishes naturally stops the mic and retains its final text")
    func naturalFinalStopsCapture() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)
        await controller.start(DictationRequest())
        engine.continuation.yield(.init(finalizedText: "complete utterance", volatileText: ""))
        engine.continuation.finish()
        #expect(await waitUntil(controller.phase == .ready))
        #expect(audio.stopped && !controller.isListening)
        #expect(engine.cancelCalled, "natural completion also releases recognizer resources")
        #expect(await controller.finish() == "complete utterance")
        #expect(!engine.finishAudioCalled, "an already completed stream needs no second finalization")
    }

    @Test("Cancelling while permission is pending never starts the microphone")
    func cancelPendingPermission() async {
        let engine = FakeEngine()
        let audio = FakeAudioSource()
        audio.holdPermission = true
        let controller = makeController(engine: engine, audio: audio)
        let starting = Task { await controller.start(DictationRequest()) }
        #expect(await waitUntil(controller.phase == .starting))
        controller.cancel()
        audio.holdPermission = false
        await starting.value
        #expect(controller.phase == .idle)
        #expect(!engine.started && !audio.started)
    }

    @Test("Cancelling preparation prevents a late prepared engine from reopening the mic")
    func cancelPendingPreparation() async {
        let engine = FakeEngine()
        engine.holdPrepare = true
        engine.reportsLoading = true
        let audio = FakeAudioSource()
        let controller = makeController(engine: engine, audio: audio)
        let starting = Task { await controller.start(DictationRequest()) }
        #expect(await waitUntil(controller.phase == .loadingModel))
        controller.cancel()
        engine.holdPrepare = false
        await starting.value
        #expect(engine.cancelCalled && !engine.started && !audio.started)
        #expect(controller.phase == .idle)
    }

    @Test("Finishing consumes a late final result before returning the complete transcript")
    func finishWaitsForFinalWords() async {
        let engine = FakeEngine()
        engine.finalUpdate = .init(finalizedText: "deploy the staging branch", volatileText: "")
        let controller = makeController(engine: engine, audio: FakeAudioSource())
        await controller.start(DictationRequest())
        engine.continuation.yield(.init(finalizedText: "", volatileText: "deploy the"))
        #expect(await waitUntil(controller.transcript == "deploy the"))
        #expect(await controller.finish() == "deploy the staging branch")
        #expect(controller.phase == .idle)
    }

    @Test("A finalization error retains partial text until explicitly accepted")
    func finalizationFailureRequiresPartialAcceptance() async {
        let engine = FakeEngine()
        engine.finishError = DictationFailure.engine("recognizer tail failed")
        let controller = makeController(engine: engine, audio: FakeAudioSource())
        await controller.start(DictationRequest())
        engine.continuation.yield(.init(finalizedText: "", volatileText: "recognized prefix"))
        #expect(await waitUntil(controller.transcript == "recognized prefix"))
        #expect(await controller.finish() == nil)
        #expect(controller.phase == .failed(.finalizationFailed))
        #expect(controller.transcript == "recognized prefix")
        #expect(controller.takePartialTranscript() == "recognized prefix")
        #expect(controller.phase == .idle && controller.transcript.isEmpty)
    }

    @Test("A missing final callback times out without silently accepting partial text")
    func missingFinalCallbackIsBounded() async {
        let engine = FakeEngine()
        engine.leaveUpdatesOpenOnFinish = true
        engine.finalizeTimeout = .milliseconds(20)
        let controller = makeController(engine: engine, audio: FakeAudioSource())
        await controller.start(DictationRequest())
        engine.continuation.yield(.init(finalizedText: "", volatileText: "kept prefix"))
        #expect(await waitUntil(controller.transcript == "kept prefix"))
        let start = ContinuousClock.now
        #expect(await controller.finish() == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(controller.phase == .failed(.finalizationTimedOut))
        #expect(engine.cancelCalled)
        #expect(controller.transcript == "kept prefix")
        controller.cancel()
        #expect(controller.transcript.isEmpty)
        #expect(controller.takePartialTranscript() == nil)
    }

    @Test("Even an uncooperative finishAudio call cannot hold finalization past its deadline")
    func uncooperativeEngineIsBounded() async {
        let engine = FakeEngine()
        engine.holdFinish = true
        engine.finalizeTimeout = .milliseconds(20)
        let controller = makeController(engine: engine, audio: FakeAudioSource())
        await controller.start(DictationRequest())
        let start = ContinuousClock.now
        #expect(await controller.finish() == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(controller.phase == .failed(.finalizationTimedOut))
        #expect(engine.cancelCalled)
        // Release the deliberately uncooperative fake after proving that the
        // controller has already returned; do not leave its task in the suite.
        engine.finishContinuation?.resume()
        engine.finishContinuation = nil
    }

    @Test("Cancellation during finalization cannot insert text or revive a failed overlay")
    func cancelPendingFinish() async {
        let engine = FakeEngine()
        engine.leaveUpdatesOpenOnFinish = true
        let controller = makeController(engine: engine, audio: FakeAudioSource())
        await controller.start(DictationRequest())
        engine.continuation.yield(.init(finalizedText: "", volatileText: "must discard"))
        #expect(await waitUntil(controller.transcript == "must discard"))
        let finishing = Task { await controller.finish() }
        #expect(await waitUntil(controller.phase == .finishing))
        controller.cancel()
        #expect(await finishing.value == nil)
        #expect(controller.phase == .idle && controller.transcript.isEmpty)
    }

    @Test("Late audio callbacks from a cancelled session cannot interrupt its replacement")
    func oldAudioCallbacksCannotAffectNextSession() async {
        let first = FakeEngine()
        let next = FakeEngine()
        let audio = FakeAudioSource()
        var starts = 0
        let controller = VoiceDictationController(engineFactory: { _, _ in
            defer { starts += 1 }
            return [starts == 0 ? first : next]
        }, audioSource: audio)
        await controller.start(DictationRequest())
        let previousLevel = audio.onLevel
        let previousInterruption = audio.onInterruption
        controller.cancel()
        await controller.start(DictationRequest())
        previousLevel?(0.9)
        previousInterruption?()
        // The callbacks schedule work on MainActor; give both a chance to run.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.phase == .listening && controller.level == 0)
        #expect(!next.finishAudioCalled && !next.cancelCalled)
        controller.cancel()
    }
}

/// The CJK-aware transcript joiner — the reason "你好"+"世界" doesn't grow a
/// space and "hello"+"world" does.
@Suite("Dictation transcript joining")
struct DictationTranscriptTests {
    @Test("ASCII words get a separating space")
    func asciiWords() {
        #expect(DictationTranscript.join("hello", "world") == "hello world")
    }

    @Test("CJK segments join without spaces")
    func cjk() {
        #expect(DictationTranscript.join("你好", "世界") == "你好世界")
    }

    @Test("Existing whitespace is respected")
    func existingSpace() {
        #expect(DictationTranscript.join("hello ", "world") == "hello world")
    }

    @Test("ASCII clause punctuation takes a space; CJK punctuation doesn't")
    func punctuation() {
        #expect(DictationTranscript.join("wait,", "go") == "wait, go")
        #expect(DictationTranscript.join("Hello.", "How are you") == "Hello. How are you")
        #expect(DictationTranscript.join("hello", "，世界") == "hello，世界")
        #expect(DictationTranscript.join("你好。", "再说一次") == "你好。再说一次")
    }

    @Test("Empty sides pass through")
    func empties() {
        #expect(DictationTranscript.join("", "x") == "x")
        #expect(DictationTranscript.join("x", "") == "x")
        #expect(DictationTranscript.join("", "").isEmpty)
    }

    @Test("Mixed ASCII/CJK boundary joins tight")
    func mixed() {
        #expect(DictationTranscript.join("用 git", "提交") == "用 git提交")
        #expect(DictationTranscript.join("提交到", "main") == "提交到main")
    }
}
