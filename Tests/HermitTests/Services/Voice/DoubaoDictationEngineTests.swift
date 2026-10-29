import AVFoundation
import Foundation
import Testing
@testable import Moshpit

@Suite("Doubao recording lifecycle")
struct DoubaoDictationEngineTests {
    private actor Probe: DoubaoVoiceTranscribing {
        private(set) var recordings: [Data] = []
        private(set) var cancellationObserved = false
        var held = false
        var failure: DoubaoVoiceFailure?
        private var waiter: CheckedContinuation<Void, Never>?

        init(held: Bool = false, failure: DoubaoVoiceFailure? = nil) {
            self.held = held; self.failure = failure
        }
        func transcribe(wav: Data, apiKey: String, resourceID: String) async throws -> String {
            recordings.append(wav)
            if held { await withCheckedContinuation { waiter = $0 } }
            cancellationObserved = Task.isCancelled
            if let failure { throw failure }
            // Deliberately return even when cancelled: the engine, not just
            // a cooperative transport, must reject a late result.
            return "识别成功"
        }
        func release() { held = false; waiter?.resume(); waiter = nil }
    }

    private func pcm(frames: AVAudioFrameCount = 480, rate: Double = 48_000,
                     channels: AVAudioChannelCount = 2) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate, channels: channels, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            buffer.floatChannelData?[channel].initialize(repeating: 0.25, count: Int(frames))
        }
        return buffer
    }

    private func engine(_ probe: Probe) -> DoubaoDictationEngine {
        DoubaoDictationEngine(client: probe, loadAPIKey: { "unit-test-key" })
    }

    private func start(_ engine: DoubaoDictationEngine) async throws {
        try await engine.prepare { _ in }
        try await engine.start()
    }

    private func collect(_ engine: DoubaoDictationEngine) -> Task<[DictationUpdate], Error> {
        Task {
            var values: [DictationUpdate] = []
            for try await value in engine.updates { values.append(value) }
            return values
        }
    }

    private func uint(_ data: Data, at offset: Int, bytes: Int) -> UInt32 {
        data.dropFirst(offset).prefix(bytes).enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }

    @Test("Microphone buffers stay local until explicit finish and are sent as mono 16 kHz 16-bit WAV")
    func formatAndSingleUpload() async throws {
        let probe = Probe()
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        engine.append(try pcm(frames: 4_800))
        #expect(await probe.recordings.isEmpty)
        #expect(engine.bufferedAudioByteCount > 0)
        async let first: Void = engine.finishAudio()
        async let duplicate: Void = engine.finishAudio()
        _ = await (first, duplicate)
        let recordings = await probe.recordings
        #expect(recordings.count == 1)
        let wav = try #require(recordings.first)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        #expect(uint(wav, at: 20, bytes: 2) == 1) // PCM
        #expect(uint(wav, at: 22, bytes: 2) == 1) // mono
        #expect(uint(wav, at: 24, bytes: 4) == 16_000)
        #expect(uint(wav, at: 28, bytes: 4) == 32_000)
        #expect(uint(wav, at: 34, bytes: 2) == 16)
        #expect(uint(wav, at: 40, bytes: 4) == wav.count - 44)
        // EOS must drain the resampler's delayed tail. 0.1 seconds at 16 kHz
        // is exactly 1,600 PCM16 frames, plus the 44-byte WAV header.
        #expect(wav.count == 3_244)
        #expect(engine.bufferedAudioByteCount == 0)
        #expect(try await updates.value == [.init(finalizedText: "识别成功", volatileText: "")])
    }

    private func recordingWithEndPulse(frames: Int, chunkSize: Int) async throws -> Data {
        let probe = Probe()
        let engine = engine(probe)
        try await start(engine)
        for start in stride(from: 0, to: frames, by: chunkSize) {
            let count = min(chunkSize, frames - start)
            let buffer = try pcm(frames: AVAudioFrameCount(count))
            for channel in 0..<2 {
                for index in 0..<count {
                    buffer.floatChannelData?[channel][index] = start + index >= frames - 60 ? 0.75 : 0
                }
            }
            engine.append(buffer)
        }
        await engine.finishAudio()
        return try #require(await probe.recordings.first)
    }

    @Test("EOS preserves the final nonzero samples for short clips and all microphone chunk boundaries",
          arguments: [48, 480, 4_800, 48_000])
    func resamplerDrainsTail(frames: Int) async throws {
        let single = try await recordingWithEndPulse(frames: frames, chunkSize: frames)
        let chunked = try await recordingWithEndPulse(frames: frames, chunkSize: max(1, frames / 10))
        #expect(single.count == 44 + (frames / 3) * 2)
        #expect(chunked == single)
        // All earlier input is silence. A missing filter tail would therefore
        // remove the only speech-like energy in the 100 ms and 1 s fixtures.
        let samples = stride(from: 44, to: single.count, by: 2).map {
            Int16(bitPattern: UInt16(uint(single, at: $0, bytes: 2)))
        }
        #expect(samples.suffix(20).contains { abs(Int($0)) > 1_000 })
    }

    @Test("A microphone format change drains its old resampler before accepting the next segment")
    func formatChangeKeepsBothTails() async throws {
        let probe = Probe()
        let engine = engine(probe)
        try await start(engine)
        engine.append(try pcm(frames: 4_800, rate: 48_000, channels: 2))
        engine.append(try pcm(frames: 4_410, rate: 44_100, channels: 1))
        await engine.finishAudio()
        let wav = try #require(await probe.recordings.first)
        #expect(wav.count == 44 + 3_200 * 2)
        // The last sample of the first segment and the final segment both
        // retain their nonzero signal rather than becoming padding or loss.
        #expect(uint(wav, at: 44 + 1_599 * 2, bytes: 2) > 1_000)
        #expect(uint(wav, at: 44 + 3_199 * 2, bytes: 2) > 1_000)
    }

    @Test("Exactly two minutes remains accepted after draining, without exceeding the PCM byte bound")
    func exactDurationLimitIncludesDrain() async throws {
        let probe = Probe()
        let engine = engine(probe)
        try await start(engine)
        engine.append(try pcm(frames: 16_000 * 120, rate: 16_000, channels: 1))
        await engine.finishAudio()
        let wav = try #require(await probe.recordings.first)
        #expect(wav.count == DoubaoVoiceClient.maximumWAVBytes)
        #expect(engine.bufferedAudioByteCount == 0)
    }

    @Test("Cancel before finish discards audio; late mic callbacks cannot revive or upload it")
    func cancelledRecordingNeverUploads() async throws {
        let probe = Probe()
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        let buffer = try pcm()
        engine.append(buffer)
        engine.cancel()
        engine.append(buffer)
        await engine.finishAudio()
        #expect(engine.bufferedAudioByteCount == 0)
        #expect(await probe.recordings.isEmpty)
        #expect(try await updates.value.isEmpty)
    }

    @Test("A response arriving after cancellation cannot become a transcript")
    func lateResultIsDiscarded() async throws {
        let probe = Probe(held: true)
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        engine.append(try pcm())
        let finish = Task { await engine.finishAudio() }
        for _ in 0..<200 {
            if await !probe.recordings.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.recordings.count == 1)
        engine.cancel()
        #expect(try await updates.value.isEmpty)
        await probe.release()
        await finish.value
        #expect(await probe.cancellationObserved)
        #expect(engine.bufferedAudioByteCount == 0)
    }

    @Test("Exceeding two minutes rejects the whole recording, never a successful prefix")
    func durationLimitRejectsWholeRecording() async throws {
        let probe = Probe()
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        engine.append(try pcm(frames: 16_000, rate: 16_000, channels: 1))
        engine.append(try pcm(frames: 16_000 * 120, rate: 16_000, channels: 1))
        await engine.finishAudio()
        #expect(engine.bufferedAudioByteCount == 0)
        #expect(await probe.recordings.isEmpty)
        do { _ = try await updates.value; Issue.record("Expected a duration failure") }
        catch let failure as DictationFailure {
            #expect(failure == .engine(DoubaoVoiceFailure.recordingTooLong.localizedDescription))
        }
    }

    @Test("Provider failures preserve the safe actionable message for controller review")
    func providerFailureIsTyped() async throws {
        let probe = Probe(failure: .authentication)
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        engine.append(try pcm())
        await engine.finishAudio()
        do { _ = try await updates.value; Issue.record("Expected an authentication failure") }
        catch let failure as DictationFailure {
            #expect(failure == .engine(DoubaoVoiceFailure.authentication.localizedDescription))
        }
        #expect(await probe.recordings.count == 1)
    }

    @Test("An empty recording is rejected locally without spending an API request")
    func emptyRecordingNeverUploads() async throws {
        let probe = Probe()
        let engine = engine(probe)
        let updates = collect(engine)
        try await start(engine)
        await engine.finishAudio()
        #expect(await probe.recordings.isEmpty)
        do { _ = try await updates.value; Issue.record("Expected no speech") }
        catch let failure as DictationFailure {
            #expect(failure == .engine(DoubaoVoiceFailure.noSpeech.localizedDescription))
        }
    }
}
