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
    @State private var referenceText = ""
    @State private var keyTerms = ""
    @State private var ignorePunctuation = true
    @State private var accuracyResults: [UUID: RecognitionAccuracy.Result] = [:]
    @State private var accuracyTask: Task<Void, Never>?
    @State private var accuracyGeneration: UInt64 = 0
    @State private var accuracyMessage: String?
    @State private var showsAccuracyControls = false
    @FocusState private var accuracyField: AccuracyField?
    private enum AccuracyField { case reference, terms }

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

            if !attempts.isEmpty {
                accuracyControls
                FormGroup(title: "COMPARISON RESULTS") {
                    Text("原始识别结果")
                        .font(.footnote).foregroundStyle(Ink.meta)
                        .accessibilityIdentifier("voice-test-comparisons")
                    ForEach(attempts) { attempt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(attempt.metrics.engineLabel)
                                .font(.footnote.weight(.semibold)).foregroundStyle(Ink.accent)
                            Text(attempt.metrics.isRetry
                                 ? String(localized: "Recording replay") : String(localized: "Live recording"))
                                .font(.footnote).foregroundStyle(Ink.meta)
                            Text(attempt.text).textSelection(.enabled)
                            if let result = accuracyResults[attempt.id] {
                                accuracySummary(result)
                            }
                            timingRow(attempt.metrics.isRetry ? "Replay processing" : "After stopping",
                                      seconds: attempt.metrics.finalizationSeconds)
                        }
                    }
                    Text("Live results measure waiting after Stop; replay results measure processing saved audio.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    Text("准确率对照使用原始识别结果，手动修改的文字不参与评分。")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    Text("Results stay on this screen and are cleared when you start a new recording.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }


        }
        .moshpitForm()
        .navigationTitle("Recording test")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onDisappear { cancelRecording(); invalidateAccuracy() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                cancelRecording()
                if accuracyTask != nil { invalidateAccuracy() }
            }
        }
        .onChange(of: controller.metrics) { _, _ in recordCompletedAttempt() }
        .onChange(of: referenceText) { _, _ in invalidateAccuracy() }
        .onChange(of: keyTerms) { _, _ in invalidateAccuracy() }
        .onChange(of: ignorePunctuation) { _, _ in invalidateAccuracy() }
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
        accuracyField = nil
        controller.cancel()
        sessionRequest = settings.dictationRequest
        savedResult = ""
        attempts = []
        invalidateAccuracy()
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

    private var accuracyControls: some View {
        FormGroup(title: "准确率对照", footer: "仅对原始识别文字评分，不计手动编辑；内容只保留在当前测试页。") {
            DisclosureGroup(isExpanded: $showsAccuracyControls) {
                TextEditor(text: $referenceText)
                    .focused($accuracyField, equals: .reference)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .frame(minHeight: 90, maxHeight: 140)
                    .accessibilityLabel("标准原文")
                    .accessibilityIdentifier("voice-test-reference")
                Text("标准原文和识别结果各限 2,000 个字符。")
                    .font(.footnote).foregroundStyle(Ink.meta)
                TextField("技术词／命令／参数，每行一个", text: $keyTerms, axis: .vertical)
                    .focused($accuracyField, equals: .terms)
                    .lineLimit(2...4).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("voice-test-keywords")
                Toggle("忽略标点与空白", isOn: $ignorePunctuation)
                    .accessibilityIdentifier("voice-test-ignore-punctuation")
                Text("字符错误率越低越好，不是模型置信度。对比命令或参数时请关闭忽略；技术词区分大小写，只统计原文中出现的前 32 项。")
                    .font(.footnote).foregroundStyle(Ink.meta)
                Button(accuracyTask == nil ? "计算准确率对照" : "正在对比…", action: compareAccuracy)
                    .disabled(accuracyTask != nil || referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attempts.isEmpty)
                    .accessibilityIdentifier("voice-test-score")
                if let accuracyMessage {
                    Text(accuracyMessage).font(.footnote).foregroundStyle(Ink.warn)
                        .accessibilityIdentifier("voice-test-score-message")
                }
            } label: {
                Text("填写标准原文并计算")
                    .accessibilityIdentifier("voice-test-accuracy-controls")
            }
        }
    }

    private func invalidateAccuracy() {
        accuracyGeneration &+= 1
        accuracyTask?.cancel(); accuracyTask = nil
        accuracyResults = [:]; accuracyMessage = nil
    }

    private func compareAccuracy() {
        guard accuracyTask == nil, !attempts.isEmpty else { return }
        accuracyField = nil
        accuracyGeneration &+= 1
        let generation = accuracyGeneration
        let reference = referenceText, terms = keyTerms, ignore = ignorePunctuation
        let samples = attempts.map { ($0.id, $0.text) }
        accuracyMessage = nil
        accuracyTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                var results: [UUID: RecognitionAccuracy.Result] = [:]
                for (id, text) in samples {
                    guard !Task.isCancelled else { break }
                    if let result = RecognitionAccuracy.compare(reference: reference, recognized: text,
                                                                terms: terms, ignorePunctuation: ignore) {
                        results[id] = result
                    }
                }
                return results
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, generation == accuracyGeneration else { return }
            accuracyResults = results
            if results.count != samples.count {
                accuracyMessage = "部分结果无法对比：请检查原文是否含有效文字，且原文和识别结果均不超过 2,000 个字符。"
            }
            accuracyTask = nil
        }
    }

    private func accuracySummary(_ result: RecognitionAccuracy.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("字符错误率：" + result.errorRate.formatted(.percent.precision(.fractionLength(1))))
                .fontWeight(.semibold)
                .accessibilityIdentifier("voice-test-accuracy-result")
            Text("错字 \(result.substitutions) · 漏字 \(result.deletions) · 多字 \(result.insertions)")
            Text("末尾缺字（对齐估计）：\(result.trailingOmissions)")
            if result.numberCount > 0 {
                Text("数字片段保留：\(result.retainedNumberCount)/\(result.numberCount)")
            }
            if !result.retainedTerms.isEmpty || !result.missingTerms.isEmpty {
                Text("技术词保留：\(result.retainedTerms.count)/\(result.retainedTerms.count + result.missingTerms.count)")
                if !result.missingTerms.isEmpty { Text("未保留：" + result.missingTerms.joined(separator: "、")) }
            }
        }
        .font(.footnote).foregroundStyle(Ink.secondary)
        .accessibilityElement(children: .contain)
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
        invalidateAccuracy()
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
