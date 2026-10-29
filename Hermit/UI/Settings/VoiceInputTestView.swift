import SwiftUI
import UIKit

/// A standalone recording/review workspace. It has no terminal session or
/// send callback; accepting a transcript only retains a local test result.
@MainActor
struct VoiceInputTestView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller = VoiceInputTestView.makeController()
    @State private var sessionRequest = DictationRequest()
    @State private var isShowingSession = false
    @State private var savedResult = ""
    @State private var didCopy = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration: UInt64 = 0
    @State private var hasReviewEdits = false
    @State private var attempts: [TestAttempt] = []

    private struct TestAttempt: Identifiable {
        let metrics: DictationMetrics
        let text: String
        var id: UUID { metrics.id }
    }

    private var selectedEngine: VoiceEngineKind {
        isShowingSession ? (controller.currentRequest ?? sessionRequest).engine : settings.voiceEngine
    }

    var body: some View {
        Form {
            FormGroup(title: "RECOGNITION") {
                LabeledContent("Recognition", value: selectedEngine.displayName)
                    .accessibilityIdentifier("voice-test-engine")
                if selectedEngine == .doubao {
                    Text("When you stop and transcribe, this recording is uploaded to Volcengine. Recognition uses your saved API key and may incur service charges.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                        .accessibilityIdentifier("voice-test-disclosure")
                } else {
                    Text("Recognition runs on this device. You can review and copy the result here without connecting to a host.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                        .accessibilityIdentifier("voice-test-disclosure")
                }
            }

            FormGroup(title: "RECORDING TEST") {
                if isShowingSession {
                    DictationOverlayView(
                        controller: controller,
                        onCancel: cancelRecording,
                        onInsert: keepResult,
                        onStop: stopRecording,
                        onRetry: retryRecording,
                        onReviewFocus: {},
                        initialRequest: sessionRequest,
                        isFinishing: operationTask != nil,
                        acceptTitle: String(localized: "Keep result"),
                        onReviewEditsChange: { hasReviewEdits = $0 })
                        .padding(.vertical, 6)
                } else {
                    Button {
                        startRecording()
                    } label: {
                        Label("Start recording", systemImage: "mic.fill")
                    }
                    .accessibilityIdentifier("voice-test-start")
                    Text("Speak a short sentence, stop, then review the recognized text.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }

            if !savedResult.isEmpty {
                FormGroup(title: "TEST RESULT") {
                    Text(savedResult)
                        .font(.body).foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("voice-test-result")
                    Button {
                        UIPasteboard.general.string = savedResult
                        didCopy = true
                    } label: {
                        Label(didCopy ? String(localized: "Copied") : String(localized: "Copy result"),
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("voice-test-copy")
                }
            }

            if isShowingSession, controller.canRetryRecording {
                FormGroup(title: "COMPARE THIS RECORDING") {
                    Menu {
                        Button("Apple (built in)") { compareLocally(engine: .apple) }
                            .accessibilityIdentifier("voice-test-compare-apple")
                        ForEach(WhisperModelStore.catalog().filter(\.isInstalled)) { model in
                            Button("Whisper · \(model.name)") {
                                compareLocally(engine: .whisper, model: model.id)
                            }
                        }
                    } label: {
                        Label("Compare local recognition", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(operationTask != nil || hasReviewEdits)
                    .accessibilityIdentifier("voice-test-compare")
                    Text(hasReviewEdits
                         ? String(localized: "Undo edits before recognizing again.")
                         : String(localized: "Reuses this recording on this device. Your default engine stays unchanged."))
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }

            if let metrics = controller.metrics, metrics.outcome != nil {
                FormGroup(title: "LAST RECOGNITION TIMING") {
                    if !metrics.engineLabel.isEmpty {
                        LabeledContent("Recognition", value: metrics.engineLabel)
                    }
                    timingRow("Audio duration", seconds: metrics.audioSeconds)
                    timingRow("Engine preparation", seconds: metrics.preparationSeconds)
                    timingRow("First text", seconds: metrics.firstTextSeconds)
                    timingRow(metrics.isRetry ? "Replay processing" : "After stopping",
                              seconds: metrics.finalizationSeconds)
                    timingRow("Total time", seconds: metrics.totalSeconds)
                    Text("Timing helps compare speed. Check the words yourself to judge accuracy.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
                .accessibilityIdentifier("voice-test-timing")
            }

            if attempts.count > 1 {
                FormGroup(title: "COMPARISON RESULTS") {
                    ForEach(attempts) { attempt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(attempt.metrics.engineLabel)
                                .font(.footnote.weight(.semibold)).foregroundStyle(Ink.accent)
                            Text(attempt.metrics.isRetry
                                 ? String(localized: "Recording replay") : String(localized: "Live recording"))
                                .font(.footnote).foregroundStyle(Ink.meta)
                            Text(attempt.text).textSelection(.enabled)
                            timingRow(attempt.metrics.isRetry ? "Replay processing" : "After stopping",
                                      seconds: attempt.metrics.finalizationSeconds)
                        }
                    }
                    Text("Live results measure waiting after Stop; replay results measure processing saved audio.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    Text("Results stay on this screen and are cleared when you start a new recording.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
                .accessibilityIdentifier("voice-test-comparisons")
            }


        }
        .moshpitForm()
        .navigationTitle("Recording test")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onDisappear { cancelRecording() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelRecording() }
        }
        .onChange(of: controller.metrics) { _, _ in recordCompletedAttempt() }
    }

    private static func makeController() -> VoiceDictationController {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-MOSHPIT_VOICE_SETTINGS_TEST_PREVIEW") {
            return .previewForReviewUITest()
        }
        #endif
        return VoiceDictationController()
    }

    private func startRecording() {
        guard !isShowingSession, operationTask == nil else { return }
        controller.cancel()
        sessionRequest = settings.dictationRequest
        savedResult = ""
        attempts = []
        hasReviewEdits = false
        didCopy = false
        isShowingSession = true
        let request = sessionRequest
        perform { await controller.start(request) }
    }

    private func stopRecording() {
        guard isShowingSession, controller.isListening else { return }
        perform { await controller.stopForReview() }
    }

    private func retryRecording(_ request: DictationRequest) {
        guard isShowingSession, !hasReviewEdits else { return }
        perform { await controller.retry(request) }
    }

    private func compareLocally(engine: VoiceEngineKind, model: String = "") {
        guard engine != .doubao, isShowingSession, controller.canRetryRecording,
              operationTask == nil, !hasReviewEdits else { return }
        var request = controller.currentRequest ?? sessionRequest
        request.engine = engine
        request.whisperModelId = model
        request.contextualStrings = settings.voiceContextualStrings
        retryRecording(request)
    }

    private func timingRow(_ title: LocalizedStringKey, seconds: TimeInterval?) -> some View {
        LabeledContent(title, value: seconds.map {
            $0.formatted(.number.precision(.fractionLength(2))) + " s"
        } ?? "—")
        .font(.footnote)
    }

    private func keepResult(_ text: String) {
        guard operationTask == nil else { return }
        switch controller.phase {
        case .ready, .failed, .interrupted: break
        default: return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        savedResult = text
        didCopy = false
        cancelRecording()
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard operationTask == nil else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        operationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await operation()
            guard !Task.isCancelled, operationGeneration == generation else { return }
            recordCompletedAttempt()
            operationTask = nil
        }
    }

    private func recordCompletedAttempt() {
        guard isShowingSession, controller.phase == .ready, let metrics = controller.metrics,
              metrics.outcome == .completed, !controller.transcript.isEmpty,
              !attempts.contains(where: { $0.id == metrics.id }) else { return }
        attempts.append(TestAttempt(metrics: metrics, text: controller.transcript))
        if attempts.count > 8 { attempts.removeFirst() }
    }

    private func cancelRecording() {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        controller.cancel()
        isShowingSession = false
    }
}
