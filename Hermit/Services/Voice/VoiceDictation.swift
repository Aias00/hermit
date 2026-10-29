import AVFoundation
import Foundation
import Observation
import MoshpitKit

/// One incremental update from a dictation engine: the complete transcript
/// state so far, not a delta. Engines own the assembly because the two
/// recognition APIs report differently — SpeechAnalyzer emits *segments*
/// (finalized text accumulates, the volatile hypothesis is replaced), while
/// SFSpeechRecognizer re-reports the *whole utterance* on every callback.
/// Normalizing here keeps the controller and UI dumb.
struct DictationUpdate: Equatable, Sendable {
    /// Text the engine has committed — it will not change anymore.
    var finalizedText: String
    /// The engine's current in-flight hypothesis for the audio after
    /// `finalizedText`. Rendered dimmer in the UI; replaced on every update.
    var volatileText: String
}

/// What `prepare()` is currently doing, so the overlay can say which of the
/// two very different waits the user is looking at — fetching hundreds of
/// megabytes, or loading bytes that are already on disk.
enum DictationPreparation: Equatable, Sendable {
    /// Fetching model assets. 0…1 where the source reports progress.
    case downloading(progress: Double)
    /// Assets are local; CoreML or the speech daemon is loading them.
    case loading
}

/// Where a dictation session currently is. Drives recording, finalization,
/// review and retry controls; text is accepted only after recording stops.
enum DictationPhase: Equatable {
    case idle
    /// Permission checks + engine selection underway (sub-second normally).
    case starting
    /// First use of an on-device model locale: the system is downloading its
    /// speech assets. `progress` is 0…1 where known.
    case downloadingModel(progress: Double)
    /// Assets are on disk and being loaded into memory. Distinct from
    /// `downloadingModel` because it needs no network and is bounded — a
    /// Whisper model can spend several seconds here on first load while
    /// CoreML compiles it, and "Downloading 100%" sitting still is alarming.
    case loadingModel
    case listening
    /// Mic stopped; waiting for the engine to finalize the tail of the audio.
    case finishing
    /// The recognizer ended its stream normally. The microphone is off and
    /// the recognized text remains available for review and insertion.
    case ready
    /// The system took the microphone (call, Siri). Whatever was heard is
    /// kept — Insert still works; only new audio is off the table.
    case interrupted
    case failed(DictationFailure)
}

enum DictationFailure: Equatable, Error {
    case microphoneDenied
    case speechRecognitionDenied
    /// No engine on this device/OS can transcribe the chosen language.
    case unsupportedLanguage(String)
    /// Whisper is selected but no model is on disk. Recoverable, and the fix
    /// is a specific place in Settings — so it says where.
    case noWhisperModel
    case audioCapture(String)
    case engine(String)
    case finalizationTimedOut
    case finalizationFailed

    /// User-facing message for the overlay's failed state.
    var message: String {
        switch self {
        case .microphoneDenied:
            return String(localized: "Microphone access is off. Enable it in Settings → Privacy → Microphone.")
        case .speechRecognitionDenied:
            return String(localized: "Speech recognition is off. Enable it in Settings → Privacy → Speech Recognition.")
        case .unsupportedLanguage(let name):
            return String(localized: "Dictation isn't available for \(name) on this device.")
        case .noWhisperModel:
            return String(localized: "No Whisper model is downloaded yet. Pick one in Settings → Voice Input → Model.")
        case .audioCapture(let detail):
            return String(localized: "Couldn't start the microphone: \(detail)")
        case .engine(let detail):
            return detail
        case .finalizationTimedOut:
            return String(localized: "Speech recognition did not finish in time. You can keep the text recognized so far.")
        case .finalizationFailed:
            return String(localized: "The last words could not be finalized. You can keep the text recognized so far.")
        }
    }
}

/// Everything a session needs to choose an engine and a language. Assembled
/// from `AppSettings` at the moment the mic key is tapped, so changing any of
/// it in Settings takes effect on the next session with no extra plumbing.
struct DictationRequest: Equatable, Sendable {
    var engine: VoiceEngineKind = .apple
    /// BCP-47 for the Apple engines; "" means Automatic.
    var appleLocaleId: String = ""
    /// Whisper language code ("zh", "en", …); "" means let Whisper detect.
    var whisperLanguage: String = ""
    /// Whisper variant; "" means use the best installed one.
    var whisperModelId: String = ""
}

extension DictationFailure: LocalizedError {
    /// So a failure that leaks into a generic `localizedDescription` still
    /// reads as its real message, not "error 4".
    var errorDescription: String? { message }
}

/// A speech-to-text engine the controller can drive. Two implementations:
/// `ModernDictationEngine` (iOS 26+, SpeechAnalyzer's on-device models) and
/// `LegacyDictationEngine` (SFSpeechRecognizer, iOS 18–25). Tests inject a
/// scripted fake through `VoiceDictationController`'s factory.
protocol DictationEngine: AnyObject {
    /// Complete-state updates, finishing when the engine has delivered its
    /// final result (after `finishAudio()`) or throwing on recognition error.
    var updates: AsyncThrowingStream<DictationUpdate, Error> { get }
    /// Short label naming the engine and language actually in play — shown on
    /// the overlay so a session running in the wrong language is visible
    /// *before* the user talks to it for a minute and gets nonsense back.
    var label: String { get }
    /// How long `finishAudio()` may take before the controller gives up and
    /// keeps whatever transcript exists. Engines that stream have delivered
    /// nearly everything by then; Whisper does all its work here and needs
    /// room proportional to the utterance.
    var finalizeTimeout: Duration { get }
    /// Authorization + model assets. May be slow on first use of a locale
    /// (model download, then load) — progress lands in `onProgress`.
    func prepare(onProgress: @escaping @Sendable (DictationPreparation) -> Void) async throws
    /// Begin accepting audio. Only valid after `prepare()`.
    func start() async throws
    /// Feed one microphone buffer. Called on the audio tap's thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio is coming — finalize and end `updates`.
    func finishAudio() async
    /// Abandon the session; `updates` ends without further results.
    func cancel()
}

extension DictationEngine {
    /// Streaming engines have essentially finished by the time the mic stops.
    var finalizeTimeout: Duration { .seconds(5) }
}

/// Microphone capture, abstracted so controller tests never touch real audio
/// hardware (Simulator CI has no deterministic mic).
protocol DictationAudioSource: AnyObject {
    /// Ask for (or verify) record permission. False = denied.
    func requestPermission() async -> Bool
    /// Start capturing. `onBuffer` fires on the audio thread with raw mic
    /// buffers; `onLevel` fires with a 0…1 loudness for the level meter;
    /// `onInterruption` fires when the system takes the mic away (phone call).
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Session-only PCM retention. The tap owns its buffers, so retaining the
/// incoming object is unsafe: copy its live frames before returning to it.
/// Exceeding either budget discards the WHOLE recording; a prefix must never
/// masquerade as a successful retry of the complete utterance.
final class DictationRecordingCache: @unchecked Sendable {
    static let maximumDuration: TimeInterval = 120
    static let maximumBytes = 32 * 1_024 * 1_024
    enum UnavailableReason: Equatable { case limitExceeded, copyingFailed }
    struct Status {
        let count: Int
        let duration: TimeInterval
        let bytes: Int
        let unavailable: UnavailableReason?
    }
    private let lock = NSLock()
    private var accepting = true
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: TimeInterval = 0
    private var bytes = 0
    private var unavailable: UnavailableReason?

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return Status(count: buffers.count, duration: duration, bytes: bytes, unavailable: unavailable)
    }

    /// Also gates delivery to the live recognizer. seal()/clear() wait for an
    /// in-flight callback, and no late callback can refill or forward after it.
    func capture(_ buffer: AVAudioPCMBuffer, deliver: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if unavailable == nil, buffer.frameLength > 0 {
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let length = source.reduce(0) { $0 + Int($1.mDataByteSize) }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            if !seconds.isFinite || seconds <= 0 {
                discard(.copyingFailed)
            } else if seconds > Self.maximumDuration - duration || length > Self.maximumBytes - bytes {
                discard(.limitExceeded)
            } else if let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) {
                copy.frameLength = buffer.frameLength
                let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                var valid = source.count == destination.count
                if valid {
                    for index in source.indices {
                        guard let from = source[index].mData, let to = destination[index].mData,
                              source[index].mDataByteSize <= destination[index].mDataByteSize else {
                            valid = false
                            break
                        }
                        memcpy(to, from, Int(source[index].mDataByteSize))
                    }
                }
                if valid {
                    buffers.append(copy)
                    duration += seconds
                    bytes += length
                } else { discard(.copyingFailed) }
            } else { discard(.copyingFailed) }
        }
        deliver()
    }

    func seal() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
    }

    /// Replay takes only one chunk at a time. Cancellation can therefore free
    /// the remaining recording even if model preparation never returns.
    func buffer(at index: Int) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !accepting, buffers.indices.contains(index) else { return nil }
        return buffers[index]
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        buffers.removeAll()
        duration = 0
        bytes = 0
    }

    private func discard(_ reason: UnavailableReason) {
        buffers.removeAll()
        duration = 0
        bytes = 0
        unavailable = reason
    }
}

/// Drives one dictation session: mic permission → engine prep (model
/// download) → live transcription → review/retry → insert-or-cancel. Owned by the terminal
/// screen while the overlay is up; thrown away afterwards.
///
/// The transcript is buffered here. Finishing returns it to the terminal
/// screen's editable draft; the shared paper-plane action submits that draft.
@Observable
@MainActor
final class VoiceDictationController {
    private(set) var phase: DictationPhase = .idle
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    /// Mic loudness 0…1 for the overlay's level meter.
    private(set) var level: Float = 0
    /// Engine + language of the running session, for the overlay's chip.
    /// Empty until an engine has been selected.
    private(set) var engineLabel = ""
    private(set) var canRetryRecording = false
    private(set) var retryUnavailableReason: String?
    private(set) var isReplaying = false
    private(set) var isTakingLonger = false
    private(set) var currentRequest: DictationRequest?
    private(set) var originalTranscript = ""

    /// Everything the user has said so far, as it would be inserted.
    var transcript: String {
        DictationTranscript.join(finalizedText, volatileText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isListening: Bool { phase == .listening }

    @ObservationIgnored
    private let makeEngines: (DictationRequest, [String]) async throws -> [DictationEngine]
    @ObservationIgnored private let audioSource: DictationAudioSource
    @ObservationIgnored private var engine: DictationEngine?
    @ObservationIgnored private var preparingEngine: DictationEngine?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationToken: UUID?
    @ObservationIgnored private var finalizationContinuation: CheckedContinuation<FinalizationOutcome, Never>?
    @ObservationIgnored private var recording: DictationRecordingCache?
    @ObservationIgnored private var hasOriginalTranscript = false
    @ObservationIgnored private var originalRequest: DictationRequest?
    @ObservationIgnored private var originalEngineLabel = ""
    @ObservationIgnored private var replayUpdate: DictationUpdate?
    @ObservationIgnored private var replayFailure: DictationFailure?
    @ObservationIgnored private var replayStreamEnded = false
    @ObservationIgnored private var slowWaitTask: Task<Void, Never>?
    @ObservationIgnored private let slowWaitDelay: Duration
    @ObservationIgnored private let retryTimeoutOverride: Duration?

    private enum FinalizationOutcome {
        case complete
        case failed(DictationFailure)
        case cancelled
    }

    init(engineFactory: @escaping (DictationRequest, [String]) async throws -> [DictationEngine]
             = DictationEngineFactory.candidates,
         audioSource: DictationAudioSource = MicrophoneAudioSource(),
         slowWaitDelay: Duration = .seconds(2), retryTimeoutOverride: Duration? = nil) {
        makeEngines = engineFactory
        self.audioSource = audioSource
        self.slowWaitDelay = slowWaitDelay
        self.retryTimeoutOverride = retryTimeoutOverride
    }

    #if DEBUG
    /// Exercises the draft handoff with a predetermined transcript. No mic,
    /// recognizer or network request is started by the simulator UI fixture.
    static func previewForUITest(text: String, failure: DictationFailure? = nil) -> VoiceDictationController {
        let controller = VoiceDictationController(audioSource: ReviewPreviewAudioSource())
        controller.finalizedText = text
        controller.phase = failure.map(DictationPhase.failed) ?? .interrupted
        controller.engineLabel = "UI test transcript"
        controller.rememberOriginalTranscript()
        return controller
    }

    /// The isolated loopback UI lab uses scripted PCM/recognizers. This never
    /// requests system microphone or speech permissions and opens no network.
    static func previewForReviewUITest() -> VoiceDictationController {
        var attempt = 0
        return VoiceDictationController(engineFactory: { request, _ in
            defer { attempt += 1 }
            let text: String
            if attempt == 0 { text = "simulated voice" }
            else if request.appleLocaleId == "en-US" { text = "retried English voice" }
            else if request.appleLocaleId == "zh-CN" { text = "重新识别的中文" }
            else { text = "retried automatic voice" }
            return [ReviewPreviewEngine(text: text)]
        }, audioSource: ReviewPreviewAudioSource())
    }
    #endif

    /// Kick off a session. Safe to call only from `.idle`/`.failed`; anything
    /// else is ignored.
    func start(_ request: DictationRequest) async {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        generation &+= 1
        let currentGeneration = generation
        engine?.cancel()
        consumeTask?.cancel()
        engine = nil
        consumeTask = nil
        recording?.clear()
        recording = DictationRecordingCache()
        canRetryRecording = false
        retryUnavailableReason = nil
        currentRequest = request
        originalTranscript = ""
        hasOriginalTranscript = false
        originalRequest = nil
        originalEngineLabel = ""
        isReplaying = false
        endSlowWait()
        phase = .starting
        finalizedText = ""
        volatileText = ""
        level = 0
        engineLabel = ""

        let permitted = await audioSource.requestPermission()
        guard acceptsStart(currentGeneration) else { return }
        guard permitted else {
            phase = .failed(.microphoneDenied)
            return
        }

        guard let engine = await prepareEngine(request, generation: currentGeneration) else { return }
        self.engine = engine
        engineLabel = engine.label
        Log.voice.info("dictation started engine=\(engine.label, privacy: .public)")

        consume(engine, generation: currentGeneration)

        guard let recording else { return }
        do {
            try audioSource.start(
                onBuffer: { [weak engine] buffer in
                    recording.capture(buffer) { engine?.append(buffer) }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        guard let self, generation == currentGeneration, phase == .listening else { return }
                        self.level = level
                    }
                },
                onInterruption: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, generation == currentGeneration else { return }
                        await handleInterruption()
                    }
                })
        } catch {
            stopAudio()
            engine.cancel()
            consumeTask?.cancel()
            self.engine = nil
            phase = .failed(.audioCapture(error.localizedDescription))
            return
        }
        phase = .listening
    }

    private func prepareEngine(_ request: DictationRequest, generation currentGeneration: UInt64) async -> DictationEngine? {
        // Work down the candidate list: an engine whose locale looked fine
        // can still fail to prepare (asset install unavailable, reservation
        // cap) — degrade to the next one and only fail when all did.
        let onProgress: @Sendable (DictationPreparation) -> Void = { [weak self] step in
            Task { @MainActor [weak self] in
                // Don't regress the phase if listening already started
                // (progress callbacks can trail the install completing).
                guard let self, generation == currentGeneration,
                      phase == .starting || isPreparing else { return }
                switch step {
                case .downloading(let progress): phase = .downloadingModel(progress: progress)
                case .loading: phase = .loadingModel
                }
            }
        }
        // Resolved here rather than inside the factory: reading the user's
        // language ranking and installed keyboards is main-actor work, and
        // this is the main actor.
        let spoken = VoiceLanguageResolver.spokenLanguageCandidates()
        var selected: DictationEngine?
        var lastError: Error?
        do {
            let candidates = try await makeEngines(request, spoken)
            guard acceptsStart(currentGeneration) else {
                candidates.forEach { $0.cancel() }
                return nil
            }
            for candidate in candidates {
                do {
                    preparingEngine = candidate
                    try await candidate.prepare(onProgress: onProgress)
                    guard acceptsStart(currentGeneration) else { candidate.cancel(); return nil }
                    try await candidate.start()
                    guard acceptsStart(currentGeneration) else { candidate.cancel(); return nil }
                    preparingEngine = nil
                    selected = candidate
                    break
                } catch let failure as DictationFailure where failure == .speechRecognitionDenied {
                    // Denial is a user decision, not an engine defect —
                    // falling through would just re-ask. Surface it.
                    candidate.cancel()
                    guard acceptsStart(currentGeneration) else { return nil }
                    preparingEngine = nil
                    throw failure
                } catch {
                    candidate.cancel()
                    guard acceptsStart(currentGeneration) else { return nil }
                    preparingEngine = nil
                    lastError = error
                    Log.voice.error("engine unavailable, trying next: \(error.localizedDescription)")
                }
            }
        } catch let failure as DictationFailure {
            guard acceptsStart(currentGeneration) else { return nil }
            phase = .failed(failure)
            return nil
        } catch {
            guard acceptsStart(currentGeneration) else { return nil }
            phase = .failed(.engine(error.localizedDescription))
            return nil
        }
        guard let selected else {
            if let failure = lastError as? DictationFailure {
                phase = .failed(failure)
            } else if let lastError {
                phase = .failed(.engine(lastError.localizedDescription))
            } else {
                phase = .failed(.engine(String(localized: "Speech recognition is unavailable.")))
            }
            return nil
        }
        return selected
    }

    private func consume(_ engine: DictationEngine, generation currentGeneration: UInt64) {
        consumeTask = Task { [weak self] in
            do {
                for try await update in engine.updates {
                    guard let self, generation == currentGeneration, !Task.isCancelled else { return }
                    if isReplaying {
                        replayUpdate = update
                    } else {
                        finalizedText = update.finalizedText
                        volatileText = update.volatileText
                    }
                }
                guard let self, generation == currentGeneration, !Task.isCancelled else { return }
                if isReplaying { replayStreamEnded = true }
                if phase == .listening {
                    stopAudio()
                    engine.cancel()
                    phase = .ready
                    rememberOriginalTranscript()
                    updateRetryAvailability()
                    Log.voice.info("dictation ended: recognizer-final")
                }
            } catch {
                guard let self, generation == currentGeneration, !Task.isCancelled else { return }
                if isReplaying { replayFailure = .finalizationFailed }
                if phase == .finishing, let token = finalizationToken {
                    completeFinalization(.failed(.finalizationFailed), token: token)
                    return
                }
                guard phase == .listening else { return }
                // A DictationFailure travels as itself; anything else (an
                // Apple recognition error) keeps its own message.
                phase = .failed((error as? DictationFailure) ?? .engine(error.localizedDescription))
                stopAudio()
                engine.cancel()
                rememberOriginalTranscript()
                updateRetryAvailability()
                Log.voice.info("dictation ended: recognition-error")
            }
        }
    }

    /// Stop and review without committing to the terminal draft. The complete
    /// recording remains available only for the lifetime of this overlay.
    func stopForReview() async {
        guard !isReplaying else { return }
        let currentGeneration = generation
        let outcome = await stopListening()
        guard generation == currentGeneration else { return }
        switch outcome {
        case .complete: phase = .ready
        case .failed(let failure): phase = .failed(failure)
        case .cancelled: return
        }
        rememberOriginalTranscript()
        updateRetryAvailability()
    }

    /// Try another local recognizer/language against the SAME recording. No
    /// microphone permission or capture call belongs in this path. Keep the
    /// prior text visible, committing replacement text only on nonempty success.
    func retry(_ request: DictationRequest) async {
        guard canRetryRecording, isStableForReview, let recording else { return }
        rememberOriginalTranscript()
        let previousRequest = currentRequest
        let previousEngineLabel = engineLabel
        generation &+= 1
        let currentGeneration = generation
        engine?.cancel()
        consumeTask?.cancel()
        engine = nil
        consumeTask = nil
        isReplaying = true
        canRetryRecording = false
        currentRequest = request
        replayUpdate = nil
        replayFailure = nil
        replayStreamEnded = false
        phase = .starting
        guard let engine = await prepareEngine(request, generation: currentGeneration) else {
            guard generation == currentGeneration else { return }
            currentRequest = previousRequest
            engineLabel = previousEngineLabel
            isReplaying = false
            updateRetryAvailability()
            return
        }
        self.engine = engine
        engineLabel = engine.label
        phase = .finishing
        beginSlowWait(generation: currentGeneration)
        consume(engine, generation: currentGeneration)
        Log.voice.info("dictation retry started engine=\(engine.label, privacy: .public)")
        let status = recording.status
        for index in 0..<status.count {
            guard acceptsStart(currentGeneration) else { return }
            // Never accept an early-completed prefix as the whole recording.
            if replayFailure != nil || replayStreamEnded {
                replayFailure = replayFailure ?? .finalizationFailed
                break
            }
            guard let buffer = recording.buffer(at: index) else { return }
            engine.append(buffer)
            await Task.yield()
        }
        guard acceptsStart(currentGeneration) else { return }
        let outcome: FinalizationOutcome
        if let replayFailure {
            outcome = .failed(replayFailure)
        } else {
            // Buffered Apple recognition must decode the entire recording;
            // its live-stream tail budget alone is insufficient.
            let budget = retryTimeoutOverride ?? max(engine.finalizeTimeout,
                .seconds(max(20, status.duration * 2)))
            outcome = await finalizeEngine(budget: budget)
        }
        guard generation == currentGeneration else { return }
        switch outcome {
        case .complete:
            let replacement = replayUpdate.map {
                DictationTranscript.join($0.finalizedText, $0.volatileText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            if replacement.isEmpty {
                currentRequest = previousRequest
                engineLabel = previousEngineLabel
                phase = .failed(.engine(String(localized: "No speech was recognized.")))
            } else {
                finalizedText = replacement
                volatileText = ""
                phase = .ready
            }
        case .failed(let failure):
            currentRequest = previousRequest
            engineLabel = previousEngineLabel
            phase = .failed(failure)
        case .cancelled: break
        }
        engine.cancel()
        consumeTask?.cancel()
        isReplaying = false
        replayUpdate = nil
        endSlowWait()
        updateRetryAvailability()
    }

    func restoreOriginalTranscript() {
        guard isStableForReview, !isReplaying, hasOriginalTranscript else { return }
        finalizedText = originalTranscript
        volatileText = ""
        currentRequest = originalRequest
        engineLabel = originalEngineLabel
        phase = .ready
        updateRetryAvailability()
    }

    /// Stop the mic, let the engine finalize, and return the transcript
    /// (nil when nothing usable was heard). Success ends in `.idle`; failure
    /// retains the transcript in `.failed` for explicit partial acceptance.
    func finish() async -> String? {
        guard !isReplaying else { return nil }
        if phase == .listening { Log.voice.info("dictation ending: user-finish") }
        let currentGeneration = generation
        let result = await stopListening()
        guard generation == currentGeneration else { return nil }
        switch result {
        case .complete:
            let text = transcript
            reset()
            return text.isEmpty ? nil : text
        case .failed(let failure):
            phase = .failed(failure)
            rememberOriginalTranscript()
            updateRetryAvailability()
            return nil
        case .cancelled:
            return nil
        }
    }

    /// Explicit acceptance of an incomplete transcript after the overlay has
    /// shown the failure. A failed finish never inserts partial text silently.
    func takePartialTranscript() -> String? {
        guard case .failed = phase, !isReplaying else { return nil }
        let text = transcript
        engine?.cancel()
        consumeTask?.cancel()
        reset()
        return text.isEmpty ? nil : text
    }

    /// Abandon the session and discard the transcript.
    func cancel() {
        if phase != .idle { Log.voice.info("dictation ended: cancelled") }
        generation &+= 1
        stopAudio()
        preparingEngine?.cancel()
        preparingEngine = nil
        engine?.cancel()
        consumeTask?.cancel()
        if let token = finalizationToken { completeFinalization(.cancelled, token: token) }
        reset()
    }

    private func acceptsStart(_ currentGeneration: UInt64) -> Bool {
        guard generation == currentGeneration else { return false }
        guard !Task.isCancelled else { cancel(); return false }
        return true
    }

    /// Between "go" and "listening": fetching or loading model assets.
    private var isPreparing: Bool {
        if case .downloadingModel = phase { return true }
        return phase == .loadingModel
    }

    /// The system claimed the mic mid-session. Finalize what was heard and
    /// park in `.interrupted` so the user can still insert it.
    private func handleInterruption() async {
        guard phase == .listening else { return }
        Log.voice.info("dictation ending: interruption")
        let currentGeneration = generation
        let result = await stopListening()
        guard generation == currentGeneration else { return }
        switch result {
        case .complete: phase = .interrupted
        case .failed(let failure): phase = .failed(failure)
        case .cancelled: break
        }
        rememberOriginalTranscript()
        updateRetryAvailability()
    }

    /// Mic off + engine finalization (bounded — a wedged recognizer must not
    /// hold the overlay hostage; whatever transcript exists is kept).
    private func stopListening() async -> FinalizationOutcome {
        switch phase {
        case .ready, .interrupted: return .complete
        case .failed(let failure): return .failed(failure)
        case .listening: break
        default: return .cancelled
        }
        phase = .finishing
        Log.voice.info("dictation ending: finalize-requested")
        stopAudio()
        return await finalizeEngine(budget: engine?.finalizeTimeout ?? .seconds(5))
    }

    private func finalizeEngine(budget: Duration) async -> FinalizationOutcome {
        guard let engine else { return .complete }
        let consumeTask = consumeTask
        // The budget is the engine's, not a fixed 5 s: a streaming engine has
        // already delivered nearly everything, while Whisper hasn't started —
        // decoding a minute of speech happens entirely inside finishAudio(),
        // and cutting it off at 5 s would throw away the whole transcript.
        if slowWaitTask == nil { beginSlowWait(generation: generation) }
        let token = UUID()
        finalizationToken = token
        // A structured task group waits for every child before returning, even
        // after cancelAll(). Keep the completion wait independent so an engine
        // that ignores cancellation cannot defeat this deadline.
        return await withCheckedContinuation { continuation in
            finalizationContinuation = continuation
            finalizationTask = Task { [weak self] in
                await engine.finishAudio()
                await consumeTask?.value
                guard !Task.isCancelled else { return }
                if let self, isReplaying, let replayFailure {
                    completeFinalization(.failed(replayFailure), token: token)
                } else {
                    self?.completeFinalization(.complete, token: token)
                }
            }
            finalizationTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: budget) } catch { return }
                self?.completeFinalization(.failed(.finalizationTimedOut), token: token)
            }
        }
    }

    private func completeFinalization(_ outcome: FinalizationOutcome, token: UUID) {
        guard finalizationToken == token, let continuation = finalizationContinuation else { return }
        finalizationToken = nil
        finalizationContinuation = nil
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        endSlowWait()
        switch outcome {
        case .complete:
            Log.voice.info("dictation ended: finalized")
        case .failed(.finalizationTimedOut):
            Log.voice.info("dictation ended: finalization-timeout")
        case .failed:
            Log.voice.info("dictation ended: finalization-error")
        case .cancelled:
            break
        }
        if case .complete = outcome { } else {
            engine?.cancel()
            consumeTask?.cancel()
            finalizationTask?.cancel()
        }
        finalizationTask = nil
        continuation.resume(returning: outcome)
    }

    private func stopAudio() {
        recording?.seal()
        audioSource.stop()
        level = 0
    }

    private var isStableForReview: Bool {
        switch phase {
        case .ready, .interrupted, .failed: return true
        default: return false
        }
    }

    private func rememberOriginalTranscript() {
        guard !isReplaying, !hasOriginalTranscript else { return }
        hasOriginalTranscript = true
        originalTranscript = transcript
        originalRequest = currentRequest
        originalEngineLabel = engineLabel
    }

    private func updateRetryAvailability() {
        guard isStableForReview, !isReplaying else {
            canRetryRecording = false
            return
        }
        let status = recording?.status
        canRetryRecording = status?.unavailable == nil && (status?.count ?? 0) > 0
        if canRetryRecording {
            retryUnavailableReason = nil
        } else if status?.unavailable == .limitExceeded {
            retryUnavailableReason = String(localized: "Retry is available for recordings up to 2 minutes and 32 MB.")
        } else {
            retryUnavailableReason = String(localized: "No recording is available to retry.")
        }
    }

    private func beginSlowWait(generation currentGeneration: UInt64) {
        endSlowWait()
        let delay = slowWaitDelay
        slowWaitTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == currentGeneration, phase == .finishing else { return }
            isTakingLonger = true
        }
    }

    private func endSlowWait() {
        slowWaitTask?.cancel()
        slowWaitTask = nil
        isTakingLonger = false
    }

    private func reset() {
        generation &+= 1
        recording?.clear()
        recording = nil
        canRetryRecording = false
        retryUnavailableReason = nil
        isReplaying = false
        currentRequest = nil
        originalTranscript = ""
        hasOriginalTranscript = false
        originalRequest = nil
        originalEngineLabel = ""
        replayUpdate = nil
        replayFailure = nil
        replayStreamEnded = false
        endSlowWait()
        engine?.cancel()
        consumeTask?.cancel()
        engine = nil
        consumeTask = nil
        finalizedText = ""
        volatileText = ""
        phase = .idle
    }
}

#if DEBUG
private final class ReviewPreviewEngine: DictationEngine {
    let updates: AsyncThrowingStream<DictationUpdate, Error>
    private let continuation: AsyncThrowingStream<DictationUpdate, Error>.Continuation
    private let text: String
    var label: String { "UI test transcript" }
    init(text: String) {
        self.text = text
        (updates, continuation) = AsyncThrowingStream.makeStream()
    }
    func prepare(onProgress: @escaping @Sendable (DictationPreparation) -> Void) async throws {}
    func start() async throws { continuation.yield(.init(finalizedText: "", volatileText: text)) }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishAudio() async {
        continuation.yield(.init(finalizedText: text, volatileText: ""))
        continuation.finish()
    }
    func cancel() { continuation.finish() }
}

private final class ReviewPreviewAudioSource: DictationAudioSource {
    func requestPermission() async -> Bool { true }
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable () -> Void) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else { return }
        buffer.frameLength = 1_600
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 1_600)
        onBuffer(buffer)
    }
    func stop() {}
}
#endif

/// Joining rule for transcript pieces: English-like segments need a space
/// between them, CJK must not grow spaces mid-sentence. Pure + tested.
enum DictationTranscript {
    /// ASCII marks that end a clause — a following ASCII word wants a space
    /// ("Hello." + "How" → "Hello. How"). Their CJK counterparts (。，) are
    /// full-width and never take one.
    private static let clauseEnders: Set<Unicode.Scalar> = [".", ",", "!", "?", ";", ":", ")"]

    /// Concatenate two transcript pieces, inserting a single space only at an
    /// ASCII word/clause boundary — "hello"+"world" → "hello world",
    /// "wait,"+"go" → "wait, go" — while "你好"+"世界" → "你好世界" and
    /// pieces already separated ("hello "+"world") pass through untouched.
    static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first,
              last.isASCII, first.isASCII else {
            return head + tail
        }
        let wordlike = CharacterSet.alphanumerics
        guard wordlike.contains(first) else { return head + tail }
        let needsSpace = wordlike.contains(last) || clauseEnders.contains(last)
        return needsSpace ? head + " " + tail : head + tail
    }
}
