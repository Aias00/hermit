import Foundation

/// Numeric, per-attempt diagnostics. Never retains audio, recognized text,
/// vocabulary, device names or credentials. Times use monotonic uptime.
struct DictationMetrics: Equatable, Sendable, Identifiable {
    enum Outcome: String, Sendable { case completed, failed, interrupted, cancelled }

    let id: UUID
    let isRetry: Bool
    private(set) var engineLabel = ""
    private(set) var preparationSeconds: TimeInterval?
    private(set) var audioSeconds: TimeInterval?
    private(set) var firstTextSeconds: TimeInterval?
    private(set) var finalizationSeconds: TimeInterval?
    private(set) var totalSeconds: TimeInterval?
    private(set) var outcome: Outcome?

    private let startedAt: TimeInterval
    private var recognitionStartedAt: TimeInterval?
    private var finalizationStartedAt: TimeInterval?

    init(isRetry: Bool, at time: TimeInterval, id: UUID = UUID()) {
        self.id = id
        self.isRetry = isRetry
        startedAt = time
    }

    mutating func prepared(engine: String, at time: TimeInterval) {
        guard outcome == nil, preparationSeconds == nil else { return }
        engineLabel = engine
        preparationSeconds = elapsed(from: startedAt, to: time)
    }

    mutating func beganRecognition(at time: TimeInterval) {
        guard outcome == nil, recognitionStartedAt == nil else { return }
        recognitionStartedAt = time
    }

    mutating func receivedText(at time: TimeInterval) {
        guard outcome == nil, firstTextSeconds == nil, let recognitionStartedAt else { return }
        firstTextSeconds = elapsed(from: recognitionStartedAt, to: time)
    }

    mutating func capturedAudio(duration: TimeInterval?) {
        guard outcome == nil, let duration, duration.isFinite, duration >= 0 else { return }
        audioSeconds = duration
    }

    mutating func beganFinalization(at time: TimeInterval) {
        guard outcome == nil, finalizationStartedAt == nil else { return }
        finalizationStartedAt = time
    }

    mutating func ended(_ result: Outcome, at time: TimeInterval) {
        guard outcome == nil else { return }
        outcome = result
        totalSeconds = elapsed(from: startedAt, to: time)
        if result != .cancelled, let finalizationStartedAt {
            finalizationSeconds = elapsed(from: finalizationStartedAt, to: time)
        }
    }

    private func elapsed(from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        return end - start
    }
}
