import Foundation

enum AuthMethod: String, Codable, CaseIterable {
    case password
    case key
}

enum ConnectionProtocol: String, Codable, CaseIterable {
    case ssh
    case mosh

    var label: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        }
    }

    var icon: String {
        switch self {
        case .ssh: return "lock.fill"
        case .mosh: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// The path carrying SSH bytes. Independent of the remote session mode.
enum ConnectionTransport: String, Codable, CaseIterable, Sendable {
    case direct
    case socks5
    case cloudflareSSH
    case tailcat
    case tailscale

    var label: String {
        switch self {
        case .direct: return String(localized: "Direct")
        case .socks5: return "SOCKS5"
        case .cloudflareSSH: return String(localized: "Cloudflare SSH (Experimental)")
        case .tailcat: return String(localized: "Tailcat (Experimental)")
        case .tailscale: return String(localized: "Tailscale (Experimental)")
        }
    }

    var requiresSSH: Bool { self == .cloudflareSSH || self == .tailcat || self == .tailscale }
}

/// Binds a saved host to the app's Tailscale account and, when selected from
/// discovery, its stable peer identity. No node credentials belong here.
struct TailscaleConnectionSettings: Equatable, Hashable, Sendable {
    var accountID: String
    var peerID: String?

    static func validated(accountID: String?, peerID: String?) throws -> Self {
        guard let accountID, UUID(uuidString: accountID) != nil else {
            throw ConnectionTransportError.invalidTailscaleConfiguration
        }
        if let peerID {
            guard !peerID.isEmpty, peerID.utf8.count <= 128,
                  peerID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
                throw ConnectionTransportError.invalidTailscaleConfiguration
            }
        }
        return Self(accountID: accountID, peerID: peerID)
    }
}

/// Public routing metadata only. The tc address contains a shared secret and
/// must stay in the separate Tailcat Keychain service, including on Simulator.
struct TailcatConnectionSettings: Equatable, Hashable, Sendable {
    var credentialRef: String
    var serverPublicKey: String

    /// Trust is scoped to the remote node identity, never a local forwarding
    /// port or a user-editable display alias shared by unrelated servers.
    var hostKeyIdentity: String { "tailcat-" + serverPublicKey.dropFirst("nodekey:".count) + ".invalid" }

    static func validated(credentialRef: String?, serverPublicKey: String?) throws -> Self {
        guard let credentialRef, TailcatCredentials.isReference(credentialRef),
              let serverPublicKey, isNodePublicKey(serverPublicKey) else {
            throw ConnectionTransportError.invalidTailcatConfiguration
        }
        return Self(credentialRef: credentialRef, serverPublicKey: serverPublicKey)
    }

    static func isNodePublicKey(_ value: String) -> Bool {
        let prefix = "nodekey:"
        guard value.hasPrefix(prefix) else { return false }
        let bytes = value.dropFirst(prefix.count).utf8
        return bytes.count == 64 && bytes.contains(where: { $0 != 48 })
            && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Public configuration only. Access credentials belong in Keychain, separately
/// from the SSH password/key and from the connection's logical host identity.
struct CloudflareConnectionSettings: Equatable, Hashable, Sendable {
    var hostname: String
    var teamDomain: String
    var audience: String

    /// Empty metadata selects anonymous discovery during explicit login.
    /// Verified application bindings and credentials are kept in Keychain.
    var usesAutomaticDiscovery: Bool { teamDomain.isEmpty && audience.isEmpty }

    static func validated(hostname: String, teamDomain: String, audience: String) throws -> Self {
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let teamDomain = teamDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let audience = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHostname(hostname) else { throw ConnectionTransportError.invalidCloudflareHostname }
        if teamDomain.isEmpty && audience.isEmpty {
            return Self(hostname: hostname, teamDomain: "", audience: "")
        }
        guard isHostname(teamDomain), teamDomain.hasSuffix(".cloudflareaccess.com"),
              !teamDomain.hasSuffix(".fed.cloudflareaccess.com") else {
            throw ConnectionTransportError.invalidCloudflareTeamDomain
        }
        guard !audience.isEmpty, audience.utf8.count <= 256,
              audience.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw ConnectionTransportError.invalidCloudflareAudience
        }
        return Self(hostname: hostname, teamDomain: teamDomain, audience: audience)
    }

    private static func isHostname(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains("."), value.utf8.allSatisfy({ $0 < 128 }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

enum SSHTransportConfiguration: Equatable, Sendable {
    case direct
    case socks5(host: String, port: Int)
    case cloudflare(CloudflareConnectionSettings)
    case tailcat(TailcatConnectionSettings)
    case tailscale(TailscaleConnectionSettings)
}

/// Configuration errors are permanent until the user edits the connection;
/// callers must not turn these into a direct dial or an automatic retry loop.
enum ConnectionTransportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedTransport(String)
    case conflictingSOCKSProxy
    case invalidSSHHost
    case invalidSSHPort
    case invalidSOCKSHost
    case invalidSOCKSPort
    case invalidCloudflareHostname
    case invalidCloudflareTeamDomain
    case invalidCloudflareAudience
    case cloudflareRequiresSSH
    case tailcatRequiresSSH
    case invalidTailcatConfiguration
    case invalidTailcatHostAlias
    case tailscaleRequiresSSH
    case invalidTailscaleConfiguration

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return String(localized: "This connection uses an unsupported transport. Choose a supported transport before connecting.")
        case .conflictingSOCKSProxy:
            return String(localized: "This connection has conflicting transport settings. Choose its transport again.")
        case .invalidSSHHost:
            return String(localized: "Enter an SSH hostname or IP address without a URL scheme, path, or whitespace.")
        case .invalidSSHPort:
            return String(localized: "Enter an SSH port from 1 to 65535.")
        case .invalidSOCKSHost:
            return String(localized: "Enter a SOCKS5 proxy hostname or IP address without a URL scheme, path, or whitespace.")
        case .invalidSOCKSPort:
            return String(localized: "Enter a SOCKS5 proxy port from 1 to 65535.")
        case .invalidCloudflareHostname:
            return String(localized: "Enter the Cloudflare SSH hostname without https://, a port, or a path.")
        case .invalidCloudflareTeamDomain:
            return String(localized: "Enter your Access team domain, such as team.cloudflareaccess.com. Federal team domains are not supported.")
        case .invalidCloudflareAudience:
            return String(localized: "Enter the Access application's Audience (AUD) identifier.")
        case .cloudflareRequiresSSH:
            return String(localized: "Cloudflare SSH carries TCP only. Select SSH instead of Mosh for this connection.")
        case .tailcatRequiresSSH:
            return String(localized: "This Tailcat connection carries SSH over TCP. Select SSH instead of Mosh.")
        case .invalidTailcatConfiguration:
            return String(localized: "Paste a Tailcat address and save this connection before connecting.")
        case .invalidTailcatHostAlias:
            return String(localized: "Use a name such as mac-mini for the SSH host alias. Paste the secret tc address only in the Tailcat address field.")
        case .tailscaleRequiresSSH:
            return String(localized: "This Tailscale connection carries SSH over TCP. Select SSH instead of Mosh.")
        case .invalidTailscaleConfiguration:
            return String(localized: "Sign in to Tailscale in this app and select an account for this connection.")
        }
    }
}

/// Which multiplexer a connection drives on the remote host.
///
/// tmux and herdr COEXIST rather than replace one another: they are separate
/// servers holding unrelated sessions, so a host missing the chosen one is
/// never silently switched to the other — that would show the user someone
/// else's work and call it theirs. The choice is per connection because one
/// person's hosts rarely all have the same tools installed.
enum Multiplexer: String, Codable, CaseIterable, Sendable {
    /// No multiplexer — one plain shell pane, no session persistence.
    case none
    case tmux
    /// herdr (<https://herdr.dev>) — a multiplexer built for CLI coding
    /// agents. It tracks agent status itself, so the Vibe Island needs no
    /// host-side hooks installed.
    case herdr

    var label: String {
        switch self {
        case .none:  return String(localized: "None")
        case .tmux:  return "tmux"
        case .herdr: return "herdr"
        }
    }

    /// One-line "what am I picking" for the form row. Deliberately concrete —
    /// the user is choosing between two things they may never have compared.
    var subtitle: String {
        switch self {
        case .none:
            return String(localized: "Single shell, no session persistence")
        case .tmux:
            return String(localized: "Mature, already on nearly every host")
        case .herdr:
            return String(localized: "Built for coding agents — agent status needs no hooks")
        }
    }

    /// SF Symbol standing in for this choice, so the picker reads at a glance
    /// instead of asking you to parse two lowercase tool names.
    ///
    /// Each one says what the thing IS rather than decorating it: a single
    /// shell, a split grid, and the agent sparkle the workbench already uses
    /// for every agent row — herdr's whole point is that it tracks agents.
    var symbol: String {
        switch self {
        case .none:  return "terminal"
        case .tmux:  return "rectangle.split.2x2"
        case .herdr: return "sparkles"
        }
    }

    /// Binary probed on PATH and used to boot the session. `nil` for `.none`.
    var binaryName: String? {
        switch self {
        case .none:  return nil
        case .tmux:  return "tmux"
        case .herdr: return "herdr"
        }
    }
}

struct ServerConnection: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var connectionProtocol: ConnectionProtocol
    /// SSH port for mosh bootstrap (default 22)
    var sshPort: Int
    /// Mosh UDP port range start (default 60001)
    var moshPortRangeStart: Int
    /// Mosh UDP port range end (default 60999)
    var moshPortRangeEnd: Int
    /// Custom mosh-server binary path on the remote host (e.g. /usr/local/bin/mosh-server)
    var moshServerPath: String?
    /// For password auth, stored in Keychain (not here).
    /// For key auth, this is the Keychain reference ID.
    var keychainRef: String?
    var createdAt: Date
    var lastConnectedAt: Date?

    // MARK: - Enhance page fields

    /// Startup command to run after connection (e.g. "cd ~/project")
    var startupCommand: String?
    /// Forward SSH agent to remote host
    var forwardAgent: Bool
    /// Enable SSH compression
    var compression: Bool
    /// Keep-alive interval in seconds (0 = disabled)
    var keepAliveInterval: Int
    /// Jump host for ProxyJump (e.g. "bastion.example.com")
    var jumpHost: String?
    /// Route connection through Tailscale VPN
    var useTailscale: Bool
    /// Auto-attach to tmux session if only one exists
    var tmuxAutoAttach: Bool
    /// Offer to create a new tmux session
    var tmuxCreateNew: Bool
    /// Enable tmux integration.
    ///
    /// LEGACY — superseded by ``multiplexer``. Kept as a stored field so
    /// connections saved before the multiplexer picker existed still decode to
    /// the same behaviour, and so rolling back to an older build doesn't
    /// silently drop a user's tmux setting. `multiplexerRaw` wins when present.
    var useTmux: Bool

    // MARK: - Prototype v2 fields (optional so stored JSON keeps decoding)

    /// Mosh predictive-echo mode ("adaptive" default). Stored raw so the
    /// struct stays Codable-stable.
    var predictModeRaw: String?
    /// Reconnect over 5G/LTE when Wi-Fi drops (prototype "Roam on Cellular").
    var roamOnCellular: Bool?
    /// Custom tmux binary path on the remote host.
    var tmuxPath: String?
    /// Custom herdr binary path on the remote host.
    var herdrPath: String?
    /// Selected multiplexer, stored raw so the struct stays Codable-stable.
    /// `nil` on anything saved before the picker existed — ``multiplexer``
    /// then falls back to ``useTmux``.
    var multiplexerRaw: String?
    /// When the user picked a managed key from SSH Keys (instead of pasting a
    /// PEM), these reference the `SSHKeyRecord`: id for UI display, raw
    /// algorithm so `SSHService` knows how to interpret the keychain blob
    /// (Secure Enclave keys are a `dataRepresentation`, not PEM).
    var sshKeyId: UUID?
    var sshKeyAlgorithmRaw: String?
    /// Route this connection's SSH dial through a SOCKS5 proxy (Add
    /// Connection → Proxy). Optional, like the rest of this section, so
    /// connections saved before this field existed keep decoding — `nil`
    /// behaves exactly like `false`, dialing `host`/`port` directly.
    var useSOCKSProxy: Bool?
    var socksProxyHost: String?
    /// `nil` ⇒ 1080, the conventional SOCKS5 default.
    var socksProxyPort: Int?

    /// Missing on legacy records. Unknown values are retained by Codable but
    /// rejected by validatedTransport(), never interpreted as direct.
    var transportRaw: String?
    var cloudflareHostname: String?
    var cloudflareTeamDomain: String?
    var cloudflareAudience: String?
    var tailcatCredentialRef: String?
    var tailcatServerPublicKey: String?
    var tailscaleAccountID: String?
    var tailscalePeerID: String?

    var transport: ConnectionTransport? {
        if let transportRaw { return ConnectionTransport(rawValue: transportRaw) }
        return useSOCKSProxy == true ? .socks5 : .direct
    }

    /// Explicit selection normalizes the legacy flag. Inactive endpoint fields
    /// may be kept for editing, but only validatedTransport() chooses a route.
    mutating func selectTransport(_ transport: ConnectionTransport) {
        transportRaw = transport.rawValue
        useSOCKSProxy = transport == .socks5
    }

    func validatedTransport() throws -> SSHTransportConfiguration {
        guard let transport else {
            throw ConnectionTransportError.unsupportedTransport(transportRaw ?? "")
        }
        if transportRaw != nil, transport != .socks5, useSOCKSProxy == true {
            throw ConnectionTransportError.conflictingSOCKSProxy
        }
        switch transport {
        case .direct:
            return .direct
        case .socks5:
            let host = (socksProxyHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSSHHostname(host), host.utf8.count <= 255 else {
                throw ConnectionTransportError.invalidSOCKSHost
            }
            let port = socksProxyPort ?? 1080
            guard (1...65535).contains(port) else { throw ConnectionTransportError.invalidSOCKSPort }
            return .socks5(host: host, port: port)
        case .cloudflareSSH:
            guard connectionProtocol == .ssh else { throw ConnectionTransportError.cloudflareRequiresSSH }
            return .cloudflare(try CloudflareConnectionSettings.validated(
                hostname: cloudflareHostname ?? host, teamDomain: cloudflareTeamDomain ?? "",
                audience: cloudflareAudience ?? ""))
        case .tailcat:
            guard connectionProtocol == .ssh else { throw ConnectionTransportError.tailcatRequiresSSH }
            return .tailcat(try TailcatConnectionSettings.validated(
                credentialRef: tailcatCredentialRef, serverPublicKey: tailcatServerPublicKey))
        case .tailscale:
            guard connectionProtocol == .ssh else { throw ConnectionTransportError.tailscaleRequiresSSH }
            return .tailscale(try TailscaleConnectionSettings.validated(
                accountID: tailscaleAccountID, peerID: tailscalePeerID))
        }
    }

    /// Allows ordinary DNS/MagicDNS names and IPv4/IPv6 literals. Schemes and
    /// shell/URL decorations are not part of an SSH network endpoint.
    static func isSSHHostname(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("://") && !value.contains(where: {
            $0.isWhitespace || $0.isNewline || "/@?#".contains($0)
        }) && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    var sshKeyAlgorithm: SSHKeyAlgorithm? {
        sshKeyAlgorithmRaw.flatMap(SSHKeyAlgorithm.init(rawValue:))
    }

    var predictMode: PredictMode {
        get { predictModeRaw.flatMap(PredictMode.init(rawValue:)) ?? .adaptive }
        set { predictModeRaw = newValue.rawValue }
    }

    /// Which multiplexer to drive. Migration: stored JSON written before the
    /// picker existed has no `multiplexerRaw`, and `useTmux` was hardcoded
    /// `true` by the form — so those connections land on `.tmux` and behave
    /// exactly as they did.
    var multiplexer: Multiplexer {
        get { multiplexerRaw.flatMap(Multiplexer.init(rawValue:)) ?? (useTmux ? .tmux : .none) }
        set {
            multiplexerRaw = newValue.rawValue
            // Keep the legacy flag consistent with the new one so an older
            // build reading the same store makes the same decision.
            useTmux = newValue == .tmux
        }
    }

    /// Custom binary path for the SELECTED multiplexer, or nil to use PATH.
    /// A non-nil path means the user vouches for the binary, which skips the
    /// capability probe's degrade check (the probe walks PATH, not custom
    /// locations).
    var multiplexerPath: String? {
        switch multiplexer {
        case .none:  return nil
        case .tmux:  return tmuxPath
        case .herdr: return herdrPath
        }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        connectionProtocol: ConnectionProtocol = .ssh,
        sshPort: Int = 22,
        moshPortRangeStart: Int = 60001,
        moshPortRangeEnd: Int = 60999,
        moshServerPath: String? = nil,
        keychainRef: String? = nil,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        startupCommand: String? = nil,
        forwardAgent: Bool = false,
        compression: Bool = false,
        keepAliveInterval: Int = 60,
        jumpHost: String? = nil,
        useTailscale: Bool = false,
        tmuxAutoAttach: Bool = true,
        tmuxCreateNew: Bool = true,
        useTmux: Bool = false,
        predictModeRaw: String? = nil,
        roamOnCellular: Bool? = nil,
        tmuxPath: String? = nil,
        herdrPath: String? = nil,
        multiplexerRaw: String? = nil,
        transportRaw: String? = nil,
        cloudflareHostname: String? = nil,
        cloudflareTeamDomain: String? = nil,
        cloudflareAudience: String? = nil,
        tailcatCredentialRef: String? = nil,
        tailcatServerPublicKey: String? = nil,
        tailscaleAccountID: String? = nil,
        tailscalePeerID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.connectionProtocol = connectionProtocol
        self.sshPort = sshPort
        self.moshPortRangeStart = moshPortRangeStart
        self.moshPortRangeEnd = moshPortRangeEnd
        self.moshServerPath = moshServerPath
        self.keychainRef = keychainRef
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.startupCommand = startupCommand
        self.forwardAgent = forwardAgent
        self.compression = compression
        self.keepAliveInterval = keepAliveInterval
        self.jumpHost = jumpHost
        self.useTailscale = useTailscale
        self.tmuxAutoAttach = tmuxAutoAttach
        self.tmuxCreateNew = tmuxCreateNew
        self.useTmux = useTmux
        self.predictModeRaw = predictModeRaw
        self.roamOnCellular = roamOnCellular
        self.tmuxPath = tmuxPath
        self.herdrPath = herdrPath
        self.multiplexerRaw = multiplexerRaw
        self.transportRaw = transportRaw
        self.cloudflareHostname = cloudflareHostname
        self.cloudflareTeamDomain = cloudflareTeamDomain
        self.cloudflareAudience = cloudflareAudience
        self.tailcatCredentialRef = tailcatCredentialRef
        self.tailcatServerPublicKey = tailcatServerPublicKey
        self.tailscaleAccountID = tailscaleAccountID
        self.tailscalePeerID = tailscalePeerID
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }
}
