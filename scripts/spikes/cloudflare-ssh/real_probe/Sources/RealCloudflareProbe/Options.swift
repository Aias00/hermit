import Foundation

struct Options {
    let hostname: String
    let teamDomain: String
    let audience: String?
    let saveCredentials: String?
    let reuseCredentials: String?
    let loginOnly: Bool
    let anonymousTransport: Bool
    let loginTimeout: Int

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var loginOnly = false
        var anonymousTransport = false
        var index = 0
        let valued: Set<String> = ["--hostname", "--team", "--aud", "--save-credentials", "--reuse-credentials", "--login-timeout-seconds"]
        while index < arguments.count {
            let option = arguments[index]
            if option == "--login-only", !loginOnly { loginOnly = true; index += 1; continue }
            if option == "--anonymous-transport", !anonymousTransport { anonymousTransport = true; index += 1; continue }
            guard valued.contains(option), values[option] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw ProbeError.invalidArguments }
            values[option] = arguments[index + 1]
            index += 2
        }
        guard let hostname = values["--hostname"], let team = values["--team"],
              let timeout = Int(values["--login-timeout-seconds"] ?? "300"), (1...600).contains(timeout),
              !(values["--save-credentials"] != nil && values["--reuse-credentials"] != nil)
        else { throw ProbeError.invalidArguments }
        if anonymousTransport {
            guard values["--aud"]?.isEmpty == false, !loginOnly,
                  values["--save-credentials"] == nil, values["--reuse-credentials"] == nil,
                  values["--login-timeout-seconds"] == nil else { throw ProbeError.invalidArguments }
        }
        self.hostname = hostname
        self.teamDomain = team
        self.audience = values["--aud"]
        self.saveCredentials = values["--save-credentials"]
        self.reuseCredentials = values["--reuse-credentials"]
        self.loginOnly = loginOnly
        self.anonymousTransport = anonymousTransport
        self.loginTimeout = timeout
    }

    static let usage = """
    cloudflare-real-probe --hostname SSH_HOSTNAME --team TEAM.cloudflareaccess.com [--aud AUD]
      [--save-credentials NEW_PRIVATE_FILE | --reuse-credentials PRIVATE_FILE]
      [--login-only] [--login-timeout-seconds 300]
    cloudflare-real-probe --anonymous-transport --hostname SSH_HOSTNAME --team TEAM.cloudflareaccess.com --aud AUD

    --anonymous-transport makes one anonymous WSS upgrade attempt (15 seconds),
    using system TLS trust. No discovery, browser login, credentials, or SSH bytes.
    It requires --aud and rejects all login/file flags. Only typed phases and
    numeric HTTP responses are printed; an unexpected 101 is immediately closed.

    Uses the pinned cloudflared encrypted browser-to-client transfer protocol.
    No browser opens automatically. The tool writes a temporary mode-0600 HTML
    login page and prints only its local path; open that page yourself while
    this process remains running. It is deleted when this attempt ends.

    Without --aud, discovery verifies signed application metadata using the
    explicitly configured team's HTTPS signing keys. No team is inferred.

    Tokens stay in memory unless --save-credentials explicitly creates a new
    mode-0600 file. --reuse-credentials revalidates its signature and scope.
    No token, Cookie, subject, email, or login capability is printed.

    Default: log in, connect via WSS with system TLS trust, verify SSH banner.
    --login-only skips WSS. Neither mode proves SSH host-key authentication,
    exec, PTY, or complete G1/G2 acceptance. No service token is supported.
    """
}

enum ProbeError: Error, LocalizedError {
    case invalidArguments
    case privateFile
    case bannerTimedOut
    case invalidBanner
    case connectionClosed
    case unexpectedAnonymousUpgrade

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Invalid arguments. Run with --help; arguments were not echoed."
        case .privateFile: return "Private-file operation failed; existing files, symlinks, or unsafe permissions are rejected."
        case .bannerTimedOut: return "WSS connected, but no valid SSH banner arrived before the deadline."
        case .invalidBanner: return "The WSS stream did not contain a supported, bounded SSH identification."
        case .connectionClosed: return "The stream closed before the SSH banner was verified."
        case .unexpectedAnonymousUpgrade: return "The anonymous request unexpectedly upgraded; it was closed without sending SSH data."
        }
    }
}
