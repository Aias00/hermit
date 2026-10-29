import AVFoundation
import Foundation
import Testing
@testable import Moshpit

@Suite("Local dictation PCM conversion")
struct DictationBufferConverterTests {
    private func format(rate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: false))
    }

    private func buffer(frames: Int, rate: Double = 48_000, channels: AVAudioChannelCount = 2,
                        value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format(rate: rate, channels: channels),
                                                  frameCapacity: AVAudioFrameCount(max(1, frames))))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<Int(channels) {
            buffer.floatChannelData?[index].initialize(repeating: value, count: frames)
        }
        return buffer
    }

    private func samples(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        try buffers.flatMap { buffer in
            let data = try #require(buffer.floatChannelData?[0])
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
    }

    private func endPulse(frames: Int, rate: Double, chunkSize: Int) throws -> [Float] {
        let converter = DictationBufferConverter()
        let output = try format()
        var converted: [AVAudioPCMBuffer] = []
        for start in stride(from: 0, to: frames, by: chunkSize) {
            let count = min(chunkSize, frames - start)
            let input = try buffer(frames: count, rate: rate, value: 0)
            for channel in 0..<2 {
                for index in 0..<count where start + index >= frames - 60 {
                    input.floatChannelData?[channel][index] = 0.75
                }
            }
            converted.append(contentsOf: try converter.append(input, to: output))
        }
        converted.append(contentsOf: try converter.finish())
        return try samples(converted)
    }

    @Test("EOS preserves duration and the last sound, independent of microphone chunk boundaries",
          arguments: [48, 480, 4_800, 48_000])
    func preservesShortTail(frames: Int) throws {
        let whole = try endPulse(frames: frames, rate: 48_000, chunkSize: frames)
        let chunked = try endPulse(frames: frames, rate: 48_000, chunkSize: max(1, frames / 10))
        #expect(whole.count == frames / 3)
        #expect(chunked.count == whole.count)
        #expect(zip(whole, chunked).allSatisfy { abs($0 - $1) < 0.000_01 })
        // All earlier input is silence, so this checks actual tail content,
        // not just frame counts that could be satisfied by adding zeros.
        #expect(whole.suffix(20).contains { abs($0) > 0.1 })
    }

    @Test("A noninteger resampling ratio preserves cumulative duration and chunk invariance",
          arguments: [4_410, 48_000])
    func nonintegerRatio(frames: Int) throws {
        let whole = try endPulse(frames: frames, rate: 44_100, chunkSize: frames)
        let chunked = try endPulse(frames: frames, rate: 44_100, chunkSize: 127)
        let expected = Int((Double(frames) * 16_000 / 44_100).rounded())
        #expect(whole.count == expected)
        #expect(chunked.count == expected)
        #expect(zip(whole, chunked).allSatisfy { abs($0 - $1) < 0.000_01 })
        #expect(whole.suffix(20).contains { abs($0) > 0.1 })
    }

    @Test("A route format change drains each old segment before starting the next one")
    func inputFormatChangePreservesTails() throws {
        let converter = DictationBufferConverter()
        let target = try format()
        var output = try converter.append(buffer(frames: 4_800, value: 0.25), to: target)
        output += try converter.append(buffer(frames: 4_410, rate: 44_100, channels: 1, value: -0.5), to: target)
        output += try converter.append(buffer(frames: 1_600, rate: 16_000, channels: 1, value: 0.125), to: target)
        output += try converter.finish()
        let result = try samples(output)
        #expect(result.count == 4_800)
        #expect(result[1_599] > 0.1)
        #expect(result[3_199] < -0.2)
        #expect(abs(result[4_799] - 0.125) < 0.000_01)
    }

    @Test("An output format change returns the old tail with its original format")
    func outputFormatChangePreservesOwnership() throws {
        let converter = DictationBufferConverter()
        var output = try converter.append(buffer(frames: 4_800), to: format())
        let transition = try converter.append(buffer(frames: 4_800), to: format(rate: 48_000, channels: 2))
        #expect(transition.first?.format.sampleRate == 16_000)
        output += transition
        output += try converter.finish()
        #expect(output.filter { $0.format.sampleRate == 16_000 }.reduce(0) { $0 + Int($1.frameLength) } == 1_600)
        #expect(output.filter { $0.format.sampleRate == 48_000 }.reduce(0) { $0 + Int($1.frameLength) } == 4_800)
    }

    @Test("Matching-format output owns its storage after the microphone reuses its buffer")
    func matchingFormatCopiesAudio() throws {
        let converter = DictationBufferConverter()
        let input = try buffer(frames: 4_800, rate: 16_000, channels: 1, value: 0.25)
        let output = try converter.append(input, to: input.format) + converter.finish()
        input.floatChannelData?[0].update(repeating: -0.75, count: Int(input.frameLength))
        let result = try samples(output)
        #expect(result.count == 4_800)
        #expect(result.allSatisfy { abs($0 - 0.25) < 0.000_01 })
    }

    @Test("Empty input produces no audio; a finished converter cannot be revived")
    func emptyAndFinished() throws {
        let converter = DictationBufferConverter()
        #expect(try converter.append(buffer(frames: 0), to: format()).isEmpty)
        #expect(try converter.finish().isEmpty)
        #expect(try converter.finish().isEmpty)
        #expect(throws: CancellationError.self) {
            try converter.append(buffer(frames: 480), to: format())
        }
    }

    @Test("Cancellation discards the filter tail and rejects late microphone buffers")
    func discardDoesNotDrain() throws {
        let converter = DictationBufferConverter()
        let before = try converter.append(buffer(frames: 4_800), to: format())
        #expect(before.reduce(0) { $0 + Int($1.frameLength) } < 1_600)
        converter.discard()
        #expect(try converter.finish().isEmpty)
        #expect(throws: CancellationError.self) {
            try converter.append(buffer(frames: 480), to: format())
        }
    }
}
