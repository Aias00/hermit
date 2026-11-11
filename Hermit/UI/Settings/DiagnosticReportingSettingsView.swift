import SwiftUI

struct DiagnosticReportingSettingsView: View {
    @State private var reporter = DiagnosticReporter.shared
    @State private var showManual = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Automatic reporting", value: reporter.isEnabled ? String(localized: "Enabled") : String(localized: "Not enabled"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(reporter.isEnabled ? LocalizedStringKey("Automatic reporting: enabled") : LocalizedStringKey("Automatic reporting: not enabled")))
                    .accessibilityIdentifier("diagnostics-enabled-state")
                if let configuration = reporter.configuration {
                    LabeledContent("Receiver", value: configuration.endpoint.host ?? "")
                }
                if let last = reporter.lastSuccess {
                    LabeledContent("Last successful upload", value: last.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("diagnostics-last-success")
                }
                if let status = reporter.statusMessage { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Only connection stages, error categories, network recovery, and app and iOS versions are uploaded. Terminal content, commands, host addresses, passwords, and tokens are excluded.")
            }
            Section {
                if let text = Bundle.main.object(forInfoDictionaryKey: "HermitDiagnosticsSetupURL") as? String,
                   let url = URL(string: text), url.scheme == "https" {
                    Link("Set up my receiver", destination: url)
                        .accessibilityIdentifier("diagnostics-open-setup")
                }
                Button("Set up receiver manually") { showManual = true }.accessibilityIdentifier("diagnostics-manual-setup")
                if reporter.configuration != nil {
                    Button(reporter.isEnabled ? LocalizedStringKey("Upload now") : LocalizedStringKey("Turn on automatic reporting")) {
                        Task {
                            if reporter.isEnabled { await reporter.flush(force: true) }
                            else if let configuration = reporter.configuration { await reporter.enable(configuration) }
                        }
                    }.disabled(reporter.isUploading)
                }
                if reporter.isEnabled {
                    Button("Turn off automatic reporting") { Task { await reporter.disable() } }
                }
                Button("Clear records and remove receiver configuration", role: .destructive) { Task { await reporter.forget() } }
                    .accessibilityIdentifier("diagnostics-forget")
            } footer: {
                Text("Records are collected only while automatic reporting is on. Turning it off deletes records not yet uploaded. Uploads are checked every 5 minutes in the foreground, and pending batches are submitted when the app enters the background. iOS schedules background transfers; offline records are kept and retried with backoff. Uploads are limited to 1 MB per day; up to about 3 MB is kept locally for 7 days. Clearing local records does not delete records already received by the receiver.")
            }
        }
        .navigationTitle("Automatic diagnostic reporting")
        .sheet(isPresented: $showManual) { DiagnosticReportingManualSetup() }
        .task { if reporter.isEnabled { await reporter.flush() } }
    }
}

struct DiagnosticReportingConsentView: View {
    let configuration: DiagnosticReceiverConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Diagnostic receiver") {
                    Text(configuration.endpoint.absoluteString).textSelection(.enabled)
                    Text("Confirm that this is your own receiver. Device credentials are stored only in this device’s Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("After you enable reporting, Hermit periodically uploads structured connection and recovery records, along with app and iOS versions. Terminal content, commands, host addresses, and SSH credentials are never uploaded.")
                    Button("Enable automatic diagnostic reporting") {
                        busy = true
                        Task {
                            await DiagnosticReporter.shared.enable(configuration)
                            busy = false
                            if DiagnosticReporter.shared.isEnabled { dismiss() }
                        }
                    }.disabled(busy).accessibilityIdentifier("diagnostics-confirm-enable")
                    if let status = DiagnosticReporter.shared.statusMessage { Text(status).font(.footnote) }
                }
            }.navigationTitle("Set up diagnostic reporting")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct DiagnosticReportingManualSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var token = ""
    @State private var proposed: DiagnosticReceiverConfiguration?
    @State private var invalid = false
    var body: some View {
        if let proposed {
            DiagnosticReportingConsentView(configuration: proposed)
        } else {
          NavigationStack {
            Form {
                TextField("HTTPS receiver address", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("diagnostics-endpoint")
                SecureField("Device reporting credential", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // This is an app-managed device token, not a website login.
                    // Prevent iOS's save-password sheet from intercepting setup.
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("diagnostics-device-token")
                Button("Check configuration") {
                    if let url = URL(string: endpoint) { proposed = try? DiagnosticReceiverConfiguration(endpoint: url, token: token) }
                    invalid = proposed == nil
                }.accessibilityIdentifier("diagnostics-check-configuration")
                if invalid { Text("Enter a valid HTTPS receiver address and device credential. The address cannot contain a username, password, or query parameters.") }
                Text("The receiver must support the Hermit diagnostic format. You can also open the app from the receiver’s protected pairing page.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Manual setup")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("diagnostics-manual-cancel") } }
          }
        }
    }
}
