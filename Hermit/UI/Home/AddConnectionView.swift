import SwiftUI
import TailcatSSH

/// Screen 1 — Add Connection modal form. Also doubles as the editor for an
/// existing connection (Home card → Edit).
struct AddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(SSHKeyStore.self) private var keyStore

    let store: ConnectionStore
    let keychain: KeychainService
    var existing: ServerConnection?
    var onConnect: ((ServerConnection) -> Void)?

    @State private var discovering = false
    @State private var browser = LocalHostBrowser()
    @State private var showAdvanced = false
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var privateKeyPEM = ""
    /// Managed key picked from SSH Keys; nil = paste-a-PEM mode.
    @State private var selectedKeyId: UUID?
    @State private var useMosh = false
    @State private var predictMode: PredictMode = .adaptive
    @State private var roamOnCellular = true
    /// Defaults to tmux: every connection saved before this picker existed ran
    /// tmux (the form hardcoded it), so a new connection behaving the same way
    /// is the least surprising thing.
    @State private var multiplexer: Multiplexer = .tmux
    @State private var tmuxPath = ""
    @State private var herdrPath = ""
    // Empty by default: a non-nil path SKIPS the capability probe (the user
    // "vouches" for it), so prefilling the Apple-Silicon Homebrew path made
    // every Linux host bypass the graceful mosh degrade and die on a raw
    // "command not found". Empty → `mosh-server` on PATH + probe intact.
    @State private var moshServerPath = ""
    @State private var compressOutput = false
    @State private var saveError: String?
    @State private var showKeyPicker = false
    @State private var transportForm = ConnectionTransportForm()
    @State private var showCloudflareAdvanced = false
    @State private var accessAccount: (settings: CloudflareConnectionSettings, label: String)?
    @State private var accessError: String?
    @State private var accessBusy = false
    @State private var accessTask: Task<Void, Never>?
    @State private var accessStatusGeneration = 0
    @State private var accessOperationGeneration = 0
    @State private var saving = false
    @State private var tailcatBusy = false
    @State private var tailcatClientPrivateKey: String?
    @State private var tailcatClientPublicKey: String?
    @State private var tailcatError: String?
    @State private var tailcatCredentialMissing = false
    @State private var tailcatNeedsReplacementAddress = false
    @State private var tailscaleAccount = TailscaleAccount.shared
    @State private var showTailscaleSettings = false

    init(store: ConnectionStore, keychain: KeychainService, existing: ServerConnection? = nil,
         onConnect: ((ServerConnection) -> Void)? = nil) {
        self.store = store
        self.keychain = keychain
        self.existing = existing
        self.onConnect = onConnect
        if let c = existing {
            _name = State(initialValue: c.name)
            _host = State(initialValue: c.host)
            _port = State(initialValue: String(c.port))
            _username = State(initialValue: c.username)
            _authMethod = State(initialValue: c.authMethod)
            _selectedKeyId = State(initialValue: c.sshKeyId)
            _useMosh = State(initialValue: c.connectionProtocol == .mosh && c.transport?.requiresSSH != true)
            _predictMode = State(initialValue: c.predictMode)
            _roamOnCellular = State(initialValue: c.roamOnCellular ?? true)
            _multiplexer = State(initialValue: c.multiplexer)
            _tmuxPath = State(initialValue: c.tmuxPath ?? "")
            _herdrPath = State(initialValue: c.herdrPath ?? "")
            _moshServerPath = State(initialValue: c.moshServerPath ?? "")
            _compressOutput = State(initialValue: c.compression)
            _transportForm = State(initialValue: ConnectionTransportForm(connection: c))
            _showCloudflareAdvanced = State(initialValue:
                !(c.cloudflareTeamDomain ?? "").isEmpty || !(c.cloudflareAudience ?? "").isEmpty
                || (!(c.cloudflareHostname ?? "").isEmpty && c.cloudflareHostname != c.host))
        }
    }

    /// Keys that can actually authenticate: everything except hardware-token
    /// ECDSA-sk (its private half lives on the YubiKey).
    private var connectableKeys: [SSHKeyRecord] {
        keyStore.keys.filter { $0.algorithm != .ecdsaSK }
    }

    private var selectedKey: SSHKeyRecord? {
        selectedKeyId.flatMap { id in keyStore.keys.first { $0.id == id } }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !accessBusy && !saving && !tailcatBusy
            && (transportForm.selection != .tailcat || transportForm.tailcatAddress.isEmpty || tailcatClientPrivateKey != nil)
            && (transportForm.selection != .tailcat || !tailcatNeedsReplacementAddress || !transportForm.tailcatAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (transportForm.selection != .tailscale || tailscaleBindingReady)
            && (try? configuredConnection()) != nil
    }

    private var tailscaleBindingReady: Bool {
        transportForm.isTailscaleAccountReady(currentAccountID: tailscaleAccount.accountID, state: tailscaleAccount.state)
    }

    private func configuredConnection() throws -> ServerConnection {
        try transportForm.validatedConnection(from: existing ?? ServerConnection(), host: host,
                                              port: port, usesMosh: useMosh)
    }

    private var cloudflareSettings: CloudflareConnectionSettings? {
        guard transportForm.selection == .cloudflareSSH else { return nil }
        return try? transportForm.cloudflareSettings(host: host)
    }

    private var endpointIssue: String? {
        if transportForm.selection == .tailcat, host.hasPrefix("tc"), host.utf8.count > 40 {
            return ConnectionTransportError.invalidTailcatHostAlias.localizedDescription
        }
        if !host.isEmpty, !ServerConnection.isSSHHostname(host.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ConnectionTransportError.invalidSSHHost.localizedDescription
        }
        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            return ConnectionTransportError.invalidSSHPort.localizedDescription
        }
        return nil
    }

    private var transportIssue: String? {
        var connection = existing ?? ServerConnection()
        connection.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.connectionProtocol = useMosh ? .mosh : .ssh
        do {
            _ = try transportForm.applying(to: connection)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { discovering = true } label: { Label("发现本地设备", systemImage: "wifi.router") }
                        .accessibilityIdentifier("discover-local-hosts")
                }
                FormGroup(title: "名称") {
                    FieldRow(placeholder: "Name", text: $name)
                }
                FormGroup(title: "连接") {
                    if transportForm.selection == .tailscale, tailscaleBindingReady {
                        tailscaleDevicePicker
                    }
                    if transportForm.selection == .tailcat {
                        FieldRow(placeholder: "SSH 主机别名（可留空）", text: $host)
                            .accessibilityIdentifier("tailcat-host-alias")
                        Text("例如 mac-mini。这里只用于显示，无需公网 IP 或域名。")
                            .font(.footnote).foregroundStyle(Ink.meta)
                    } else if transportForm.selection == .tailscale {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SSH address").font(.caption).foregroundStyle(Ink.meta)
                            FieldRow(placeholder: "Host", text: $host)
                                .accessibilityIdentifier("tailscale-ssh-host")
                        }
                    } else {
                        FieldRow(placeholder: "Host", text: $host)
                    }
                    NumberFieldRow(label: "Port", placeholder: "22", text: $port)
                    FieldRow(placeholder: "Username", text: $username)
                    Picker("连接模式", selection: $useMosh) {
                        Text("SSH").tag(false)
                        Text("Mosh").tag(true)
                    }
                    .accessibilityIdentifier("connection-protocol-picker")
                    .disabled(transportForm.selection?.requiresSSH == true)
                    if transportForm.selection == .cloudflareSSH {
                        Text("Cloudflare 仅承载 SSH TCP，Mosh 的 UDP 不会经过此入口。")
                            .font(.footnote).foregroundStyle(Ink.meta)
                    } else if transportForm.selection == .tailcat {
                        Text("此 Tailcat 连接仅承载 SSH TCP，仍使用下方的 SSH 密码或密钥。")
                            .font(.footnote).foregroundStyle(Ink.meta)
                    } else if transportForm.selection == .tailscale {
                        Text("This connection uses Tailscale inside Hermit. SSH still requires the username and password or key below.")
                            .font(.footnote).foregroundStyle(Ink.meta)
                    }
                    if let endpointIssue {
                        Text(endpointIssue).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("connection-endpoint-error")
                    }
                }

                transportSection

                FormGroup(title: "AUTHENTICATION") {
                    PillSegmentedControl(
                        items: [
                            SegItem(value: AuthMethod.password, label: "Password"),
                            SegItem(value: AuthMethod.key, label: "SSH Key"),
                        ],
                        selection: $authMethod)
                    if authMethod == .password {
                        FieldRow(placeholder: "Password", text: $password, secure: true)
                    } else {
                        // Always rendered — even with zero saved keys — so there's
                        // always a way into KeyPickerSheet's generate/import CTA
                        // instead of paste-PEM being the only option. Kept as an
                        // independent `if` from the TextEditor below (not folded
                        // into an if/else): MainFlowUITest asserts the PEM editor
                        // appears immediately with an empty key store, with no
                        // extra tap first.
                        ChevronRow(
                            label: "Key",
                            value: selectedKey.map { "\($0.name) · \($0.badgeText)" } ?? String(localized: "Paste PEM")
                        ) {
                            showKeyPicker = true
                        }
                        .accessibilityIdentifier("key-picker-row")
                        if selectedKey == nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Private Key (PEM)")
                                    .font(.footnote)
                                    .foregroundStyle(Ink.meta)
                                TextEditor(text: $privateKeyPEM)
                                    .font(Face.mono(11))
                                    .foregroundStyle(Ink.primary)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 84)
                                    .padding(8)
                                    .background(Ink.terminalBG,
                                                in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                                            .strokeBorder(Ink.groupBorder, lineWidth: 1))
                                    .accessibilityIdentifier("private-key-editor")
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                FormGroup(title: "会话保持", footer: "tmux 与 herdr 使用各自的会话。SSH 下的 herdr 可使用原生工作区与 Agent 切换。") {
                    Picker("会话模式", selection: $multiplexer) {
                        Text("关闭").tag(Multiplexer.none)
                        Text("tmux").tag(Multiplexer.tmux)
                        Text("herdr").tag(Multiplexer.herdr)
                    }.pickerStyle(.segmented).accessibilityIdentifier("multiplexer-picker")
                }
                if onConnect != nil {
                    Section("连接测试") {
                        Button { Task { await save(connectAfter: true) } } label: {
                            Label("保存并测试连接", systemImage: "network")
                        }.disabled(!canSave).accessibilityIdentifier("test-host-connection")
                    }
                }
                DisclosureGroup("高级连接设置", isExpanded: $showAdvanced) {
                FormGroup(
                    title: "ROAMING · MOSH",
                    footer: "Mosh keeps the session alive across Wi-Fi / 5G handoff and sleep/wake. UDP must be open server-side; the client picks an unused port within range. With tmux, Hermit attaches to your existing sessions and never creates or restyles them; only sessions you create through Hermit get its native look (status bar hidden, restored on disconnect)."
                ) {
                    ToggleRow(
                        label: "Use Mosh",
                        subtitle: "Wrap SSH with mosh-server (UDP)",
                        identifier: "toggle-use-mosh",
                        isOn: $useMosh)
                        .disabled(transportForm.selection?.requiresSSH == true)
                    // The tuning rows only exist when Mosh does. With
                    // the toggle off they were pure expert noise — and
                    // "Roam on Cellular: ON" under a disabled Mosh was
                    // a lie about what would happen.
                    if useMosh {
                        ValueRow(
                            label: "UDP Port Range",
                            value: "\(settings.udpRangeStart) – \(settings.udpRangeEnd)")
                        Menu {
                            ForEach(PredictMode.allCases, id: \.self) { mode in
                                Button {
                                    predictMode = mode
                                } label: {
                                    Label {
                                        Text(mode.label)
                                    } icon: {
                                        if predictMode == mode {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text("Predict Mode").font(.body).foregroundStyle(Ink.primary)
                                Spacer()
                                Text(predictMode.label).font(.body).foregroundStyle(Ink.meta)
                                MenuChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        ToggleRow(
                            label: "Roam on Cellular",
                            subtitle: "Reconnect over 5G/LTE when Wi-Fi drops",
                            isOn: $roamOnCellular)
                        FieldRow(placeholder: "mosh-server path",
                                 text: $moshServerPath)
                    }
                }

                FormGroup(
                    title: "ADVANCED",
                    footer: "tmux and herdr hold separate, unrelated sessions. If the host doesn't have the one you pick, Hermit says so and drops to a plain shell — it never quietly attaches the other. With Mosh, herdr runs its own terminal UI; native rendering needs SSH."
                ) {
                    // The path field follows the choice: it's the one
                    // that skips the capability probe, so offering the
                    // wrong binary's path would be a trap.
                    switch multiplexer {
                    case .tmux:
                        FieldRow(placeholder: "Custom tmux Path", text: $tmuxPath)
                    case .herdr:
                        FieldRow(placeholder: "Custom herdr Path", text: $herdrPath)
                    case .none:
                        EmptyView()
                    }
                    ToggleRow(label: "Compress Output", isOn: $compressOutput)
                }
                }.accessibilityIdentifier("connection-advanced")
            }
            .disabled(saving)
            .moshpitForm()
            .navigationTitle(existing == nil ? "新建 Host" : "编辑 Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Ink.accent)
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(canSave ? Ink.accent : Ink.disabledNav)
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-connection")
                }
            }
            .moshpitCard(isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                HermitNoticeCard(title: "Could not save", message: saveError ?? "") {
                    saveError = nil
                }
            }
            .appSheet(isPresented: $showKeyPicker) {
                KeyPickerSheet(keys: connectableKeys, selectedKeyId: $selectedKeyId)
            }
        }
        .appSheet(isPresented: $discovering) {
            NavigationStack {
                List {
                    if let failure = browser.failure { Text(failure).foregroundStyle(.orange) }
                    ForEach(browser.hosts) { found in
                        Button {
                            host = found.hostname; port = String(found.port)
                            if name.isEmpty { name = found.name }
                            discovering = false
                        } label: {
                            VStack(alignment: .leading) { Text(found.name); Text(found.hostname).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if browser.hosts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView("查找局域网 SSH 服务…")
                            Text("手机与电脑需处于同一 Wi-Fi。只会发现通过 Bonjour 广播 SSH 服务的设备；未发现时仍可手动输入 IP。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical)
                    }
                }.navigationTitle("本地设备").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { discovering = false } }
                }.task { browser.start() }.onDisappear { browser.stop() }
            }.preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
        .appSheet(isPresented: $showTailscaleSettings) {
            TailscaleSettingsView()
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: transportForm.selection) { _, selection in
            if selection?.requiresSSH == true { useMosh = false }
            accessError = nil
        }
        .task(id: transportForm.selection) {
            if transportForm.selection == .tailcat { await prepareTailcatIdentity() }
            if transportForm.selection == .tailscale {
                await tailscaleAccount.resume()
                bindInitialTailscaleAccount()
            }
        }
        .onChange(of: tailscaleAccount.state) { _, _ in bindInitialTailscaleAccount() }
        .onChange(of: tailscaleAccount.accountID) { _, _ in bindInitialTailscaleAccount() }
        .onChange(of: cloudflareSettings) { _, _ in
            cancelAccessOperation()
            accessAccount = nil
            accessError = nil
        }
        .task(id: cloudflareSettings) {
            accessAccount = nil
            accessError = nil
            let generation = accessStatusGeneration
            guard let settings = cloudflareSettings else { return }
            let label = await CloudflareAccessAuth.shared.accountLabel(settings: settings)
            guard !Task.isCancelled, generation == accessStatusGeneration,
                  cloudflareSettings == settings, let label else { return }
            accessAccount = (settings, label)
        }
        .onDisappear { cancelAccessOperation() }
    }

    private var transportSection: some View {
        FormGroup(title: "连接方式", footer: "选择此连接使用的网络入口。") {
            Group {
                Picker("传输", selection: $transportForm.selection) {
                    if transportForm.selection == nil {
                        Text("不支持的连接方式 — 请重新选择").tag(Optional<ConnectionTransport>.none)
                    }
                    ForEach(ConnectionTransport.allCases, id: \.self) { transport in
                        Text(transport.label).tag(Optional(transport))
                    }
                }
                .accessibilityIdentifier("connection-transport-picker")
                if transportForm.selection == .socks5 {
                    FieldRow(placeholder: "Proxy Host", text: $transportForm.socksHost)
                        .accessibilityIdentifier("socks-proxy-host")
                    NumberFieldRow(label: "Proxy Port", placeholder: "1080", text: $transportForm.socksPort)
                        .accessibilityIdentifier("socks-proxy-port")
                    Text("仅支持无需认证的 SOCKS5。Mosh 启用后，其 UDP 数据仍然直连远端。")
                        .font(.footnote).foregroundStyle(Ink.meta)
                } else if transportForm.selection == .cloudflareSSH {
                    Text("使用上方主机域名登录 Cloudflare。可以先保存，稍后再登录。")
                        .font(.footnote).foregroundStyle(Ink.meta)
                    DisclosureGroup(isExpanded: $showCloudflareAdvanced) {
                        FieldRow(placeholder: "入口域名覆盖（留空使用上方主机）", text: $transportForm.cloudflareHostname)
                            .accessibilityIdentifier("cloudflare-hostname")
                        Toggle("手动配置 Access", isOn: $transportForm.cloudflareManualConfiguration)
                            .accessibilityIdentifier("cloudflare-manual-access-toggle")
                        if transportForm.cloudflareManualConfiguration {
                            FieldRow(placeholder: "Access 团队域名，例如 team.cloudflareaccess.com", text: $transportForm.cloudflareTeamDomain)
                                .accessibilityIdentifier("cloudflare-team-domain")
                            FieldRow(placeholder: "Access 应用 Audience（AUD）", text: $transportForm.cloudflareAudience)
                                .accessibilityIdentifier("cloudflare-audience")
                        } else {
                            Text("Access 配置将在登录时自动获取并验证。")
                                .font(.footnote).foregroundStyle(Ink.meta)
                        }
                    } label: {
                        Text("高级 Cloudflare 配置")
                            .accessibilityIdentifier("cloudflare-advanced-toggle")
                    }
                } else if transportForm.selection == .tailcat {
                    tailcatControls
                } else if transportForm.selection == .tailscale {
                    tailscaleControls
                }
            }
            .disabled(accessBusy)
            if transportForm.selection == .cloudflareSSH {
                Text("实验功能，兼容性仍在验证。SSH 密码或密钥仍需单独设置。")
                    .font(.footnote).foregroundStyle(Ink.meta)
                    .accessibilityIdentifier("cloudflare-experimental-notice")
                accessControls
            }
            if let transportIssue {
                Text(transportIssue).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("connection-transport-error")
            }
        }
    }

    private var tailscaleControls: some View {
        Group {
            LabeledContent("Tailscale status", value: tailscaleAccount.state.displayLabel)
                .accessibilityIdentifier("tailscale-connection-status")
            Button("Manage Tailscale") { showTailscaleSettings = true }
                .accessibilityIdentifier("tailscale-manage-account")
            if tailscaleAccount.state == .connected,
               let accountID = tailscaleAccount.accountID,
               let boundID = transportForm.tailscaleAccountID, accountID != boundID {
                Text(TailscaleAccountError.accountMismatch.localizedDescription)
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("tailscale-account-mismatch")
                Button("Use current Tailscale account") {
                    transportForm.bindTailscaleAccount(accountID)
                    host = ""
                }
                .accessibilityIdentifier("tailscale-rebind-account")
            }
            if tailscaleBindingReady {
                if tailscaleAccount.peers.isEmpty {
                    Text("No visible devices. Check your tailnet's access rules. You can also enter a Tailscale IP or MagicDNS name when adding a host.")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
                Button("Refresh devices") { Task { await tailscaleAccount.refresh() } }
                    .accessibilityIdentifier("tailscale-refresh-peers")
            }
            Text("Experimental. Only this app's SSH connections use the built-in Tailscale connection; Mosh is not supported here yet.")
                .font(.footnote).foregroundStyle(Ink.meta)
                .accessibilityIdentifier("tailscale-experimental-notice")
        }
    }

    private var selectedTailscalePeerID: String? {
        transportForm.effectiveTailscalePeerID(host: host)
    }

    private var tailscaleDeviceTitle: String {
        if let id = selectedTailscalePeerID {
            return tailscaleAccount.peers.first { $0.id == id }.map(tailscalePeerTitle)
                ?? String(localized: "Saved Tailscale device")
        }
        return host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Choose a Tailscale device")
            : String(localized: "Manually entered address")
    }

    private func tailscalePeerTitle(_ peer: TailscaleAccountPeer) -> String {
        peer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? peer.connectionHost ?? String(localized: "Saved Tailscale device") : peer.name
    }

    private var tailscaleDevicePicker: some View {
        Menu {
            ForEach(tailscaleAccount.peers) { peer in
                if let endpoint = peer.connectionHost {
                    Button {
                        transportForm.selectTailscalePeer(id: peer.id, host: endpoint)
                        host = endpoint
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = peer.name }
                    } label: {
                        Label(tailscalePeerTitle(peer), systemImage: selectedTailscalePeerID == peer.id ? "checkmark"
                              : peer.isOnline ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    }
                    .accessibilityIdentifier("tailscale-peer-" + peer.id)
                    .accessibilityAddTraits(selectedTailscalePeerID == peer.id ? .isSelected : [])
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "network").foregroundStyle(Ink.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tailscale device").font(.caption).foregroundStyle(Ink.meta)
                    Text(tailscaleDeviceTitle).foregroundStyle(Ink.accent)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(Ink.accent)
            }
        }
        .disabled(tailscaleAccount.peers.isEmpty)
        .accessibilityIdentifier("tailscale-choose-peer")
        .accessibilityLabel(Text("Tailscale device"))
        .accessibilityValue(tailscaleDeviceTitle)
        .accessibilityHint(Text("Choosing a device fills in the SSH address below."))
    }

    private func bindInitialTailscaleAccount() {
        guard transportForm.selection == .tailscale, transportForm.tailscaleAccountID == nil,
              tailscaleAccount.state == .connected, let accountID = tailscaleAccount.accountID else { return }
        transportForm.bindTailscaleAccount(accountID)
    }

    private var tailcatControls: some View {
        Group {
            FieldRow(placeholder: existing?.tailcatCredentialRef == nil || tailcatNeedsReplacementAddress
                     ? "Tailcat 地址（tc…）" : "Tailcat 地址（留空保留已保存地址）",
                     text: $transportForm.tailcatAddress, secure: true)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .privacySensitive()
                .accessibilityIdentifier("tailcat-address")
            Text("地址含连接凭据，仅保存在此设备的钥匙串中，不随连接配置导出。")
                .font(.footnote).foregroundStyle(Ink.meta)
            if tailcatNeedsReplacementAddress {
                Text(TailcatCredentialError.missingCredential.localizedDescription)
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let publicKey = tailcatClientPublicKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text("客户端公钥").font(.footnote).foregroundStyle(Ink.meta)
                    Text(publicKey).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("tailcat-client-public-key")
                    Button("复制客户端公钥") { UIPasteboard.general.string = publicKey }
                        .accessibilityIdentifier("tailcat-copy-client-key")
                    Text("可将此公钥加入 Mac 上 Tailcat 的 --allow 白名单。保存后此设备会继续使用同一身份。")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }
            if tailcatBusy { ProgressView("正在读取 Tailcat 身份…") }
            if let tailcatError {
                Text(tailcatError).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("tailcat-credential-error")
                Button("重试读取 Tailcat 身份") { Task { await prepareTailcatIdentity() } }
                    .disabled(tailcatBusy)
                if tailcatCredentialMissing {
                    Button("生成新的客户端身份") {
                        tailcatNeedsReplacementAddress = true
                        generateTailcatIdentity()
                    }
                        .disabled(tailcatBusy)
                    Text("重新生成后，需要在 Mac 的白名单中添加新的客户端公钥。")
                        .font(.footnote).foregroundStyle(Ink.meta)
                }
            }
            Text("实验功能。请使用 Tailcat 转发远端的 SSH 端口，保留 SSH 登录认证。")
                .font(.footnote).foregroundStyle(Ink.meta)
                .accessibilityIdentifier("tailcat-experimental-notice")
        }
    }

    @MainActor private func prepareTailcatIdentity() async {
        guard tailcatClientPrivateKey == nil, !tailcatBusy else { return }
        tailcatBusy = true
        defer { tailcatBusy = false }
        tailcatError = nil
        tailcatCredentialMissing = false
        guard let ref = existing?.tailcatCredentialRef else {
            generateTailcatIdentity()
            return
        }
        do {
            let credential = try await TailcatCredentials.shared.load(ref: ref)
            guard !Task.isCancelled, transportForm.selection == .tailcat else { return }
            tailcatClientPrivateKey = credential.clientPrivateKey
            tailcatClientPublicKey = credential.clientPublicKey
        } catch {
            guard !Task.isCancelled, transportForm.selection == .tailcat else { return }
            tailcatError = error.localizedDescription
            tailcatCredentialMissing = (error as? TailcatCredentialError) == .missingCredential
        }
    }

    private func generateTailcatIdentity() {
        do {
            let identity = try TailcatIdentity.generateClientKey()
            tailcatClientPrivateKey = identity.privateKey
            tailcatClientPublicKey = identity.publicKey
            tailcatError = nil
            tailcatCredentialMissing = false
        } catch {
            tailcatError = TailcatCredentialError.invalidClientIdentity.localizedDescription
        }
    }

    private var accessControls: some View {
        Group {
            if let account = accessAccount, account.settings == cloudflareSettings {
                LabeledContent("Access 账号", value: account.label)
                    .accessibilityIdentifier("cloudflare-access-account")
                Button("退出此 Access 应用") { updateAccessAccount(signOut: true) }
                    .disabled(accessBusy)
                    .accessibilityIdentifier("cloudflare-access-sign-out")
            } else {
                Text("尚未登录此 Access 应用")
                    .font(.footnote).foregroundStyle(Ink.meta)
            }
            Button { updateAccessAccount(signOut: false) } label: {
                Label("登录 Cloudflare Access", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(cloudflareSettings == nil || accessBusy)
            .accessibilityIdentifier("cloudflare-access-login")
            if accessBusy { ProgressView("正在处理 Access 登录…") }
            if let accessError {
                Text(accessError).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("cloudflare-access-error")
            }
        }
    }

    private func updateAccessAccount(signOut: Bool) {
        guard !accessBusy, let settings = cloudflareSettings else { return }
        accessBusy = true
        accessError = nil
        accessStatusGeneration += 1
        accessOperationGeneration += 1
        let generation = accessOperationGeneration
        accessTask = Task { @MainActor in
            defer {
                if generation == accessOperationGeneration { accessBusy = false; accessTask = nil }
            }
            do {
                if signOut {
                    try await CloudflareAccessAuth.shared.signOut(settings: settings)
                    if generation == accessOperationGeneration, cloudflareSettings == settings { accessAccount = nil }
                } else {
                    let label = try await CloudflareAccessAuth.shared.authorize(settings: settings)
                    guard !Task.isCancelled, generation == accessOperationGeneration,
                          cloudflareSettings == settings else { return }
                    accessAccount = (settings, label)
                }
            } catch {
                guard !Task.isCancelled, generation == accessOperationGeneration,
                      cloudflareSettings == settings else { return }
                accessError = error.localizedDescription
            }
        }
    }

    private func cancelAccessOperation() {
        accessOperationGeneration += 1
        accessStatusGeneration += 1
        accessTask?.cancel()
        accessTask = nil
        accessBusy = false
    }

    private func save(connectAfter: Bool = false) async {
        guard !accessBusy, !saving, !tailcatBusy else { return }
        guard transportForm.selection != .tailscale || tailscaleBindingReady else { return }
        saving = true
        defer { saving = false }
        store.reloadIfNeeded()
        guard store.isAuthoritative else {
            saveError = TailcatCredentialError.storageUnavailable.localizedDescription
            return
        }
        var connection: ServerConnection
        do {
            connection = try configuredConnection()
        } catch {
            saveError = error.localizedDescription
            return
        }
        connection.name = name
        connection.username = username
        connection.authMethod = authMethod
        connection.moshPortRangeStart = settings.udpRangeStart
        connection.moshPortRangeEnd = settings.udpRangeEnd
        // Per-connection mosh-server (`--server`). Empty → nil → bootstrap uses
        // `mosh-server` on PATH (more portable than a hardcoded absolute path).
        connection.moshServerPath = moshServerPath.isEmpty ? nil : moshServerPath
        connection.predictMode = predictMode
        connection.roamOnCellular = roamOnCellular
        connection.tmuxPath = tmuxPath.isEmpty ? nil : tmuxPath
        connection.herdrPath = herdrPath.isEmpty ? nil : herdrPath
        connection.compression = compressOutput
        // Also keeps the legacy `useTmux` flag in sync — see `multiplexer`.
        connection.multiplexer = multiplexer

        var stagedTailcatRef: String?
        do {
            if connection.transport == .tailcat, !transportForm.tailcatAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let privateKey = tailcatClientPrivateKey else { throw TailcatCredentialError.invalidClientIdentity }
                let credential = try TailcatCredential.create(address: transportForm.tailcatAddress, clientPrivateKey: privateKey)
                let ref = try await TailcatCredentials.shared.save(credential)
                stagedTailcatRef = ref
                connection.tailcatCredentialRef = ref
                connection.tailcatServerPublicKey = credential.serverPublicKey
            }
            if let secret = ConnectionCredential.apply(
                to: &connection, authMethod: authMethod, selectedKeyId: selectedKeyId,
                keys: keyStore.keys, password: password, privateKeyPEM: privateKeyPEM,
                newRef: { keychain.generateRef() }),
               let ref = connection.keychainRef {
                if authMethod == .password {
                    try await keychain.savePassword(secret, forRef: ref, requireBiometry: false)
                } else {
                    try await keychain.savePrivateKey(secret, forRef: ref, requireBiometry: false)
                }
            }
            // Drop any cached (possibly stale) credential so the new one is used.
            await SSHService.shared.clearCachedSecret(for: connection.id)
        } catch {
            if let stagedTailcatRef { try? await TailcatCredentials.shared.delete(ref: stagedTailcatRef) }
            saveError = error.localizedDescription
            return
        }

        // Keychain writes suspend this task. A host can have been removed in
        // the meantime; do not report a silent no-op update as a successful
        // save or retire credentials still belonging to the original record.
        store.reloadIfNeeded()
        if connection.transport == .tailscale,
           (tailscaleAccount.state != .connected || connection.tailscaleAccountID != tailscaleAccount.accountID) {
            saveError = TailscaleAccountError.accountChanged.localizedDescription
            return
        }
        if !store.isAuthoritative || (existing != nil && !store.connections.contains(where: { $0.id == connection.id })) {
            if let stagedTailcatRef { try? await TailcatCredentials.shared.delete(ref: stagedTailcatRef) }
            saveError = (store.isAuthoritative ? TailcatCredentialError.connectionRemoved : .storageUnavailable).localizedDescription
            return
        }
        if existing == nil {
            store.add(connection)
        } else {
            store.update(connection)
        }
        // Commit the new reference first. Replaced credentials remain intact
        // through every earlier validation / Keychain failure.
        if let previous = existing?.tailcatCredentialRef, previous != connection.tailcatCredentialRef,
           !store.connections.contains(where: { $0.tailcatCredentialRef == previous }) {
            try? await TailcatCredentials.shared.delete(ref: previous)
        }
        dismiss()
        if connectAfter { onConnect?(connection) }
    }
}
