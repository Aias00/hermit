import SwiftUI

struct iCloudSyncView: View {
    @Environment(CloudSyncService.self) private var sync
    @Environment(ConnectionStoreHolder.self) private var connections
    @Environment(SSHKeyStore.self) private var keys
    @Environment(ThemeStore.self) private var themes
    @Environment(AppThemeStore.self) private var appThemes
    @Environment(ShortcutStore.self) private var shortcuts

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: Binding(get: { sync.enabled }, set: { value in
                    sync.setEnabled(value)
                    if value { Task { await sync.sync(manual: true) } }
                }))
                .disabled(!sync.available)
                .accessibilityIdentifier("icloud-sync-enabled")
                Toggle("Sync SSH Credentials", isOn: Binding(get: { sync.syncCredentials }, set: sync.setSyncCredentials))
                    .disabled(!sync.available)
                    .accessibilityIdentifier("icloud-sync-credentials")
            } footer: {
                Text("When enabled, saved hosts, SSH keys, themes, appearance and keyboard shortcuts sync through your private iCloud database. SSH passwords and portable private keys are included by default and stored in CloudKit encrypted fields. Turning credential sync off keeps existing cloud copies and local Keychain items.")
            }

            Section {
                LabeledContent("Last successful sync") {
                    if let date = sync.lastSync { Text(date, format: .dateTime.month().day().hour().minute()) }
                    else { Text("Not synced yet") }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("icloud-last-sync")
                Button {
                    Task { await sync.sync(manual: true) }
                } label: {
                    HStack {
                        Text(sync.syncing ? "Syncing…" : "Sync Now")
                        Spacer()
                        if sync.syncing { ProgressView() }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                }
                .disabled(!sync.available || !sync.enabled || sync.syncing)
                .accessibilityIdentifier("icloud-sync-now")
                if let message = sync.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("icloud-sync-status")
                }
            } footer: {
                Text("Sync runs when the app enters the foreground or when you tap Sync Now. It does not run continuously in the background. Use Sync Now to authorize protected SSH keys.")
            }

            Section("On this device") {
                LabeledContent("SSH Hosts", value: "\(connections.store.connections.count)")
                    .accessibilityIdentifier("icloud-count-hosts")
                LabeledContent("Portable SSH Keys", value: "\(keys.keys.filter(CloudSyncLocalStore.isPortable).count)")
                    .accessibilityIdentifier("icloud-count-keys")
                LabeledContent("Custom Themes", value: "\(themes.customThemes.count + appThemes.customThemes.count)")
                    .accessibilityIdentifier("icloud-count-themes")
                LabeledContent("Keyboard Shortcuts", value: "\(shortcuts.shortcuts.count)")
                    .accessibilityIdentifier("icloud-count-shortcuts")
                LabeledContent("Terminal Appearance", value: String(localized: "Included"))
                    .accessibilityIdentifier("icloud-appearance")
            }
            Section {
                Text("Cloudflare sign-ins, Tailscale device identity, Tailcat credentials, host-key trust and Secure Enclave keys stay on this device. Sign in or bind those connections again on another device. Remote terminal sessions and downloaded voice models are not synced.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
