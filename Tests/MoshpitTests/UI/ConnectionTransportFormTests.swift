import Foundation
import Testing
@testable import Moshpit

@Suite("Connection transport form")
struct ConnectionTransportFormTests {
    @Test("Editing an unknown transport requires an explicit supported choice")
    func unknownSelection() throws {
        var original = ServerConnection(host: "host.internal")
        original.transportRaw = "future-transport"
        var form = ConnectionTransportForm(connection: original)
        #expect(form.selection == nil)
        #expect(throws: ConnectionTransportError.unsupportedTransport("future-transport")) {
            try form.validatedConnection(from: original, host: original.host, port: "22", usesMosh: false)
        }
        form.selection = .direct
        let saved = try form.validatedConnection(from: original, host: original.host, port: "22", usesMosh: false)
        #expect(try saved.validatedTransport() == .direct)
        #expect(original.transportRaw == "future-transport")
    }

    @Test("Invalid SSH ports cannot silently save as port 22", arguments: ["", "abc", "0", "65536", "22/ssh", "1e2"])
    func invalidSSHPort(value: String) {
        let form = ConnectionTransportForm()
        #expect(throws: ConnectionTransportError.invalidSSHPort) {
            try form.validatedConnection(from: ServerConnection(), host: "host.internal", port: value, usesMosh: false)
        }
    }

    @Test("Invalid selected proxy ports cannot silently save as port 1080", arguments: ["", "abc", "0", "65536"])
    func invalidProxyPort(value: String) {
        var form = ConnectionTransportForm()
        form.selection = .socks5
        form.socksHost = "proxy.internal"
        form.socksPort = value
        #expect(throws: ConnectionTransportError.invalidSOCKSPort) { try form.applying(to: ServerConnection()) }
    }

    @Test("Host text rejects URL decorations and embedded whitespace", arguments: ["", "https://host.example", "host.example/path", "user@host.example", "host name", "host\u{0}"])
    func invalidSSHHost(value: String) {
        #expect(throws: ConnectionTransportError.invalidSSHHost) {
            try ConnectionTransportForm().validatedConnection(from: ServerConnection(), host: value, port: "22", usesMosh: false)
        }
    }

    @Test("Existing IP and MagicDNS SSH endpoints remain editable", arguments: ["100.64.0.1", "my-machine", "2001:db8::1"])
    func ordinaryEndpoints(host: String) throws {
        let saved = try ConnectionTransportForm().validatedConnection(from: ServerConnection(), host: host, port: "2222", usesMosh: true)
        #expect(saved.host == host)
        #expect(saved.port == 2222)
        #expect(saved.sshPort == 2222)
        #expect(saved.connectionProtocol == .mosh)
    }

    @Test("Cloudflare save uses the same configuration as login and retains SSH identity and multiplexer")
    func cloudflareSave() throws {
        var original = ServerConnection(host: "old.internal", port: 22)
        original.multiplexer = .herdr
        original.keychainRef = "existing-ssh-key"
        original.useSOCKSProxy = true
        original.socksProxyHost = "old-proxy.internal"
        var form = ConnectionTransportForm(connection: original)
        form.selection = .cloudflareSSH
        form.cloudflareManualConfiguration = true
        form.cloudflareHostname = " SSH.EXAMPLE.COM "
        form.cloudflareTeamDomain = " TEAM.CLOUDFLAREACCESS.COM "
        form.cloudflareAudience = " Aud_123 "
        let settings = try form.cloudflareSettings()
        let saved = try form.validatedConnection(from: original, host: " real-host.internal ", port: " 2222 ", usesMosh: false)
        #expect(try saved.validatedTransport() == .cloudflare(settings))
        #expect(saved.transportRaw == "cloudflareSSH")
        #expect(saved.useSOCKSProxy == false)
        #expect(saved.cloudflareHostname == settings.hostname)
        #expect(saved.cloudflareTeamDomain == settings.teamDomain)
        #expect(saved.cloudflareAudience == settings.audience)
        #expect(saved.host == "real-host.internal")
        #expect(saved.port == 2222)
        #expect(saved.multiplexer == .herdr)
        #expect(saved.keychainRef == "existing-ssh-key")
        #expect(saved.id == original.id)
        #expect(throws: ConnectionTransportError.cloudflareRequiresSSH) {
            try form.validatedConnection(from: original, host: original.host, port: "22", usesMosh: true)
        }
    }

    @Test("Incomplete manual Cloudflare fields block login and saving without switching to discovery")
    func incompleteCloudflare() {
        var form = ConnectionTransportForm()
        form.selection = .cloudflareSSH
        form.cloudflareManualConfiguration = true
        form.cloudflareHostname = "ssh.example.com"
        form.cloudflareTeamDomain = "team.cloudflareaccess.com"
        #expect(throws: ConnectionTransportError.invalidCloudflareAudience) { try form.cloudflareSettings() }
        #expect(throws: ConnectionTransportError.invalidCloudflareAudience) {
            try form.validatedConnection(from: ServerConnection(), host: "host.internal", port: "22", usesMosh: false)
        }
    }

    @Test("A hostname-only Cloudflare connection saves offline and follows Host edits after reload")
    func automaticConfigurationFollowsHost() throws {
        var form = ConnectionTransportForm()
        form.selection = .cloudflareSSH
        let original = ServerConnection(host: "old.example.com")
        let saved = try form.validatedConnection(from: original, host: " FIRST.EXAMPLE.COM ", port: "22", usesMosh: false)
        #expect(saved.cloudflareHostname == nil)
        #expect(saved.cloudflareTeamDomain == nil)
        #expect(saved.cloudflareAudience == nil)
        #expect(try saved.validatedTransport() == .cloudflare(.init(hostname: "first.example.com", teamDomain: "", audience: "")))
        let restored = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(saved))
        form = ConnectionTransportForm(connection: restored)
        #expect(!form.cloudflareManualConfiguration)
        let edited = try form.validatedConnection(from: restored, host: "second.example.com", port: "22", usesMosh: false)
        #expect(edited.cloudflareHostname == nil)
        #expect(try edited.validatedTransport() == .cloudflare(try form.cloudflareSettings(host: "second.example.com")))
    }

    @Test("An explicit entry override survives a logical SSH host edit in automatic mode")
    func automaticEntryOverride() throws {
        var form = ConnectionTransportForm()
        form.selection = .cloudflareSSH
        form.cloudflareHostname = " ENTRY.EXAMPLE.COM "
        let saved = try form.validatedConnection(from: ServerConnection(), host: "100.64.0.1", port: "22", usesMosh: false)
        #expect(saved.cloudflareHostname == "entry.example.com")
        #expect(saved.host == "100.64.0.1")
        #expect(try saved.validatedTransport() == .cloudflare(.init(hostname: "entry.example.com", teamDomain: "", audience: "")))
    }

    @Test("Legacy manual metadata is preserved until the user chooses automatic configuration")
    func manualMigrationAndAutomaticSelection() throws {
        var original = ServerConnection(host: "ssh.example.com")
        original.selectTransport(.cloudflareSSH)
        original.cloudflareTeamDomain = "team.cloudflareaccess.com"
        original.cloudflareAudience = "aud-123"
        var form = ConnectionTransportForm(connection: original)
        #expect(form.cloudflareManualConfiguration)
        #expect(try form.applying(to: original).validatedTransport() == original.validatedTransport())
        form.cloudflareManualConfiguration = false
        let automatic = try form.applying(to: original)
        #expect(automatic.cloudflareTeamDomain == nil)
        #expect(automatic.cloudflareAudience == nil)
        #expect(try form.cloudflareSettings(host: automatic.host).usesAutomaticDiscovery)
    }

    @Test("Selecting manual configuration with both fields empty cannot silently enable automatic mode")
    func emptyManualConfiguration() {
        var form = ConnectionTransportForm()
        form.selection = .cloudflareSSH
        form.cloudflareManualConfiguration = true
        #expect(throws: ConnectionTransportError.invalidCloudflareTeamDomain) {
            try form.validatedConnection(from: ServerConnection(), host: "ssh.example.com", port: "22", usesMosh: false)
        }
    }

    @Test("A Tailcat draft stores only public metadata and leaves SSH authentication intact")
    func tailcatDraft() throws {
        let original = ServerConnection(host: "", keychainRef: "existing-ssh-secret")
        var form = ConnectionTransportForm(connection: original)
        form.selection = .tailcat
        form.tailcatAddress = " \n" + TailcatCredentialFixture.address + "\n"
        #expect(!String(describing: form).contains(TailcatCredentialFixture.address))
        #expect(!String(reflecting: form).contains(TailcatCredentialFixture.address))
        let connection = try form.validatedConnection(from: original, host: "", port: "2222", usesMosh: false)
        #expect(connection.host.hasPrefix("tailcat-"))
        #expect(connection.keychainRef == original.keychainRef)
        #expect(connection.port == 2222)
        #expect(connection.useSOCKSProxy == false)
        guard case .tailcat(let settings) = try connection.validatedTransport() else {
            Issue.record("Tailcat draft selected a different transport")
            return
        }
        #expect(settings.serverPublicKey.hasPrefix("nodekey:"))
        let encoded = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        #expect(!encoded.contains(TailcatCredentialFixture.address))
        #expect(!encoded.contains("preshared"))
        #expect(!encoded.contains("privateKey"))
        #expect(throws: ConnectionTransportError.tailcatRequiresSSH) {
            try form.validatedConnection(from: original, host: "mac-mini", port: "22", usesMosh: true)
        }
    }

    @Test("Editing Tailcat without replacing its address preserves its credential reference")
    func unchangedTailcatCredential() throws {
        var original = ServerConnection(host: "mac-mini")
        original.selectTransport(.tailcat)
        original.tailcatCredentialRef = TailcatCredentials.newReference()
        original.tailcatServerPublicKey = "nodekey:" + String(repeating: "a", count: 64)
        var form = ConnectionTransportForm(connection: original)
        #expect(form.tailcatAddress.isEmpty)
        let edited = try form.validatedConnection(from: original, host: "renamed-mac", port: "22", usesMosh: false)
        #expect(edited.tailcatCredentialRef == original.tailcatCredentialRef)
        #expect(edited.tailcatServerPublicKey == original.tailcatServerPublicKey)
        form.selection = .direct
        let direct = try form.validatedConnection(from: original, host: "mac-mini.local", port: "22", usesMosh: false)
        #expect(direct.tailcatCredentialRef == nil)
        #expect(direct.tailcatServerPublicKey == nil)
        #expect(original.tailcatCredentialRef != nil, "Only successful save commits a changed reference")
    }

    @Test("Tailcat capability addresses cannot be saved as a public host alias")
    func tailcatAddressIsNotHostAlias() {
        var form = ConnectionTransportForm()
        form.selection = .tailcat
        form.tailcatAddress = TailcatCredentialFixture.address
        #expect(throws: ConnectionTransportError.invalidTailcatHostAlias) {
            try form.validatedConnection(from: ServerConnection(), host: TailcatCredentialFixture.address, port: "22", usesMosh: false)
        }
    }

    @Test("Tailcat form rejects insecure or malformed addresses before saving")
    func tailcatInvalidAddresses() {
        var form = ConnectionTransportForm()
        form.selection = .tailcat
        form.tailcatAddress = TailcatCredentialFixture.addressWithoutPSK
        #expect(throws: TailcatCredentialError.missingPresharedKey) { try form.applying(to: ServerConnection()) }
        form.tailcatAddress = "tcSECRET\u{0}tail"
        #expect(throws: TailcatCredentialError.invalidAddress) { try form.applying(to: ServerConnection()) }
    }

    @Test("Tailscale saves an explicit account binding and keeps SSH credentials and session mode")
    func tailscaleBoundDraft() throws {
        var original = ServerConnection(host: "old", keychainRef: "ssh-private-key")
        original.multiplexer = .herdr
        original.tailcatCredentialRef = TailcatCredentials.newReference()
        original.tailcatServerPublicKey = "nodekey:" + String(repeating: "a", count: 64)
        var form = ConnectionTransportForm(connection: original)
        form.selection = .tailscale
        #expect(throws: ConnectionTransportError.invalidTailscaleConfiguration) {
            try form.validatedConnection(from: original, host: "mac.tailnet.ts.net", port: "22", usesMosh: false)
        }
        let accountID = UUID().uuidString
        form.bindTailscaleAccount(accountID)
        form.selectTailscalePeer(id: "n123example", host: "mac.tailnet.ts.net")
        let saved = try form.validatedConnection(from: original, host: " mac.tailnet.ts.net ", port: "2222", usesMosh: false)
        #expect(try saved.validatedTransport() == .tailscale(.init(accountID: accountID, peerID: "n123example")))
        #expect(saved.keychainRef == original.keychainRef)
        #expect(saved.multiplexer == .herdr)
        #expect(saved.port == 2222)
        #expect(saved.tailcatCredentialRef == nil)
        #expect(saved.tailcatServerPublicKey == nil)
        #expect(saved.useSOCKSProxy == false)
    }

    @Test("A manual Tailscale endpoint edit cannot retain another peer's identity")
    func tailscaleManualHostClearsPeer() throws {
        var original = ServerConnection(host: "mac.tailnet.ts.net", tailscaleAccountID: UUID().uuidString, tailscalePeerID: "n111")
        original.selectTransport(.tailscale)
        let form = ConnectionTransportForm(connection: original)
        #expect(form.effectiveTailscalePeerID(host: " mac.tailnet.ts.net ") == "n111")
        #expect(form.effectiveTailscalePeerID(host: "100.64.0.2") == nil)
        let unchanged = try form.validatedConnection(from: original, host: original.host, port: "22", usesMosh: false)
        #expect(unchanged.tailscalePeerID == "n111")
        let edited = try form.validatedConnection(from: original, host: "100.64.0.2", port: "22", usesMosh: false)
        #expect(edited.tailscalePeerID == nil)
        #expect(edited.tailscaleAccountID == original.tailscaleAccountID)
        #expect(original.tailscalePeerID == "n111")
    }

    @Test("Explicit Tailscale account changes discard the former peer binding")
    func tailscaleAccountRebinding() throws {
        var original = ServerConnection(host: "mac", tailscaleAccountID: UUID().uuidString, tailscalePeerID: "n111")
        original.selectTransport(.tailscale)
        var form = ConnectionTransportForm(connection: original)
        let nextAccountID = UUID().uuidString
        form.bindTailscaleAccount(nextAccountID)
        #expect(form.tailscalePeerID == nil)
        #expect(form.tailscalePeerHost == nil)
        form.selectTailscalePeer(id: "n222", host: "other-mac")
        let saved = try form.validatedConnection(from: original, host: "other-mac", port: "22", usesMosh: false)
        #expect(saved.tailscaleAccountID == nextAccountID)
        #expect(saved.tailscalePeerID == "n222")
        #expect(original.tailscaleAccountID != nextAccountID)
    }

    @Test("Leaving the Tailscale transport clears inactive account metadata")
    func leavingTailscaleClearsBinding() throws {
        var original = ServerConnection(host: "mac", tailscaleAccountID: UUID().uuidString, tailscalePeerID: "n111")
        original.selectTransport(.tailscale)
        var form = ConnectionTransportForm(connection: original)
        form.selection = .direct
        let saved = try form.validatedConnection(from: original, host: "mac.local", port: "22", usesMosh: true)
        #expect(saved.tailscaleAccountID == nil)
        #expect(saved.tailscalePeerID == nil)
        #expect(try saved.validatedTransport() == .direct)
        #expect(saved.connectionProtocol == .mosh)
    }

    @Test("Tailscale Save requires the same connected account that was explicitly bound")
    func tailscaleSaveAccountGate() {
        var form = ConnectionTransportForm()
        let accountID = UUID().uuidString
        #expect(!form.isTailscaleAccountReady(currentAccountID: accountID, state: .connected))
        form.bindTailscaleAccount(accountID)
        #expect(form.isTailscaleAccountReady(currentAccountID: accountID, state: .connected))
        #expect(!form.isTailscaleAccountReady(currentAccountID: UUID().uuidString, state: .connected))
        #expect(!form.isTailscaleAccountReady(currentAccountID: nil, state: .connected))
        for state in [TailscaleAccountState.signedOut, .starting, .needsLogin, .needsApproval, .failed] {
            #expect(!form.isTailscaleAccountReady(currentAccountID: accountID, state: state))
        }
        #expect(form.tailscaleAccountID == accountID, "Account state changes cannot silently rebind the draft")
    }
}
