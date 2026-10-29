import CloudflareAccess
import CloudflareSSH
import TailcatSSH
import TailscaleSSH
import Foundation

/// Preserve the decision separately from UI copy. Reconnect must never infer
/// whether to open a browser or retry a policy denial from translated strings.
struct ConnectionFailure: Equatable {
    enum Recovery: Equatable { case retry, login, userAction }
    let recovery: Recovery
    let message: String

    init(_ error: Error) {
        if let ssh = error as? SSHError, case .underlying(let underlying) = ssh {
            self = ConnectionFailure(underlying)
            return
        }
        if error is HostKeyRejected {
            message = "已拒绝 SSH 主机密钥，连接已停止。请核对指纹后手动重试。"
        } else {
            // Raw library errors can contain URLs and implementation details.
            // Known transport/auth errors provide safe messages through map().
            message = SSHError.map(error).description
        }
        if error is ConnectionTransportError || error is HostKeyRejected || error is TailcatCredentialError {
            recovery = .userAction
        } else if let account = error as? TailscaleAccountError {
            recovery = account.isRetryable ? .retry : .userAction
        } else if let transport = error as? TailscaleSSHTransportError {
            recovery = transport.isRetryable ? .retry : .userAction
        } else if let transport = error as? TailcatSSHTransportError {
            recovery = transport.isRetryable ? .retry : .userAction
        } else if let auth = error as? CloudflareAuthError {
            recovery = auth == .loginRequired ? .login : .userAction
        } else if let access = error as? AccessError {
            switch access {
            case .expiredToken: recovery = .login
            case .networkFailure, .deadlineExceeded: recovery = .retry
            case .httpStatus(let status): recovery = status >= 500 || status == 429 ? .retry : .userAction
            default: recovery = .userAction
            }
        } else if let transport = error as? CloudflareSSHTransportError {
            switch transport {
            case .tlsFailure(.connectionClosed): recovery = .retry
            case .httpStatus(let status):
                if [301, 302, 303, 307, 308, 401].contains(status) { recovery = .login }
                else { recovery = status >= 500 || status == 429 ? .retry : .userAction }
            case .invalidEndpoint, .invalidCredential, .unsupportedWebSocketOptions,
                 .invalidWebSocketFrame, .textFrameUnsupported, .tlsFailure:
                recovery = .userAction
            default: recovery = .retry
            }
        } else if let ssh = error as? SSHError {
            switch ssh {
            case .missingKeychainRef, .missingSecret, .unsupportedKeyType,
                 .authenticationFailed, .authMethodRejected, .credentialUnavailable:
                recovery = .userAction
            default: recovery = .retry
            }
        } else if error is CancellationError {
            recovery = .userAction
        } else {
            recovery = .retry
        }
    }
}

/// Shared by foreground/path/timer recovery; a path callback cannot bypass a
/// pending backoff. The owner schedules at most one retry, never the dialer.
struct CloudflareReconnectBackoff {
    private(set) var failures = 0
    private(set) var nextAttempt: Date?
    private var stableSince: Date?

    mutating func succeeded(now: Date = Date()) {
        stableSince = now
        nextAttempt = nil
    }

    mutating func failed(now: Date = Date(), jitter: Double = Double.random(in: 0.85...1.15)) -> TimeInterval {
        if let stableSince, now.timeIntervalSince(stableSince) >= 30 { failures = 0 }
        stableSince = nil
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let delay = min(30, delays[min(failures, delays.count - 1)] * max(0.5, min(1.5, jitter)))
        failures += 1
        nextAttempt = now.addingTimeInterval(delay)
        return delay
    }

    func permitsAttempt(now: Date = Date()) -> Bool { nextAttempt.map { now >= $0 } ?? true }
}
