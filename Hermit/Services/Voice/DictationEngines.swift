import AVFoundation
import Foundation
import Speech
import MoshpitKit

// MARK: - Engine selection

/// Builds the ordered list of engines a session should try.
///
/// With Whisper selected the local model leads and Apple's engines stay
/// behind it as a fallback — a model that failed to load should cost accuracy,
/// not the ability to dictate at all. With Apple selected, the preference is:
///
/// 1. **SpeechTranscriber** (iOS 26+) — Apple's large on-device speech model
///    (the SpeechAnalyzer stack). Best accuracy, fully local, no speech-
///    recognition permission needed; assets download on first use.
/// 2. **DictationTranscriber** (iOS 26+) — the on-device keyboard-dictation
///    model, covering many locales the large model doesn't yet.
/// 3. **SFSpeechRecognizer** (iOS 18–25) — *on-device only*. The server
///    variant is deliberately never used: choosing a local engine must not
///    silently upload audio. Doubao is a separate, explicit cloud choice.
enum DictationEngineFactory {
    /// All engines that can serve the request, best first. The controller
    /// works down the list at prepare/start time: a transcriber whose locale
    /// is *listed* can still fail to obtain assets in a given environment
    /// (Simulators can't install the large-model assets at all, and a
    /// device can hit the reserved-locales cap), and the session should
    /// degrade to the next engine rather than die with a daemon error.
    ///
    /// `spokenLanguages` is the caller's ordered guess at what the user
    /// speaks — see `VoiceLanguageResolver`. It only matters when the stored
    /// language is Automatic.
    static func candidates(request: DictationRequest,
                           spokenLanguages: [String]) async throws -> [DictationEngine] {
        if request.engine == .doubao {
            return [DoubaoDictationEngine(resourceID: request.doubaoResourceID)]
        }
        var engines: [DictationEngine] = []
        if request.engine == .whisper,
           let variant = WhisperModelStore.resolvedVariant(preferring: request.whisperModelId) {
            let language = VoiceLanguageResolver.whisperCode(stored: request.whisperLanguage)
            engines.append(WhisperDictationEngine(
                store: WhisperModelStore.shared,
                variant: variant,
                language: language,
                label: whisperLabel(variant: variant, language: language),
                contextualStrings: request.contextualStrings))
        }
        let locale = await appleLocale(request: request, spokenLanguages: spokenLanguages)
        engines.append(contentsOf: await appleEngines(locale: locale, contextualStrings: request.contextualStrings))
        guard !engines.isEmpty else {
            if request.engine == .whisper, request.whisperModelId.isEmpty,
               WhisperModelStore.resolvedVariant(preferring: "") == nil {
                throw DictationFailure.noWhisperModel
            }
            throw DictationFailure.unsupportedLanguage(
                Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        return engines
    }

    /// Apple's transcribers for a locale, best first. Empty when none of them
    /// can do that language on this device.
    private static func appleEngines(locale: Locale, contextualStrings: [String] = []) async -> [DictationEngine] {
        var engines: [DictationEngine] = []
        if #available(iOS 26.0, *) {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                engines.append(ModernDictationEngine(module: .advanced(SpeechTranscriber(
                    locale: match,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []))))
            }
            if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                engines.append(ModernDictationEngine(module: .dictation(DictationTranscriber(
                    locale: match, preset: .progressiveLongDictation)), contextualStrings: contextualStrings))
            }
        }
        if let recognizer = SFSpeechRecognizer(locale: locale),
           recognizer.supportsOnDeviceRecognition {
            engines.append(LegacyDictationEngine(recognizer: recognizer, contextualStrings: contextualStrings))
        }
        return engines
    }

    /// Resolve Automatic against what Apple can actually transcribe here.
    ///
    /// The check is a real capability probe rather than a lookup table: asking
    /// each candidate language whether *some* engine claims it is the only way
    /// to avoid picking a language the device would then refuse.
    private static func appleLocale(request: DictationRequest,
                                    spokenLanguages: [String]) async -> Locale {
        if !request.appleLocaleId.isEmpty { return Locale(identifier: request.appleLocaleId) }
        for identifier in spokenLanguages {
            let locale = Locale(identifier: identifier)
            if await !appleEngines(locale: locale).isEmpty { return locale }
        }
        return spokenLanguages.first.map(Locale.init(identifier:)) ?? Locale.current
    }

    private static func whisperLabel(variant: String, language: String?) -> String {
        let model = WhisperModelStore.displayName(for: variant)
        let languageName = language.flatMap {
            Locale.current.localizedString(forLanguageCode: $0)
        } ?? String(localized: "Auto")
        return "\(model) · \(languageName)"
    }
}

// MARK: - SpeechAnalyzer engine (iOS 26+)

/// The SpeechAnalyzer pipeline: mic buffers → format conversion →
/// `AnalyzerInput` stream → transcriber module → results. Model assets are
/// system-managed (`AssetInventory`) and shared across apps, so the first use
/// of a language may download once and every later session is instant.
@available(iOS 26.0, *)
final class ModernDictationEngine: DictationEngine {
    /// Which on-device module is transcribing. Both flavors expose the same
    /// result shape but are unrelated concrete types, hence the enum rather
    /// than a generic (the module's Result associated type doesn't carry
    /// `text` at the protocol level).
    enum Module {
        case advanced(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .advanced(let transcriber): return transcriber
            case .dictation(let transcriber): return transcriber
            }
        }
    }

    let updates: AsyncThrowingStream<DictationUpdate, Error>

    var label: String {
        let name = selectedLocale.flatMap {
            Locale.current.localizedString(forIdentifier: $0.identifier(.bcp47))
        } ?? String(localized: "Unknown")
        switch module {
        case .advanced: return String(localized: "Apple · \(name)")
        case .dictation: return String(localized: "Apple Dictation · \(name)")
        }
    }

    private let module: Module
    private let contextualStrings: [String]
    private let updateContinuation: AsyncThrowingStream<DictationUpdate, Error>.Continuation
    /// Serializes converter, input delivery and termination against the tap.
    private let lock = NSLock()
    private let converter = DictationBufferConverter()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var acceptingAudio = false
    /// Set by `cancel()` so a torn-down results stream ends quietly instead
    /// of surfacing a cancellation as a user-visible error.
    private var cancelled = false

    /// Transcript assembly (results-task context only): finals accumulate,
    /// the volatile hypothesis is replaced by every non-final result.
    private var finalized = ""

    init(module: Module, contextualStrings: [String] = []) {
        self.module = module
        self.contextualStrings = VoiceVocabulary.normalized(contextualStrings)
        (updates, updateContinuation) = AsyncThrowingStream.makeStream()
    }

    /// The locale the module was built for — needed to reserve its assets.
    private var selectedLocale: Locale? {
        switch module {
        case .advanced(let transcriber): return transcriber.selectedLocales.first
        case .dictation(let transcriber): return transcriber.selectedLocales.first
        }
    }

    func prepare(onProgress: @escaping @Sendable (DictationPreparation) -> Void) async throws {
        if await AssetInventory.status(forModules: [module.speechModule]) == .installed {
            return
        }
        // The app must hold a reservation ("subscription") on the locale
        // before it may even ask about its assets — skipping this fails
        // with "not subscribed to transcription.<lang>". Reservations are
        // capped (maximumReservedLocales), so a failed reserve isn't fatal
        // here: let the install request report the real story.
        if let locale = selectedLocale {
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                do {
                    try await AssetInventory.reserve(locale: locale)
                } catch {
                    Log.voice.error("locale reservation failed: \(error.localizedDescription)")
                }
            }
        }
        // nil request = assets already installed. Otherwise this is the
        // one-time per-language model download (system-managed, shared).
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module.speechModule]) else { return }
        let progress = request.progress
        let poll = Task {
            while !Task.isCancelled {
                onProgress(.downloading(progress: progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    func start() async throws {
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.speechModule])
        // Contextual vocabulary is supported by DictationTranscriber. Keep
        // SpeechTranscriber first in the factory without implying this hint
        // changes its model or silently switching engines to honor a word list.
        if case .dictation = module, !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        try Task.checkCancellation()
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            self.analyzer = analyzer
            analyzerFormat = format
            self.inputContinuation = inputContinuation
            acceptingAudio = true
            // Subscribe before starting analysis so no early result is lost.
            resultsTask = Task { [weak self] in await self?.consumeResults() }
        }
        do {
            try await analyzer.start(inputSequence: inputSequence)
            try Task.checkCancellation()
            try lock.withLock { if cancelled { throw CancellationError() } }
        } catch {
            cancel()
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let failedAnalyzer: SpeechAnalyzer? = lock.withLock {
            guard acceptingAudio, !cancelled, let inputContinuation else { return nil }
            do {
                for converted in try converter.append(buffer, to: analyzerFormat ?? buffer.format) {
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
                return nil
            } catch {
                // A missing chunk must not become a successful transcription
                // of an incomplete recording. The controller retains PCM for
                // an explicit retry and preserves any already visible text.
                return failAudioLocked(error)
            }
        }
        if let failedAnalyzer { Task { await failedAnalyzer.cancelAndFinishNow() } }
    }

    func finishAudio() async {
        var failedAnalyzer: SpeechAnalyzer?
        let work: (SpeechAnalyzer, Task<Void, Never>?)? = lock.withLock {
            guard acceptingAudio, !cancelled, let analyzer, let inputContinuation else { return nil }
            acceptingAudio = false
            do {
                // Closing the analyzer input does not flush AVAudioConverter.
                // Deliver its EOS tail first, then finish the recognizer input.
                for tail in try converter.finish() {
                    inputContinuation.yield(AnalyzerInput(buffer: tail))
                }
                inputContinuation.finish()
                self.inputContinuation = nil
                return (analyzer, resultsTask)
            } catch {
                failedAnalyzer = failAudioLocked(error)
                return nil
            }
        }
        if let failedAnalyzer { await failedAnalyzer.cancelAndFinishNow() }
        guard let (analyzer, resultsTask) = work else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            if !lock.withLock({ cancelled }), !(error is CancellationError) {
                updateContinuation.finish(throwing: error)
            }
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
    }

    func cancel() {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            cancelled = true
            acceptingAudio = false
            converter.discard()
            inputContinuation?.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            resultsTask = nil
            updateContinuation.finish()
            defer { self.analyzer = nil }
            return self.analyzer
        }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    /// Called with `lock` held. No raw audio or recognizer output is logged.
    private func failAudioLocked(_ error: Error) -> SpeechAnalyzer? {
        acceptingAudio = false
        cancelled = true
        converter.discard()
        // Publish the failure before ending analyzer input. Otherwise its
        // results stream could end normally first and hide the dropped audio.
        updateContinuation.finish(throwing: error)
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        Log.voice.error("dictation audio conversion failed")
        return analyzer
    }

    private func consumeResults() async {
        do {
            switch module {
            case .advanced(let transcriber):
                for try await result in transcriber.results {
                    ingest(text: String(result.text.characters), isFinal: result.isFinal)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    ingest(text: String(result.text.characters), isFinal: result.isFinal)
                }
            }
            updateContinuation.finish()
        } catch {
            if lock.withLock({ cancelled }) || error is CancellationError {
                updateContinuation.finish()
            } else {
                updateContinuation.finish(throwing: error)
            }
        }
    }

    private func ingest(text: String, isFinal: Bool) {
        lock.withLock {
            guard !cancelled else { return }
            var volatileText = ""
            if isFinal {
                finalized = DictationTranscript.join(finalized, text)
            } else {
                volatileText = text
            }
            updateContinuation.yield(DictationUpdate(
                finalizedText: finalized, volatileText: volatileText))
        }
    }
}

/// One continuous PCM stream, including the resampler's final buffered audio.
/// Owners serialize append/finish/discard with their engine lifecycle lock.
/// Every returned buffer owns its storage; an audio tap may reuse its input
/// immediately after append returns, including when no conversion is needed.
final class DictationBufferConverter {
    private var converter: AVAudioConverter?
    private var ended = false

    func append(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard !ended else { throw CancellationError() }
        guard buffer.frameLength <= buffer.frameCapacity,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              format.sampleRate.isFinite, format.sampleRate > 0,
              buffer.format.channelCount > 0, format.channelCount > 0 else {
            throw Self.conversionFailure
        }
        guard buffer.frameLength > 0 else { return [] }
        var result: [AVAudioPCMBuffer] = []
        if let converter, converter.inputFormat != buffer.format || converter.outputFormat != format {
            result = try finishSegment()
        }
        if converter == nil {
            guard let created = AVAudioConverter(from: buffer.format, to: format) else {
                throw Self.conversionFailure
            }
            // Normal priming plus EOS draining preserves the recording's
            // intended duration and tail. `.none` can leave padding delay.
            created.primeMethod = .normal
            converter = created
        }
        guard let converter else { throw Self.conversionFailure }
        var consumed = false
        result.append(contentsOf: try drain(converter, ending: false) { _, inputStatus in
            guard !consumed else { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        })
        return result
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        guard !ended else { return [] }
        ended = true
        return try finishSegment()
    }

    func discard() {
        ended = true
        converter = nil
    }

    private func finishSegment() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        defer { self.converter = nil }
        return try drain(converter, ending: true) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
    }

    private func drain(_ converter: AVAudioConverter, ending: Bool,
                       input: @escaping AVAudioConverterInputBlock) throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096) else {
                throw Self.conversionFailure
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            guard error == nil, status != .error else { throw Self.conversionFailure }
            if output.frameLength > 0 { buffers.append(output) }
            switch status {
            case .endOfStream:
                guard ending else { throw Self.conversionFailure }
                return buffers
            case .inputRanDry:
                guard !ending else { throw Self.conversionFailure }
                return buffers
            case .haveData:
                guard output.frameLength > 0 else { throw Self.conversionFailure }
            case .error: throw Self.conversionFailure
            @unknown default: throw Self.conversionFailure
            }
        }
    }

    private static var conversionFailure: DictationFailure {
        .engine(String(localized: "Audio format conversion failed."))
    }
}

// MARK: - SFSpeechRecognizer engine (iOS 18–25 fallback)

/// The pre-iOS-26 Speech API. Unlike SpeechAnalyzer it needs the user's
/// speech-recognition authorization, and it re-reports the whole utterance on
/// every partial callback (so no accumulation here — the latest callback IS
/// the transcript). Recognition is ALWAYS forced on-device — the factory only
/// mints this engine when the device supports it, so Apple's local selection
/// cannot silently become a cloud request.
final class LegacyDictationEngine: DictationEngine {
    let updates: AsyncThrowingStream<DictationUpdate, Error>

    var label: String {
        let name = Locale.current.localizedString(forIdentifier: recognizer.locale.identifier)
            ?? recognizer.locale.identifier
        return String(localized: "Apple Speech · \(name)")
    }

    private let recognizer: SFSpeechRecognizer
    private let contextualStrings: [String]
    private let updateContinuation: AsyncThrowingStream<DictationUpdate, Error>.Continuation
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    init(recognizer: SFSpeechRecognizer, contextualStrings: [String] = []) {
        self.recognizer = recognizer
        self.contextualStrings = VoiceVocabulary.normalized(contextualStrings)
        (updates, updateContinuation) = AsyncThrowingStream.makeStream()
    }

    func prepare(onProgress _: @escaping @Sendable (DictationPreparation) -> Void) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationFailure.speechRecognitionDenied }
    }

    func start() async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        // Unconditional — never fall back to Apple's server (see class doc).
        request.requiresOnDeviceRecognition = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    updateContinuation.yield(DictationUpdate(finalizedText: text, volatileText: ""))
                    updateContinuation.finish()
                    return
                }
                updateContinuation.yield(DictationUpdate(finalizedText: "", volatileText: text))
            }
            if let error {
                // "No speech detected" / cancellation are clean ends of a
                // session, not failures worth an alert.
                let code = (error as NSError).code
                if cancelled || code == 216 || code == 1110 || code == 301 {
                    updateContinuation.finish()
                } else {
                    updateContinuation.finish(throwing: error)
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finishAudio() async {
        // The task delivers its final result after endAudio(), which ends
        // `updates` in the handler above — the controller awaits that.
        request?.endAudio()
    }

    func cancel() {
        cancelled = true
        request?.endAudio()
        task?.cancel()
        updateContinuation.finish()
    }
}

// MARK: - Language catalog (Settings picker)

/// Every locale some engine on this device can transcribe, deduplicated
/// across the three engines and sorted by display name. Async because the
/// iOS 26 module lists are.
enum VoiceLocaleCatalog {
    struct Option: Identifiable, Equatable {
        /// BCP-47 identifier ("en-US", "zh-CN") — stored in settings.
        let id: String
        /// Localized display name in the user's UI language.
        let name: String
    }

    static func options() async -> [Option] {
        var ids = Set<String>()
        if #available(iOS 26.0, *) {
            for locale in await SpeechTranscriber.supportedLocales {
                ids.insert(locale.identifier(.bcp47))
            }
            for locale in await DictationTranscriber.supportedLocales {
                ids.insert(locale.identifier(.bcp47))
            }
        }
        for locale in SFSpeechRecognizer.supportedLocales() {
            // Only locales the legacy engine can do ON-DEVICE — the server
            // path is never used (see DictationEngineFactory), so a locale
            // that would need it must not be offered.
            guard SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true else {
                continue
            }
            ids.insert(locale.identifier(.bcp47))
        }
        let ui = Locale.current
        return ids
            .map { Option(id: $0, name: ui.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
