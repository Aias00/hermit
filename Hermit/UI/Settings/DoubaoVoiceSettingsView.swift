import SwiftUI

/// Configuration edits never read an existing key back into a text field.
/// Saving a key does not select a provider or submit a recording.
struct DoubaoVoiceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var newAPIKey = ""
    @State private var resourceID = ""
    @State private var hasKey = false
    @State private var isCheckingKey = true
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @FocusState private var keyFocused: Bool

    private var trimmedResourceID: String {
        resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validResourceID: Bool {
        trimmedResourceID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }

    private var canSave: Bool {
        !isCheckingKey && !isSaving && validResourceID
            && (hasKey || !newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            FormGroup(title: "CLOUD RECOGNITION") {
                Text("Doubao sends your recording to Volcengine after you stop and transcribe. Use your own API key with speech recognition enabled. Volcengine may charge for recognition.")
                    .font(.footnote).foregroundStyle(Ink.meta)
                    .accessibilityIdentifier("doubao-upload-disclosure")
                Text("Cancel before stopping to discard a recording without uploading it. Recognized text stays here until you choose to use it.")
                    .font(.footnote).foregroundStyle(Ink.meta)
                Link("Doubao setup guide", destination: URL(string:
                    "https://docs.volcengine.com/docs/doubao-voice/large-model-recording-file-lite-recognition-api?lang=en")!)
                    .font(.footnote)
            }

            FormGroup(
                title: "API KEY",
                footer: "The API key is stored in this device's secure credential storage. An existing key is never shown here."
            ) {
                LabeledContent("Status", value: keyStatus)
                    .accessibilityIdentifier("doubao-key-status")
                    .accessibilityValue(isCheckingKey ? "checking" : hasKey ? "saved" : "missing")
                SecureField(hasKey ? String(localized: "Replace API key") : String(localized: "Enter API key"),
                            text: $newAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyFocused)
                    .accessibilityIdentifier("doubao-api-key")
                    .disabled(isCheckingKey || isSaving)
            }

            FormGroup(
                title: "RESOURCE ID",
                footer: "Use the speech resource enabled for your API key. The default is volc.bigasr.auc_turbo."
            ) {
                TextField("Resource ID", text: $resourceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("doubao-resource-id")
                    .disabled(isSaving)
                if !validResourceID && !isCheckingKey {
                    Text("Enter a resource ID using letters, numbers, dots, underscores or hyphens.")
                        .font(.footnote).foregroundStyle(Ink.warn)
                }
            }

            FormGroup {
                Button("Save configuration") { saveConfiguration() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("doubao-save-key")
                if hasKey {
                    Button("Delete API key", role: .destructive) { deleteKey() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("doubao-delete-key")
                }
                if isSaving {
                    ProgressView().tint(Ink.accent)
                }
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(Ink.accent)
                        .accessibilityIdentifier("doubao-save-status")
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Ink.warn)
                        .accessibilityIdentifier("doubao-configuration-error")
                }
            }
        }
        .moshpitForm()
        .navigationTitle("Configure Doubao")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            resourceID = settings.doubaoResourceID
            hasKey = await DoubaoVoiceCredentials.shared.hasKey()
            isCheckingKey = false
        }
        .onDisappear { newAPIKey = "" }
    }

    private var keyStatus: String {
        if isCheckingKey { return String(localized: "Checking…") }
        return hasKey ? String(localized: "API key saved") : String(localized: "API key missing")
    }

    private func saveConfiguration() {
        guard canSave else { return }
        keyFocused = false
        isSaving = true
        statusMessage = nil
        errorMessage = nil
        let key = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = trimmedResourceID
        Task { @MainActor in
            defer { isSaving = false }
            do {
                if !key.isEmpty { try await DoubaoVoiceCredentials.shared.save(key) }
                settings.doubaoResourceID = resource
                resourceID = resource
                newAPIKey = ""
                hasKey = await DoubaoVoiceCredentials.shared.hasKey()
                statusMessage = String(localized: "Configuration saved")
                Haptics.success()
            } catch let failure as DoubaoVoiceFailure {
                hasKey = await DoubaoVoiceCredentials.shared.hasKey()
                errorMessage = failure.localizedDescription
            } catch {
                hasKey = await DoubaoVoiceCredentials.shared.hasKey()
                errorMessage = String(localized: "Couldn't save the API key. Try again.")
            }
        }
    }

    private func deleteKey() {
        guard hasKey, !isSaving else { return }
        keyFocused = false
        isSaving = true
        statusMessage = nil
        errorMessage = nil
        newAPIKey = ""
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await DoubaoVoiceCredentials.shared.clear()
                hasKey = false
                statusMessage = String(localized: "API key deleted")
            } catch {
                hasKey = await DoubaoVoiceCredentials.shared.hasKey()
                errorMessage = String(localized: "Couldn't delete the API key. Try again.")
            }
        }
    }
}
