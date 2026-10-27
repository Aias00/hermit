import SwiftUI

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
    @State private var useSOCKSProxy = false
    @State private var socksProxyHost = ""
    @State private var socksProxyPort = "1080"

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
            _useMosh = State(initialValue: c.connectionProtocol == .mosh)
            _predictMode = State(initialValue: c.predictMode)
            _roamOnCellular = State(initialValue: c.roamOnCellular ?? true)
            _multiplexer = State(initialValue: c.multiplexer)
            _tmuxPath = State(initialValue: c.tmuxPath ?? "")
            _herdrPath = State(initialValue: c.herdrPath ?? "")
            _moshServerPath = State(initialValue: c.moshServerPath ?? "")
            _compressOutput = State(initialValue: c.compression)
            _useSOCKSProxy = State(initialValue: c.useSOCKSProxy ?? false)
            _socksProxyHost = State(initialValue: c.socksProxyHost ?? "")
            _socksProxyPort = State(initialValue: c.socksProxyPort.map(String.init) ?? "1080")
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

    private var canSave: Bool { !name.isEmpty && !host.isEmpty }

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
                    FieldRow(placeholder: "Host", text: $host)
                    NumberFieldRow(label: "Port", placeholder: "22", text: $port)
                    FieldRow(placeholder: "Username", text: $username)
                    Picker("连接模式", selection: $useMosh) {
                        Text("SSH").tag(false)
                        Text("Mosh").tag(true)
                    }
                }

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
                    footer: "Mosh keeps the session alive across Wi-Fi / 5G handoff and sleep/wake. UDP must be open server-side; the client picks an unused port within range. With tmux, Moshpit attaches to your existing sessions and never creates or restyles them; only sessions you create through Moshpit get its native look (status bar hidden, restored on disconnect)."
                ) {
                    ToggleRow(
                        label: "Use Mosh",
                        subtitle: "Wrap SSH with mosh-server (UDP)",
                        identifier: "toggle-use-mosh",
                        isOn: $useMosh)
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
                    title: "PROXY",
                    footer: "Only unauthenticated SOCKS5 proxies are supported. This proxies the SSH connection only — if Mosh is also enabled above, its UDP session connects directly once bootstrapped and is not proxied."
                ) {
                    ToggleRow(
                        label: "Use SOCKS5 Proxy",
                        subtitle: "Route this connection through a local or corporate SOCKS5 proxy",
                        isOn: $useSOCKSProxy)
                    if useSOCKSProxy {
                        FieldRow(placeholder: "Proxy Host", text: $socksProxyHost)
                        NumberFieldRow(label: "Proxy Port", placeholder: "1080", text: $socksProxyPort)
                    }
                }

                FormGroup(
                    title: "ADVANCED",
                    footer: "tmux and herdr hold separate, unrelated sessions. If the host doesn't have the one you pick, Moshpit says so and drops to a plain shell — it never quietly attaches the other. With Mosh, herdr runs its own terminal UI; native rendering needs SSH."
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
            .moshpitForm()
            .navigationTitle(existing == nil ? "新建 Host" : "编辑 Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Ink.accent)
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
                MoshpitNoticeCard(title: "Could not save", message: saveError ?? "") {
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
    }

    private func save(connectAfter: Bool = false) async {
        var connection = existing ?? ServerConnection()
        connection.name = name
        connection.host = host
        connection.port = Int(port) ?? 22
        connection.sshPort = Int(port) ?? 22
        connection.username = username
        connection.authMethod = authMethod
        connection.connectionProtocol = useMosh ? .mosh : .ssh
        connection.moshPortRangeStart = settings.udpRangeStart
        connection.moshPortRangeEnd = settings.udpRangeEnd
        // Per-connection mosh-server (`--server`). Empty → nil → bootstrap uses
        // `mosh-server` on PATH (more portable than a hardcoded absolute path).
        connection.moshServerPath = moshServerPath.isEmpty ? nil : moshServerPath
        connection.useSOCKSProxy = useSOCKSProxy
        connection.socksProxyHost = socksProxyHost.isEmpty ? nil : socksProxyHost
        connection.socksProxyPort = Int(socksProxyPort) ?? 1080
        connection.predictMode = predictMode
        connection.roamOnCellular = roamOnCellular
        connection.tmuxPath = tmuxPath.isEmpty ? nil : tmuxPath
        connection.herdrPath = herdrPath.isEmpty ? nil : herdrPath
        connection.compression = compressOutput
        // Also keeps the legacy `useTmux` flag in sync — see `multiplexer`.
        connection.multiplexer = multiplexer

        do {
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
            saveError = String(describing: error)
            return
        }

        if existing == nil {
            store.add(connection)
        } else {
            store.update(connection)
        }
        dismiss()
        if connectAfter { onConnect?(connection) }
    }
}
