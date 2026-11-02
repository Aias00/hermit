import Foundation

public enum RelayError: Error, Equatable, Sendable, LocalizedError {
  case invalidEndpoint, invalidInvitation, invitationExpired, invalidCredential, invalidName
  case httpStatus(Int)
  case networkFailure, timedOut, closed, protocolViolation, operationInProgress, writeClosed

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Relay requires an HTTPS origin without a path, credentials, query or fragment."
    case .invalidInvitation: "The pairing invitation is invalid."
    case .invitationExpired: "The pairing invitation has expired."
    case .invalidCredential: "The client credential is invalid or expired."
    case .invalidName: "The client name is invalid."
    case .httpStatus(let status): "Relay rejected the request (HTTP \(status))."
    case .networkFailure: "The relay connection failed."
    case .timedOut: "The relay operation timed out."
    case .closed: "The relay stream is closed."
    case .protocolViolation: "The relay sent an invalid data frame."
    case .operationInProgress: "Use one reader and one writer per relay stream."
    case .writeClosed: "The relay stream's write direction is closed."
    }
  }
}

/// Plaintext is available only for explicit literal-loopback integration tests.
public struct RelayEndpoint: Sendable, Equatable {
  public let url: URL

  public init(_ url: URL, allowInsecureLoopback: Bool = false) throws {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = c.host, !host.isEmpty,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      c.path.isEmpty || c.path == "/",
      c.port == nil || (1...65535).contains(c.port!),
      host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f })
    else { throw RelayError.invalidEndpoint }
    let scheme = c.scheme?.lowercased()
    guard scheme == "https" || (scheme == "http" && allowInsecureLoopback && Self.isLoopback(host))
    else {
      throw RelayError.invalidEndpoint
    }
    c.scheme = scheme
    c.path = ""
    guard let origin = c.url else { throw RelayError.invalidEndpoint }
    self.url = origin
  }

  func resource(_ path: String, webSocket: Bool = false) -> URL {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    c.path = path
    if webSocket { c.scheme = c.scheme == "https" ? "wss" : "ws" }
    return c.url!
  }

  private static func isLoopback(_ host: String) -> Bool {
    if host == "::1" || host == "[::1]" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts[0] == "127"
      && parts.allSatisfy {
        !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && UInt8($0) != nil
          && ($0.count == 1 || !$0.hasPrefix("0"))
      }
  }
}

func validID(_ value: String) -> Bool {
  let b = Array(value.utf8)
  func alphanumeric(_ c: UInt8) -> Bool { (97...122).contains(c) || (48...57).contains(c) }
  return (1...64).contains(b.count) && alphanumeric(b[0])
    && b.allSatisfy { alphanumeric($0) || $0 == 45 }
}
func validHex(_ value: String, count: Int) -> Bool {
  value.utf8.count == count
    && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func relayDate(_ value: String) -> Date? {
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = parser.date(from: value) { return date }
  parser.formatOptions = [.withInternetDateTime]
  return parser.date(from: value)
}

/// Contains a secret. Descriptions and reflection deliberately omit the URI/code.
public struct RelayInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let endpoint: RelayEndpoint
  public let device: String
  public let service: String
  public let expiresAt: Date
  let code: String
  public var description: String { "RelayInvitation(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }

  public init(uri: String, allowInsecureLoopback: Bool = false) throws {
    guard uri.utf8.count <= 8192,
      let c = URLComponents(string: uri), c.scheme == "remoteforge-relay", c.host == "pair",
      c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty,
      let items = c.queryItems, items.count == 4,
      Set(items.map(\.name)) == Set(["server", "device", "service", "expires"]),
      let fragment = c.percentEncodedFragment,
      let secrets = URLComponents(string: "https://local/?" + fragment)?.queryItems,
      secrets.count == 1, secrets[0].name == "code", let code = secrets[0].value,
      validHex(code, count: 64)
    else { throw RelayError.invalidInvitation }
    let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    guard let origin = URL(string: fields["server"]!),
      validID(fields["device"]!), validID(fields["service"]!),
      let expires = relayDate(fields["expires"]!)
    else { throw RelayError.invalidInvitation }
    self.endpoint = try RelayEndpoint(origin, allowInsecureLoopback: allowInsecureLoopback)
    self.device = fields["device"]!
    self.service = fields["service"]!
    self.expiresAt = expires
    self.code = code
    guard expires > Date() else { throw RelayError.invitationExpired }
  }

  public init(json: Data, allowInsecureLoopback: Bool = false) throws {
    struct Envelope: Decodable {
      let uri: String
      let expires_at: String
    }
    guard json.count <= 16384, let v = try? JSONDecoder().decode(Envelope.self, from: json),
      let expires = relayDate(v.expires_at)
    else { throw RelayError.invalidInvitation }
    try self.init(uri: v.uri, allowInsecureLoopback: allowInsecureLoopback)
    guard abs(expires.timeIntervalSince(expiresAt)) < 0.001 else {
      throw RelayError.invalidInvitation
    }
  }
}

/// Persist serialized credentials in the app's Keychain, not UserDefaults or logs.
public struct RelayCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let endpoint: RelayEndpoint
  public let device: String
  public let service: String
  public let clientID: String
  public let expiresAt: Date
  let token: String
  public var description: String { "RelayCredential(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }

  init(
    endpoint: RelayEndpoint, device: String, service: String, clientID: String, expiresAt: Date,
    token: String
  ) throws {
    guard validID(device), validID(service), validHex(clientID, count: 24),
      token.hasPrefix(clientID + "."), validHex(String(token.dropFirst(25)), count: 64),
      expiresAt > Date()
    else { throw RelayError.invalidCredential }
    self.endpoint = endpoint
    self.device = device
    self.service = service
    self.clientID = clientID
    self.expiresAt = expiresAt
    self.token = token
  }

  private struct Stored: Codable {
    let server: URL
    let device: String
    let service: String
    let client_id: String
    let expires_at: Date
    let token: String
  }
  /// Returns secret bytes explicitly, for storage in a credential vault.
  public func serialized() throws -> Data {
    try JSONEncoder().encode(
      Stored(
        server: endpoint.url, device: device, service: service,
        client_id: clientID, expires_at: expiresAt, token: token))
  }
  public init(serialized: Data, allowInsecureLoopback: Bool = false) throws {
    guard serialized.count <= 16384,
      let v = try? JSONDecoder().decode(Stored.self, from: serialized)
    else { throw RelayError.invalidCredential }
    try self.init(
      endpoint: RelayEndpoint(v.server, allowInsecureLoopback: allowInsecureLoopback),
      device: v.device, service: v.service, clientID: v.client_id, expiresAt: v.expires_at,
      token: v.token)
  }
}
