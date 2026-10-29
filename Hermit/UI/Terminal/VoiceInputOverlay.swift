import SwiftUI
import UIKit

/// Recognition updates may replace an untouched review, never a manual edit.
struct DictationReviewDraft: Equatable {
    private(set) var baseline = ""
    var text = ""
    var hasEdits: Bool { text != baseline }

    mutating func receive(_ transcript: String) {
        guard !hasEdits else { return }
        baseline = transcript
        text = transcript
    }

    mutating func undoEdits() { text = baseline }
}

extension DictationRequest {
    /// A per-recording choice must also reach Apple's fallback if a local
    /// Whisper model cannot load. No saved preference is changed here.
    func selectingReviewLanguage(_ id: String) -> Self {
        var request = self
        guard id != "auto" else {
            request.appleLocaleId = ""
            request.whisperLanguage = ""
            return request
        }
        request.whisperLanguage = VoiceLanguageResolver.whisperCode(forIdentifier: id) ?? id
        if engine == .apple {
            request.appleLocaleId = id
        } else if VoiceLanguageResolver.whisperCode(stored: appleLocaleId) != request.whisperLanguage {
            request.appleLocaleId = id == "zh" ? "zh-CN" : id == "yue" ? "yue-Hant-HK" : id
        }
        return request
    }
}

/// Recording and review stay local. Only Add to Draft accepts this text;
/// the shared paper plane remains the action that sends it to the terminal.
struct DictationOverlayView: View {
    let controller: VoiceDictationController
    let onCancel: () -> Void
    let onInsert: (String) -> Void
    let onStop: () -> Void
    let onRetry: (DictationRequest) -> Void
    let onReviewFocus: () -> Void
    let initialRequest: DictationRequest
    var isFinishing = false

    @State private var review = DictationReviewDraft()
    @State private var selectedRequest = DictationRequest()
    @State private var languages: [VoiceLocaleCatalog.Option] = []
    @FocusState private var reviewFocused: Bool

    private var isReview: Bool {
        switch controller.phase {
        case .ready, .interrupted, .failed: return true
        default: return false
        }
    }
    private var busy: Bool { isFinishing || controller.isReplaying || !isReview }
    private var languageID: String {
        let code = selectedRequest.engine == .apple
            ? selectedRequest.appleLocaleId : selectedRequest.whisperLanguage
        return code.isEmpty ? "auto" : code
    }
    private var languageName: String {
        if languageID == "auto" { return String(localized: "Automatic") }
        return Locale.current.localizedString(forIdentifier: languageID) ?? languageID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            languageControls
            actions
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Ink.modalBG.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Ink.cardBorder, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-overlay")
        .onAppear {
            selectedRequest = controller.currentRequest ?? initialRequest
            review.receive(controller.transcript)
        }
        .onChange(of: controller.transcript) { _, value in review.receive(value) }
        .onChange(of: controller.currentRequest) { _, value in
            if let value { selectedRequest = value }
        }
        .onChange(of: reviewFocused) { _, focused in
            if focused { onReviewFocus() }
        }
        .task {
            if initialRequest.engine == .apple {
                languages = await VoiceLocaleCatalog.options()
            } else {
                languages = WhisperLanguageCatalog.options().map { .init(id: $0.id, name: $0.name) }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if controller.isReplaying {
                ProgressView().controlSize(.mini).tint(Ink.accent)
                statusLabel(String(localized: "Recognizing recording again…"), tint: Ink.secondary)
            } else {
                switch controller.phase {
                case .idle, .starting:
                    statusLabel(String(localized: "STARTING…"), tint: Ink.meta)
                case .downloadingModel(let progress):
                    ProgressView().controlSize(.mini).tint(Ink.accent)
                    statusLabel(String(localized: "DOWNLOADING SPEECH MODEL \(Int(progress * 100))%"), tint: Ink.secondary)
                case .loadingModel:
                    ProgressView().controlSize(.mini).tint(Ink.accent)
                    statusLabel(String(localized: "LOADING SPEECH MODEL…"), tint: Ink.secondary)
                case .listening:
                    PulsingDot()
                    statusLabel(String(localized: "LISTENING"), tint: Ink.accent)
                case .finishing:
                    ProgressView().controlSize(.mini).tint(Ink.accent)
                    statusLabel(String(localized: "FINISHING…"), tint: Ink.secondary)
                case .ready:
                    statusLabel(String(localized: "Review recognized text"), tint: Ink.accent)
                case .interrupted:
                    statusLabel(String(localized: "INTERRUPTED"), tint: Ink.warn)
                case .failed:
                    statusLabel(String(localized: "VOICE INPUT"), tint: Ink.warn)
                }
            }
            Spacer(minLength: 0)
            if !controller.engineLabel.isEmpty {
                Text(controller.engineLabel)
                    .font(Face.mono(9, .medium)).foregroundStyle(Ink.tertiary)
                    .lineLimit(1).truncationMode(.head)
                    .accessibilityIdentifier("dictation-engine-label")
            }
            if controller.isListening && !controller.isReplaying {
                DictationLevelMeter(level: controller.level)
            }
        }
    }

    private func statusLabel(_ text: String, tint: Color) -> some View {
        Text(text).font(Face.text(12, .semibold)).foregroundStyle(tint).lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let failure) = controller.phase {
            Text(failure.message).font(Face.text(12)).foregroundStyle(Ink.warn)
                .fixedSize(horizontal: false, vertical: true)
            if failure == .microphoneDenied || failure == .speechRecognitionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    onCancel()
                }.font(Face.text(12, .semibold)).foregroundStyle(Ink.accent)
            }
        }
        if isReview {
            TextEditor(text: $review.text)
                .font(Face.mono(13)).foregroundStyle(Ink.primary)
                .scrollContentBackground(.hidden)
                .frame(height: 82)
                .background(Ink.neutralFill, in: RoundedRectangle(cornerRadius: 8))
                .focused($reviewFocused)
                .disabled(isFinishing)
                .accessibilityLabel("Review recognized text")
                .accessibilityIdentifier("dictation-review-editor")
            if review.text.isEmpty {
                Text("No speech was recognized.")
                    .font(Face.text(12)).foregroundStyle(Ink.placeholder)
            }
        } else if !controller.transcript.isEmpty {
            ScrollView {
                Text(controller.transcript)
                    .font(Face.mono(13)).foregroundStyle(Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60).defaultScrollAnchor(.bottom)
            .accessibilityIdentifier("dictation-transcript")
        } else {
            Text("Speak, then stop to review the text.")
                .font(Face.text(13)).foregroundStyle(Ink.placeholder)
        }
        if controller.isTakingLonger {
            Text("Still recognizing. Your previous text is kept.")
                .font(Face.text(12)).foregroundStyle(Ink.secondary)
        }
    }

    @ViewBuilder
    private var languageControls: some View {
        HStack(spacing: 12) {
            Menu {
                languageOption("auto", name: String(localized: "Automatic"))
                let common = selectedRequest.engine == .apple ? ["zh-CN", "en-US"] : ["zh", "en"]
                ForEach(common, id: \.self) { code in
                    languageOption(code, name: Locale.current.localizedString(forIdentifier: code) ?? code)
                }
                if !languages.isEmpty {
                    Menu("More languages") {
                        ForEach(languages.filter { !common.contains($0.id) }) { option in
                            languageOption(option.id, name: option.name)
                        }
                    }
                }
            } label: {
                Label(languageName, systemImage: "globe").lineLimit(1)
            }
            .disabled(busy || review.hasEdits)
            .accessibilityIdentifier("dictation-language")
            .accessibilityValue(languageID)
            if isReview {
                Button("Recognize again") {
                    reviewFocused = false
                    onRetry(selectedRequest)
                }
                .disabled(busy || review.hasEdits || !controller.canRetryRecording)
                .accessibilityIdentifier("dictation-retry")
                Spacer(minLength: 0)
                if !controller.originalTranscript.isEmpty {
                    Button("Original text") {
                        reviewFocused = false
                        controller.restoreOriginalTranscript()
                    }
                    .disabled(busy || review.hasEdits || controller.transcript == controller.originalTranscript)
                    .accessibilityIdentifier("dictation-original")
                }
            }
        }
        .font(Face.text(12, .medium)).foregroundStyle(Ink.accent)
        if isReview {
            if review.hasEdits {
                HStack(spacing: 8) {
                    Text("Undo edits before recognizing again.").foregroundStyle(Ink.secondary)
                    Spacer(minLength: 0)
                    Button("Undo edits") { review.undoEdits() }
                        .accessibilityIdentifier("dictation-undo-edits")
                }.font(Face.text(11))
            } else if let reason = controller.retryUnavailableReason {
                Text(reason).font(Face.text(11)).foregroundStyle(Ink.secondary)
            } else {
                Text(selectedRequest.engine == .apple && languageID == "auto"
                     ? "Automatic follows your system and keyboard languages. This choice applies to this recording only."
                     : "Language applies to this recording only.")
                    .font(Face.text(11)).foregroundStyle(Ink.secondary)
            }
        }
    }

    private func languageOption(_ id: String, name: String) -> some View {
        Button {
            selectedRequest = selectedRequest.selectingReviewLanguage(id)
        } label: {
            if languageID == id { Label(name, systemImage: "checkmark") }
            else { Text(name) }
        }
        .accessibilityIdentifier("dictation-language-\(id)")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            pillButton(String(localized: "Cancel"), prominent: false) {
                reviewFocused = false
                onCancel()
            }.accessibilityIdentifier("dictation-cancel")
            Spacer(minLength: 0)
            if controller.isListening && !controller.isReplaying {
                pillButton(String(localized: "Stop and review"), prominent: true,
                           systemImage: "stop.fill", disabled: isFinishing, action: onStop)
                    .accessibilityIdentifier("dictation-stop")
            } else if isReview {
                let failed = { if case .failed = controller.phase { return true }; return false }()
                pillButton(failed ? String(localized: "Keep recognized text") : String(localized: "Add to Draft"),
                           prominent: true, systemImage: "text.insert",
                           disabled: isFinishing || review.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    reviewFocused = false
                    onInsert(review.text)
                }.accessibilityIdentifier(failed ? "dictation-keep-partial" : "dictation-insert")
            }
        }
    }

    private func pillButton(_ label: String, prominent: Bool,
                            systemImage: String? = nil, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
                Text(label).font(Face.text(13, .semibold))
            }
            .foregroundStyle(prominent ? Color(hex: "090B0D") : Ink.primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(prominent ? AnyShapeStyle(Ink.accent) : AnyShapeStyle(Ink.neutralFill), in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Ink.groupBorder, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Bits

/// The red-dot equivalent in Hermit's palette: an accent dot breathing at
/// recording cadence.
private struct PulsingDot: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Ink.accent)
            .frame(width: 7, height: 7)
            .shadow(color: Ink.accent.opacity(0.8), radius: 3)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// Five capsules dancing with mic loudness — center-weighted so it reads as
/// a voice waveform, not a VU bar.
struct DictationLevelMeter: View {
    /// 0…1 loudness from the controller.
    let level: Float

    private static let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Ink.accent)
                    .frame(width: 3, height: 3 + 13 * Self.weights[index] * CGFloat(level))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}
