import Foundation
import Testing
@testable import Moshpit

@Suite("Dictation metrics")
struct DictationMetricsTests {
    @Test("Preparation, first text and finalization measure separate intervals")
    func separateIntervals() {
        var metrics = DictationMetrics(isRetry: false, at: 10)
        metrics.prepared(engine: "test", at: 12)
        metrics.beganRecognition(at: 13)
        metrics.receivedText(at: 14)
        metrics.receivedText(at: 16)
        metrics.capturedAudio(duration: 4)
        metrics.beganFinalization(at: 17)
        metrics.ended(.completed, at: 19)
        #expect(metrics.preparationSeconds == 2)
        #expect(metrics.firstTextSeconds == 1)
        #expect(metrics.audioSeconds == 4)
        #expect(metrics.finalizationSeconds == 2)
        #expect(metrics.totalSeconds == 9)
    }

    @Test("Cancellation cannot later become a successful or longer attempt")
    func cancellationIsTerminal() {
        var metrics = DictationMetrics(isRetry: false, at: 1)
        metrics.prepared(engine: "original", at: 2)
        metrics.beganRecognition(at: 2)
        metrics.beganFinalization(at: 3)
        metrics.ended(.cancelled, at: 4)
        let cancelled = metrics
        metrics.prepared(engine: "late", at: 10)
        metrics.receivedText(at: 10)
        metrics.capturedAudio(duration: 20)
        metrics.ended(.completed, at: 20)
        #expect(metrics == cancelled)
        #expect(metrics.finalizationSeconds == nil)
    }

    @Test("Retry starts fresh while referring to the same recording length")
    func retryHasItsOwnTimeline() {
        var first = DictationMetrics(isRetry: false, at: 0)
        first.capturedAudio(duration: 6)
        first.ended(.completed, at: 9)
        var retry = DictationMetrics(isRetry: true, at: 20)
        retry.capturedAudio(duration: first.audioSeconds)
        retry.prepared(engine: "second", at: 21)
        retry.beganRecognition(at: 21)
        retry.beganFinalization(at: 21)
        retry.receivedText(at: 24)
        retry.ended(.completed, at: 24)
        #expect(first.id != retry.id)
        #expect(retry.isRetry)
        #expect(retry.audioSeconds == 6)
        #expect(retry.firstTextSeconds == 3)
        #expect(retry.finalizationSeconds == 3)
        #expect(retry.totalSeconds == 4)
    }

    @Test("Missing, invalid or backwards timing never appears as zero-speed success")
    func unavailableMeasurements() {
        var metrics = DictationMetrics(isRetry: false, at: 5)
        metrics.receivedText(at: 6)
        metrics.capturedAudio(duration: .infinity)
        metrics.capturedAudio(duration: -1)
        metrics.ended(.failed, at: 4)
        #expect(metrics.firstTextSeconds == nil)
        #expect(metrics.audioSeconds == nil)
        #expect(metrics.totalSeconds == nil)
        #expect(metrics.finalizationSeconds == nil)
    }
}
