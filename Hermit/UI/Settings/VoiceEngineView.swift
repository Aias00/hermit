import SwiftUI

/// The user chooses whether recognition runs locally or sends the completed
/// recording to their configured cloud provider.
struct VoiceEngineView: View {
    @Environment(AppSettings.self) private var settings

    @State private var installedCount = 0

    var body: some View {
        @Bindable var settings = settings

        Form {
            FormGroup(
                title: "RECOGNITION",
                footer: "Apple and Whisper recognize speech on this device. Doubao uploads your recording to Volcengine after you stop and transcribe. It requires your own API key and may incur service charges."
            ) {
                ForEach(VoiceEngineKind.allCases) { kind in
                    engineRow(kind: kind, settings: settings)
                }
            }

            if settings.voiceEngine == .doubao {
                FormGroup(title: "CLOUD RECOGNITION") {
                    NavigationLink {
                        DoubaoVoiceSettingsView()
                    } label: {
                        Label("Configure Doubao", systemImage: "key")
                            .foregroundStyle(Ink.primary)
                    }
                    .accessibilityIdentifier("voice-doubao-settings-link")
                }
            }

            if settings.voiceEngine == .whisper, installedCount == 0 {
                FormGroup(title: "SETUP") {
                    NavigationLink {
                        WhisperModelView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download a model")
                                    .font(.body).foregroundStyle(Ink.primary)
                                Text("Whisper can't transcribe until one is on the device")
                                    .font(.footnote).foregroundStyle(Ink.meta)
                            }
                            Spacer()
                        }
                    }
                }
            }

            FormGroup(title: "LOCAL RECOGNITION") {
                NavigationLink {
                    VoiceVocabularyView()
                } label: {
                    Label("Technical vocabulary", systemImage: "text.book.closed")
                        .foregroundStyle(Ink.primary)
                }
                .accessibilityIdentifier("voice-vocabulary-link")
            }

            FormGroup(title: "TRY IT") {
                NavigationLink {
                    VoiceInputTestView()
                } label: {
                    Label("Recording test", systemImage: "mic")
                        .foregroundStyle(Ink.primary)
                }
                .accessibilityIdentifier("voice-test-link")
            }
        }
        .moshpitForm()
        .navigationTitle("Recognition")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear { installedCount = WhisperModelStore.catalog().filter(\.isInstalled).count }
    }

    private func engineRow(kind: VoiceEngineKind, settings: AppSettings) -> some View {
        Button {
            guard settings.voiceEngine != kind else { return }
            settings.voiceEngine = kind
            // First switch to Whisper: preselect a language rather than
            // leaving it on Auto-detect when the user's own configuration
            // already says they speak Chinese. Detection wavers on
            // code-switched speech; an explicit language plus the mixed-word
            // primer doesn't.
            if kind == .whisper, settings.whisperLanguage.isEmpty {
                settings.whisperLanguage = VoiceLanguageResolver.initialWhisperLanguage()
            }
            Haptics.select()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.body).foregroundStyle(Ink.primary)
                    Text(kind.summary)
                        .font(.footnote)
                        .foregroundStyle(Ink.meta)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if settings.voiceEngine == kind {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice-engine-\(kind.rawValue)")
        .accessibilityAddTraits(settings.voiceEngine == kind ? .isSelected : [])
    }
}
