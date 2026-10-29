import AVFoundation
import Foundation

/// Records locally and sends exactly once, only when the user stops for
/// transcription. The controller's separate recording cache supports an
/// explicit retry without microphone access or an automatic second upload.
final class DoubaoDictationEngine: DictationEngine, @unchecked Sendable {
    let updates: AsyncThrowingStream<DictationUpdate, Error>
    var label: String { String(localized: "Doubao · Cloud") }
    var finalizeTimeout: Duration { .seconds(95) }

    static let maximumDuration: TimeInterval = 120
    static let maximumPCMBytes = 16_000 * 2 * 120
    private enum State { case idle, prepared, recording, finishing, ended, cancelled }
    private let lock = NSLock()
    private var state: State = .idle
    private var pcm = Data()
    private var recordedDuration: TimeInterval = 0
    private var apiKey: String?
    private var resourceID: String
    private var requestTask: Task<String, Error>?
    private let converter = DoubaoPCMConverter()
    private let client: any DoubaoVoiceTranscribing
    private let loadAPIKey: @Sendable () async throws -> String
    private let continuation: AsyncThrowingStream<DictationUpdate, Error>.Continuation

    init(resourceID: String = DoubaoVoiceClient.defaultResourceID,
         client: any DoubaoVoiceTranscribing = DoubaoVoiceClient(),
         loadAPIKey: @escaping @Sendable () async throws -> String = {
             try await DoubaoVoiceCredentials.shared.apiKey()
         }) {
        self.resourceID = resourceID
        self.client = client
        self.loadAPIKey = loadAPIKey
        (updates, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Internal instrumentation contains only a count, never the recording.
    var bufferedAudioByteCount: Int { lock.withLock { pcm.count } }

    func prepare(onProgress: @escaping @Sendable (DictationPreparation) -> Void) async throws {
        try Task.checkCancellation()
        let resource = try DoubaoVoiceClient.validatedResourceID(resourceID)
        let key: String
        do { key = try DoubaoVoiceClient.validatedAPIKey(try await loadAPIKey()) }
        catch is CancellationError { throw CancellationError() }
        catch let error as DoubaoVoiceFailure { throw DictationFailure.engine(error.localizedDescription) }
        catch { throw DictationFailure.engine(DoubaoVoiceFailure.credentialsUnavailable.localizedDescription) }
        try Task.checkCancellation()
        try lock.withLock {
            guard state == .idle else { throw CancellationError() }
            apiKey = key
            resourceID = resource
            state = .prepared
        }
    }

    func start() async throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard state == .prepared else { throw CancellationError() }
            guard DoubaoPCMConverter.format != nil else {
                throw DictationFailure.engine(DoubaoVoiceFailure.audioConversion.localizedDescription)
            }
            state = .recording
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let failure: DoubaoVoiceFailure? = lock.withLock {
            guard state == .recording, buffer.frameLength > 0 else { return nil }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            guard seconds.isFinite, seconds > 0, buffer.format.channelCount > 0 else {
                discardRecording()
                return .audioConversion
            }
            guard seconds <= Self.maximumDuration - recordedDuration + 1e-8 else {
                discardRecording()
                return .recordingTooLong
            }
            do {
                // Conversion and mutation are both guarded. cancel/finish wait for
                // the current tap callback and late callbacks cannot refill pcm.
                let converted = try converter.append(buffer, maximumBytes: Self.maximumPCMBytes - pcm.count)
                pcm.append(converted)
                recordedDuration += seconds
                return nil
            } catch {
                discardRecording()
                return error as? DoubaoVoiceFailure ?? .audioConversion
            }
        }
        if let failure {
            continuation.finish(throwing: DictationFailure.engine(failure.localizedDescription))
        }
    }

    func finishAudio() async {
        // Install cancellation before creating the upload task: an already
        // cancelled caller must never briefly start a paid network request.
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { cancel(); return }
            let task: Task<String, Error>? = lock.withLock {
                guard state == .recording else { return nil }
                do {
                    // A resampler can retain the entire tail of a short clip.
                    // Deliver EOS and drain before testing for empty audio or
                    // creating the WAV; noDataNow only pauses conversion.
                    pcm.append(try converter.finish(maximumBytes: Self.maximumPCMBytes - pcm.count))
                } catch {
                    discardRecording()
                    let failure = error as? DoubaoVoiceFailure ?? .audioConversion
                    continuation.finish(throwing: DictationFailure.engine(failure.localizedDescription))
                    return nil
                }
                guard !pcm.isEmpty, let key = apiKey else {
                    discardRecording()
                    continuation.finish(throwing: DictationFailure.engine(DoubaoVoiceFailure.noSpeech.localizedDescription))
                    return nil
                }
                state = .finishing
                let wav = Self.wav(pcm: pcm)
                pcm.removeAll()
                apiKey = nil
                let resource = resourceID
                let client = client
                let task = Task {
                    try Task.checkCancellation()
                    return try await client.transcribe(wav: wav, apiKey: key, resourceID: resource)
                }
                requestTask = task
                return task
            }
            guard let task else { return }
            do {
                let text = try await task.value
                try Task.checkCancellation()
                lock.withLock {
                    guard state == .finishing else { return }
                    state = .ended
                    requestTask = nil
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continuation.finish(throwing: DictationFailure.engine(DoubaoVoiceFailure.noSpeech.localizedDescription))
                    } else {
                        continuation.yield(DictationUpdate(finalizedText: text, volatileText: ""))
                        continuation.finish()
                    }
                }
            } catch {
                lock.withLock {
                    guard state == .finishing else { return }
                    state = .ended
                    requestTask = nil
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        let failure = error as? DoubaoVoiceFailure ?? .network
                        continuation.finish(throwing: DictationFailure.engine(failure.localizedDescription))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            state = .cancelled
            pcm.removeAll()
            converter.discard()
            apiKey = nil
            let task = requestTask
            requestTask = nil
            return task
        }
        task?.cancel()
        continuation.finish()
    }

    /// Called with the lock held. Never retain or upload a successful prefix
    /// after exceeding the limit or failing to convert part of the recording.
    private func discardRecording() {
        state = .ended
        pcm.removeAll()
        converter.discard()
        apiKey = nil
    }

    private static func wav(pcm: Data) -> Data {
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        tag("RIFF"); number(UInt32(36 + pcm.count)); tag("WAVE")
        tag("fmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16))
        tag("data"); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

/// A finite-recording converter, rather than the shared live-preview helper.
/// Normal priming accounts for resampling filter delay. Every segment receives
/// endOfStream and is drained before upload or a microphone format change.
/// Owned by the engine and only touched while its recording lock is held.
private final class DoubaoPCMConverter {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16_000, channels: 1, interleaved: false)
    private var converter: AVAudioConverter?

    func append(_ buffer: AVAudioPCMBuffer, maximumBytes: Int) throws -> Data {
        var result = Data()
        if let converter, converter.inputFormat != buffer.format {
            result = try finish(maximumBytes: maximumBytes)
        }
        if converter == nil {
            guard let format = Self.format, let new = AVAudioConverter(from: buffer.format, to: format) else {
                throw DoubaoVoiceFailure.audioConversion
            }
            // .none is appropriate for some live consumers but leaves padding
            // delay in a finite recording even after EOS. .normal plus draining
            // preserves both its intended duration and the last speech samples.
            new.primeMethod = .normal
            converter = new
        }
        guard let converter else { throw DoubaoVoiceFailure.audioConversion }
        var consumed = false
        result.append(try drain(converter, maximumBytes: maximumBytes - result.count, ending: false) { _, status in
            guard !consumed else { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        })
        return result
    }

    func finish(maximumBytes: Int) throws -> Data {
        guard let converter else { return Data() }
        defer { self.converter = nil }
        return try drain(converter, maximumBytes: maximumBytes, ending: true) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    func discard() { converter = nil }

    private func drain(_ converter: AVAudioConverter, maximumBytes: Int, ending: Bool,
                       input: @escaping AVAudioConverterInputBlock) throws -> Data {
        guard let format = Self.format,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw DoubaoVoiceFailure.audioConversion
        }
        var result = Data()
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            guard error == nil, status != .error else { throw DoubaoVoiceFailure.audioConversion }
            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            guard byteCount <= maximumBytes - result.count else { throw DoubaoVoiceFailure.recordingTooLong }
            if byteCount > 0 {
                guard let samples = output.int16ChannelData?[0] else { throw DoubaoVoiceFailure.audioConversion }
                // Supported iOS architectures are little-endian.
                result.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount)
            }
            switch status {
            case .endOfStream:
                guard ending else { throw DoubaoVoiceFailure.audioConversion }
                return result
            case .inputRanDry:
                guard !ending else { throw DoubaoVoiceFailure.audioConversion }
                return result
            case .haveData:
                // Enforce progress, so a malformed converter cannot busy-loop.
                guard byteCount > 0 else { throw DoubaoVoiceFailure.audioConversion }
            case .error: throw DoubaoVoiceFailure.audioConversion
            @unknown default: throw DoubaoVoiceFailure.audioConversion
            }
        }
    }
}
