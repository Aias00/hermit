import Foundation

/// Enrollment state belongs to the app installation, not to individual SSH
/// hosts. The encryption key must come from the platform's secure storage.
public struct TailscaleNodeConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultControlURL = URL(string: "https://controlplane.tailscale.com")!
    public let stateDirectory: URL
    public let hostname: String
    public let controlURL: URL
    let stateEncryptionKey: Data

    public init(stateDirectory: URL, stateEncryptionKey: Data, hostname: String,
                controlURL: URL = Self.defaultControlURL) throws {
        guard stateDirectory.isFileURL, stateDirectory.path.hasPrefix("/"),
              stateDirectory.path != "/", !stateDirectory.path.utf8.contains(0),
              stateDirectory.query == nil, stateDirectory.fragment == nil,
              stateEncryptionKey.count == 32,
              Self.isHostname(hostname),
              Self.isControlURL(controlURL) else { throw TailscaleSSHTransportError.invalidConfiguration }
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.stateEncryptionKey = stateEncryptionKey
        self.hostname = hostname
        self.controlURL = controlURL
    }

    public var description: String { "TailscaleNodeConfiguration(<redacted>)" }
    public var debugDescription: String { description }

    private static func isHostname(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 63 && value.first != "-" && value.last != "-"
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }

    private static func isControlURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil else { return false }
        return components.scheme == "https"
    }
}

public struct TailscalePeer: Equatable, Sendable, Identifiable, Decodable {
    public let id: String
    public let hostname: String
    public let dnsName: String
    public let addresses: [String]
    public let isOnline: Bool
    public var name: String { hostname.isEmpty ? dnsName : hostname }

    public init(id: String, hostname: String, dnsName: String, addresses: [String], isOnline: Bool) {
        self.id = id; self.hostname = hostname; self.dnsName = dnsName
        self.addresses = addresses; self.isOnline = isOnline
    }

    enum CodingKeys: String, CodingKey {
        case id, hostname
        case dnsName = "dns_name"
        case addresses = "ips"
        case isOnline = "online"
    }
}

/// Safe classifications of native health warnings. Raw native messages can
/// include login capabilities or account data and never cross this boundary.
public enum TailscaleHealthIssue: String, Decodable, Sendable {
    case networkUnavailable = "network_unavailable"
    case dnsUnavailable = "dns_unavailable"
    case tlsFailure = "tls_failure"
    case controlUnreachable = "control_unreachable"
    case timeout
}

/// Auth URLs contain a temporary login capability. Default descriptions are
/// deliberately redacted so diagnostics cannot accidentally publish the URL.
public struct TailscaleNodeStatus: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let backendState: String
    public let authURL: URL?
    public let tailnetName: String
    public let userLogin: String
    public let accountIdentity: String?
    public let selfPeer: TailscalePeer?
    public let peers: [TailscalePeer]
    public let healthIssues: [TailscaleHealthIssue]
    public var isRunning: Bool { backendState == "Running" }

    public init(backendState: String, authURL: URL? = nil, tailnetName: String = "", userLogin: String = "",
                accountIdentity: String? = nil, selfPeer: TailscalePeer? = nil, peers: [TailscalePeer] = [],
                healthIssues: [TailscaleHealthIssue] = []) {
        self.backendState = backendState; self.authURL = authURL; self.tailnetName = tailnetName
        self.userLogin = userLogin; self.accountIdentity = accountIdentity
        self.selfPeer = selfPeer; self.peers = peers; self.healthIssues = healthIssues
    }

    public var description: String { "TailscaleNodeStatus(<redacted>)" }
    public var debugDescription: String { description }

    static func decode(_ data: Data) throws -> Self {
        let raw: StatusDocument
        do { raw = try JSONDecoder().decode(StatusDocument.self, from: data) }
        catch { throw TailscaleSSHTransportError.invalidNativeStatus }
        guard raw.schemaVersion == 1, !raw.backendState.isEmpty else {
            throw TailscaleSSHTransportError.invalidNativeStatus
        }
        let authURL: URL?
        if raw.authURL.isEmpty { authURL = nil }
        else {
            guard let candidate = URL(string: raw.authURL), isTrustedLoginURL(candidate) else {
                throw TailscaleSSHTransportError.invalidLoginURL
            }
            authURL = candidate
        }
        return Self(backendState: raw.backendState, authURL: authURL, tailnetName: raw.tailnetName,
                    userLogin: raw.userLogin, accountIdentity: raw.accountIdentity,
                    selfPeer: raw.selfPeer, peers: raw.peers,
                    healthIssues: (raw.healthIssues ?? []).compactMap(TailscaleHealthIssue.init(rawValue:)))
    }

    public static func isTrustedLoginURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host?.lowercased() == "login.tailscale.com"
            && parts.user == nil && parts.password == nil && parts.fragment == nil
            && (parts.port == nil || parts.port == 443)
    }
}

private struct StatusDocument: Decodable {
    let schemaVersion: Int
    let backendState: String
    let authURL: String
    let tailnetName: String
    let userLogin: String
    let accountIdentity: String?
    let selfPeer: TailscalePeer?
    let peers: [TailscalePeer]
    let healthIssues: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", backendState = "backend_state", authURL = "auth_url"
        case tailnetName = "tailnet_name", userLogin = "user_login", accountIdentity = "account_identity"
        case selfPeer = "self", peers, healthIssues = "health_issues"
    }
}

public enum TailscaleNativeOperation: String, Equatable, Sendable {
    case createNode, createToken, start, status, startLogin, logout, dial, read, write
}

/// Error text from Go is never exposed: it can contain host or account details.
public enum TailscaleSSHTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration, invalidHost, invalidPort, invalidTimeout, unsupportedABI
    case invalidNativeStatus, invalidLoginURL, authenticationRequired, approvalRequired
    case storageUnavailable, invalidStoredState, nodeAlreadyOpen
    case nativeFailure(operation: TailscaleNativeOperation, code: Int32)
    case bridgeFailure(code: Int32)
    case connectionClosed, backpressureExceeded

    public var isTimeout: Bool {
        if case .nativeFailure(_, 3) = self { return true }
        return false
    }

    public var isRetryable: Bool {
        switch self {
        case .invalidConfiguration, .invalidHost, .invalidPort, .invalidTimeout, .unsupportedABI,
             .invalidNativeStatus, .invalidLoginURL, .authenticationRequired, .approvalRequired,
             .storageUnavailable, .invalidStoredState, .nodeAlreadyOpen: return false
        case .nativeFailure(_, let code): return code != 1 && code != 4
        case .bridgeFailure, .connectionClosed, .backpressureExceeded: return true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The Tailscale configuration is invalid."
        case .invalidHost: return "Enter a Tailscale IP address or device name."
        case .invalidPort: return "Enter an SSH port from 1 to 65535."
        case .invalidTimeout: return "The Tailscale connection deadline is invalid."
        case .unsupportedABI: return "This Tailscale library version is not supported."
        case .invalidNativeStatus: return "The Tailscale connection returned an unsupported status."
        case .invalidLoginURL: return "Tailscale returned an untrusted login address."
        case .authenticationRequired: return "Sign in to Tailscale before connecting."
        case .approvalRequired: return "Approve this device in Tailscale before connecting."
        case .storageUnavailable: return "Secure Tailscale storage is unavailable. Unlock the device and try again."
        case .invalidStoredState: return "The saved Tailscale state could not be opened. Restore the account before connecting."
        case .nodeAlreadyOpen: return "Tailscale is still closing a previous connection. Try again shortly."
        case .nativeFailure(_, 3): return "Tailscale timed out. Check the network and remote device."
        case .nativeFailure(let operation, let code): return "Tailscale could not complete \(operation.rawValue) (code \(code))."
        case .bridgeFailure(let code): return "The Tailscale connection could not transfer data (code \(code))."
        case .connectionClosed: return "The Tailscale connection closed. Reconnect to continue."
        case .backpressureExceeded: return "The Tailscale connection is too slow to accept queued data. Reconnect to continue."
        }
    }
}
