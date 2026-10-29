import Foundation
import TailcatSSH

/// Shared by save, button enablement, and the Access login controls. Keeping
/// text parsing here prevents invalid ports from silently becoming defaults.
struct ConnectionTransportForm: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "ConnectionTransportForm(<private input>)" }
    var debugDescription: String { description }
    var selection: ConnectionTransport? = .direct
    var unsupportedRaw: String?
    var socksHost = ""
    var socksPort = "1080"
    var cloudflareHostname = ""
    var cloudflareTeamDomain = ""
    var cloudflareAudience = ""
    var cloudflareManualConfiguration = false
    /// Draft-only secret input. This form is never encoded or persisted.
    /// An empty value while editing keeps the existing Keychain item.
    var tailcatAddress = ""
    var tailscaleAccountID: String?
    var tailscalePeerID: String?
    private(set) var tailscalePeerHost: String?
    private let tailcatDraftReference = TailcatCredentials.newReference()

    init(connection: ServerConnection? = nil) {
        guard let connection else { return }
        selection = connection.transport
        unsupportedRaw = selection == nil ? connection.transportRaw : nil
        socksHost = connection.socksProxyHost ?? ""
        socksPort = connection.socksProxyPort.map(String.init) ?? "1080"
        cloudflareHostname = connection.cloudflareHostname ?? ""
        cloudflareTeamDomain = connection.cloudflareTeamDomain ?? ""
        cloudflareAudience = connection.cloudflareAudience ?? ""
        cloudflareManualConfiguration = !cloudflareTeamDomain.isEmpty || !cloudflareAudience.isEmpty
        tailscaleAccountID = connection.tailscaleAccountID
        tailscalePeerID = connection.tailscalePeerID
        tailscalePeerHost = connection.tailscalePeerID == nil ? nil : connection.host
    }

    mutating func bindTailscaleAccount(_ accountID: String) {
        tailscaleAccountID = accountID
        tailscalePeerID = nil
        tailscalePeerHost = nil
    }

    mutating func selectTailscalePeer(id: String, host: String) {
        tailscalePeerID = id
        tailscalePeerHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The visible selection and saved binding must agree after manual edits.
    func effectiveTailscalePeerID(host: String) -> String? {
        guard selection == .tailscale,
              tailscalePeerHost == host.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return tailscalePeerID
    }

    func isTailscaleAccountReady(currentAccountID: String?, state: TailscaleAccountState) -> Bool {
        state == .connected && tailscaleAccountID != nil && tailscaleAccountID == currentAccountID
    }

    func cloudflareSettings(host: String = "") throws -> CloudflareConnectionSettings {
        if cloudflareManualConfiguration {
            guard nonempty(cloudflareTeamDomain) != nil else { throw ConnectionTransportError.invalidCloudflareTeamDomain }
            guard nonempty(cloudflareAudience) != nil else { throw ConnectionTransportError.invalidCloudflareAudience }
        }
        return try CloudflareConnectionSettings.validated(
            hostname: nonempty(cloudflareHostname) ?? host,
            teamDomain: cloudflareManualConfiguration ? cloudflareTeamDomain : "",
            audience: cloudflareManualConfiguration ? cloudflareAudience : "")
    }

    func applying(to original: ServerConnection) throws -> ServerConnection {
        guard let selection else { throw ConnectionTransportError.unsupportedTransport(unsupportedRaw ?? "") }
        var connection = original
        connection.selectTransport(selection)
        connection.socksProxyHost = nonempty(socksHost)
        let proxyPort = socksPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection == .socks5 {
            guard let parsed = Int(proxyPort), (1...65535).contains(parsed) else {
                throw ConnectionTransportError.invalidSOCKSPort
            }
            connection.socksProxyPort = parsed
        } else {
            connection.socksProxyPort = Int(proxyPort)
        }
        connection.cloudflareHostname = nonempty(cloudflareHostname)
        connection.cloudflareTeamDomain = cloudflareManualConfiguration ? nonempty(cloudflareTeamDomain) : nil
        connection.cloudflareAudience = cloudflareManualConfiguration ? nonempty(cloudflareAudience) : nil
        if selection == .cloudflareSSH {
            // Validate the selected mode explicitly: two empty manual fields
            // must not accidentally switch a manual override to automatic.
            _ = try cloudflareSettings(host: connection.host)
        }
        if selection == .tailcat {
            if let address = nonempty(tailcatAddress) {
                let metadata: TailcatAddressMetadata
                do { metadata = try TailcatIdentity.parseAddress(address) }
                catch { throw TailcatCredentialError.invalidAddress }
                guard metadata.hasPresharedKey else { throw TailcatCredentialError.missingPresharedKey }
                connection.tailcatCredentialRef = tailcatDraftReference
                connection.tailcatServerPublicKey = metadata.serverPublicKey
            }
        } else {
            connection.tailcatCredentialRef = nil
            connection.tailcatServerPublicKey = nil
        }
        connection.tailscaleAccountID = selection == .tailscale ? tailscaleAccountID : nil
        connection.tailscalePeerID = selection == .tailscale ? tailscalePeerID : nil
        let validated = try connection.validatedTransport()
        if case .cloudflare(let settings) = validated {
            // An absent override follows the Host field on subsequent edits.
            if connection.cloudflareHostname != nil { connection.cloudflareHostname = settings.hostname }
            connection.cloudflareTeamDomain = nonempty(settings.teamDomain)
            connection.cloudflareAudience = nonempty(settings.audience)
        }
        return connection
    }

    func validatedConnection(from original: ServerConnection, host: String, port: String,
                             usesMosh: Bool) throws -> ServerConnection {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection == .tailcat {
            guard (host.isEmpty || ServerConnection.isSSHHostname(host)),
                  !(host.hasPrefix("tc") && host.utf8.count > 40) else {
                throw ConnectionTransportError.invalidTailcatHostAlias
            }
        } else {
            guard ServerConnection.isSSHHostname(host) else { throw ConnectionTransportError.invalidSSHHost }
        }
        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            throw ConnectionTransportError.invalidSSHPort
        }
        var connection = original
        connection.host = host
        connection.port = port
        connection.sshPort = port
        connection.connectionProtocol = usesMosh ? .mosh : .ssh
        connection = try applying(to: connection)
        if selection == .tailscale {
            // Manual endpoint edits must not retain a stale peer identity.
            connection.tailscalePeerID = effectiveTailscalePeerID(host: host)
        }
        if selection == .tailcat, host.isEmpty, let publicKey = connection.tailcatServerPublicKey {
            connection.host = "tailcat-" + publicKey.dropFirst("nodekey:".count).prefix(12)
        }
        return connection
    }

    private func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
