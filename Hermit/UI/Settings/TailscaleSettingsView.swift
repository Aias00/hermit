import SwiftUI
import SafariServices

/// Account management for the app-local Tailscale node. Merely opening this
/// screen restores status; only an explicit login action presents a browser.
struct TailscaleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = TailscaleAccount.shared
    @State private var browser: LoginPage?
    @State private var loginPresentation = TailscaleLoginPresentation()
    @State private var operationInFlight = false
    @State private var operationID = UUID()
    @State private var cancellingLogin = false
    @State private var confirmLogout = false

    private struct LoginPage: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            Form {
                FormGroup(title: "Tailscale account") {
                    LabeledContent("Status", value: statusLabel)
                        .accessibilityIdentifier("tailscale-account-status")
                    Text("Sign in here to connect to your Tailscale devices from Hermit. This creates a separate device in your tailnet.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    if account.isRequestingLoginURL {
                        ProgressView("Getting Tailscale login link…")
                            .accessibilityIdentifier("tailscale-login-link-progress")
                    } else if account.state == .starting {
                        ProgressView("Starting Tailscale…")
                    }
                    if let error = account.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("tailscale-account-error")
                    }
                    if let diagnostic = account.diagnosticMessage {
                        Text(diagnostic).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("tailscale-account-diagnostic")
                    }
                    accountControls
                }

                if account.state == .needsApproval {
                    FormGroup(title: "Device approval") {
                        Text("Your tailnet requires an administrator to approve this device. Approve Hermit in the Tailscale admin console, then refresh.")
                            .font(.footnote)
                        Button("Refresh status") { perform { await account.refresh() } }
                            .disabled(operationInFlight)
                            .accessibilityIdentifier("tailscale-refresh-status")
                    }
                }

                if account.state == .connected {
                    FormGroup(title: "Visible devices") {
                        if account.peers.isEmpty {
                            Text("No visible devices. Check your tailnet's access rules. You can also enter a Tailscale IP or MagicDNS name when adding a host.")
                                .font(.footnote).foregroundStyle(Ink.meta)
                        }
                        ForEach(account.peers) { peer in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(peer.name)
                                    Spacer()
                                    Text(peer.isOnline ? String(localized: "Online") : String(localized: "Offline"))
                                        .font(.caption).foregroundStyle(Ink.meta)
                                }
                                if let host = peer.connectionHost {
                                    Text(host).font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(Ink.meta).textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("tailscale-visible-peer-" + peer.id)
                        }
                        Button("Refresh devices") { perform { await account.refresh() } }
                            .disabled(operationInFlight)
                            .accessibilityIdentifier("tailscale-settings-refresh-peers")
                    }
                }

                FormGroup(title: "Connection setup") {
                    Text("Add or edit a host, choose Tailscale as the transport, then select a device and enter its SSH username and password or key.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    Text("Experimental. Only this app's SSH connections use the built-in Tailscale connection; Mosh is not supported here yet.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }
            .moshpitForm()
            .navigationTitle("Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Ink.accent)
                }
            }
            .task { await account.resume() }
            .onChange(of: account.loginURL) { _, url in
                guard let url = loginPresentation.automaticPageURL(loginURL: url, state: account.state) else { return }
                browser = LoginPage(url: url)
            }
            .onChange(of: account.state) { _, state in
                if state == .connected || state == .needsApproval || state == .signedOut {
                    browser = nil
                    loginPresentation.cancel()
                }
            }
            .sheet(item: $browser) { page in
                TailscaleLoginBrowser(url: page.url).ignoresSafeArea()
            }
            .confirmationDialog("Sign out of Tailscale?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    loginPresentation.cancel()
                    browser = nil
                    perform(replacingCurrent: true) { await account.logout() }
                }
            } message: {
                Text("This stops Tailscale connections in Hermit. Saved hosts remain and must be bound again after signing in.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var accountControls: some View {
        if account.state == .needsLogin {
            if let url = account.loginURL {
                Button("Open login page") { browser = LoginPage(url: url) }
                    .accessibilityIdentifier("tailscale-open-login")
                Button("Copy login link") { UIPasteboard.general.string = url.absoluteString }
                    .accessibilityIdentifier("tailscale-copy-login")
                Text("You can complete this login in a browser on another device. Return here to see the result.")
                    .font(.footnote).foregroundStyle(Ink.meta)
            } else if !account.isRequestingLoginURL {
                signInButton
            }
        } else if account.state == .signedOut || account.state == .failed {
            signInButton
        }
        if account.state == .needsLogin || account.state == .starting {
            Button("Cancel login") { cancelLogin() }
                .disabled(cancellingLogin)
                .accessibilityIdentifier("tailscale-cancel-login")
        }
        if account.accountID != nil || account.state == .failed {
            Button("Sign out of Tailscale", role: .destructive) { confirmLogout = true }
                .disabled(cancellingLogin || (operationInFlight && account.state != .starting))
                .accessibilityIdentifier("tailscale-logout")
            Text("Signing out clears this app's account. To remove its device from your tailnet, delete it in the Tailscale admin console.")
                .font(.footnote).foregroundStyle(Ink.meta)
        }
    }

    private var statusLabel: String {
        if account.isRequestingLoginURL { return String(localized: "Getting login link") }
        if account.state == .needsLogin && account.loginURL == nil { return String(localized: "Not signed in") }
        return account.state.displayLabel
    }

    private var signInButton: some View {
        Button("Sign in to Tailscale") {
            loginPresentation.requestLogin()
            perform(replacingCurrent: account.state == .failed) {
                await account.startLogin()
                if let url = loginPresentation.automaticPageURL(loginURL: account.loginURL, state: account.state) {
                    browser = LoginPage(url: url)
                }
            }
        }
        .disabled(operationInFlight && account.state != .failed)
        .accessibilityIdentifier("tailscale-login")
    }

    private func perform(replacingCurrent: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        guard !operationInFlight || replacingCurrent else { return }
        let id = UUID()
        operationID = id
        operationInFlight = true
        Task { @MainActor in
            defer { if operationID == id { operationInFlight = false } }
            await operation()
        }
    }

    private func cancelLogin() {
        // Cancellation must remain available while native startup is pending.
        // The account manager owns cancellation of its in-flight generation.
        loginPresentation.cancel()
        browser = nil
        guard !cancellingLogin else { return }
        cancellingLogin = true
        let id = UUID()
        operationID = id
        operationInFlight = true
        Task { @MainActor in
            await account.cancelLogin()
            cancellingLogin = false
            if operationID == id { operationInFlight = false }
        }
    }
}

extension TailscaleAccountState {
    var displayLabel: String {
        switch self {
        case .signedOut: return String(localized: "Not signed in")
        case .starting: return String(localized: "Starting")
        case .needsLogin: return String(localized: "Waiting for login")
        case .needsApproval: return String(localized: "Waiting for device approval")
        case .connected: return String(localized: "Connected")
        case .failed: return String(localized: "Connection failed")
        }
    }
}

extension TailscaleAccountPeer {
    var connectionHost: String? {
        let dns = dnsName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if !dns.isEmpty { return dns }
        return addresses.first
    }
}

private struct TailscaleLoginBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.view.accessibilityIdentifier = "tailscale-login-browser"
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
