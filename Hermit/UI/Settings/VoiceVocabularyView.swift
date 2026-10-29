import SwiftUI

/// Edits are local until Save. Invalid input remains visible for correction.
struct VoiceVocabularyView: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""
    @State private var hasLoaded = false
    @State private var lastSavedText: String?
    @FocusState private var editorFocused: Bool

    private var validation: VoiceVocabulary.Validation { VoiceVocabulary.validate(draft) }

    var body: some View {
        let result = validation
        Form {
            FormGroup(title: "LOCAL RECOGNITION") {
                Text("Add project names, tools and other short terms for supported Apple recognition and Whisper. Hints may help with technical words, but do not guarantee a transcription.")
                    .font(.footnote).foregroundStyle(Ink.meta)
                Text("This vocabulary stays on this device. It is not synced with iCloud or sent to Doubao.")
                    .font(.footnote).foregroundStyle(Ink.meta)
                    .accessibilityIdentifier("voice-vocabulary-local-disclosure")
            }

            FormGroup(
                title: "TERMS",
                footer: "One term per line. Up to 100 terms, 64 characters per term and 4,096 characters total. Empty lines and duplicates are removed when saving."
            ) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 170, maxHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editorFocused)
                    .accessibilityLabel(Text("Technical vocabulary"))
                    .accessibilityIdentifier("voice-vocabulary-editor")
                if let issue = result.issue {
                    Text(issue.message)
                        .font(.footnote).foregroundStyle(Ink.warn)
                        .accessibilityIdentifier("voice-vocabulary-error")
                } else {
                    LabeledContent("Terms", value: "\(result.terms.count) / 100")
                        .accessibilityIdentifier("voice-vocabulary-count")
                }
                Text("Whisper may use only the first part of a long list. Put important terms first.")
                    .font(.footnote).foregroundStyle(Ink.meta)
            }

            FormGroup {
                Button("Clear vocabulary", role: .destructive) {
                    draft = ""
                    lastSavedText = nil
                }
                .disabled(draft.isEmpty)
                .accessibilityIdentifier("voice-vocabulary-clear")
                Button("Save vocabulary") { save() }
                    .disabled(result.issue != nil || draft == settings.voiceVocabulary)
                    .accessibilityIdentifier("voice-vocabulary-save")
                if lastSavedText == draft {
                    Text("Vocabulary saved")
                        .font(.footnote).foregroundStyle(Ink.accent)
                        .accessibilityIdentifier("voice-vocabulary-saved")
                }
            }
        }
        .moshpitForm()
        .navigationTitle("Technical vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !hasLoaded else { return }
            draft = settings.voiceVocabulary
            hasLoaded = true
        }
    }

    private func save() {
        let result = validation
        guard result.issue == nil else { return }
        editorFocused = false
        settings.voiceVocabulary = result.text
        draft = result.text
        lastSavedText = result.text
        Haptics.success()
    }
}
