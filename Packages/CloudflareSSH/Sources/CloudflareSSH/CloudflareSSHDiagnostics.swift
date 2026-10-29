import NIOConcurrencyHelpers
import NIOCore

/// Only bounded, typed metadata. Never contains endpoints, headers, peer close
/// text, identity, credentials, SSH content or a reflected underlying Error.
public struct CloudflareSSHDiagnosticEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case dialStarted, tcpConnected, tlsEstablished, webSocketUpgraded, activated
        case pingQueued, pingSent, pongReceived(matched: Bool)
        case peerClose(code: UInt16?)
        case failed(CloudflareSSHTransportError)
        case localCloseRequested, transportEOF, closed, cancelled
    }
    public let kind: Kind
    public let elapsedMilliseconds: UInt64
}

/// Fixed-size state survives Citadel consuming the original transport error.
/// `firstTermination` distinguishes the original cause from cleanup effects.
public struct CloudflareSSHDiagnosticSnapshot: Sendable, Equatable {
    public let lastEvent: CloudflareSSHDiagnosticEvent?
    public let firstTermination: CloudflareSSHDiagnosticEvent?
    public let firstFailure: CloudflareSSHTransportError?
    public let peerCloseCode: UInt16?
    public let elapsedMilliseconds: UInt64
    public let pingsSent: UInt64
    public let pongsReceived: UInt64
    public let matchingPongsReceived: UInt64
}

final class CloudflareSSHDiagnostics: @unchecked Sendable {
    private let lock = NIOLock()
    private let started = NIODeadline.now().uptimeNanoseconds
    private let observer: (@Sendable (CloudflareSSHDiagnosticEvent) -> Void)?
    private var lastEvent: CloudflareSSHDiagnosticEvent?
    private var firstTermination: CloudflareSSHDiagnosticEvent?
    private var firstFailure: CloudflareSSHTransportError?
    private var peerCloseCode: UInt16?
    private var sawPeerClose = false
    private var closedAt: UInt64?
    private var pingsSent: UInt64 = 0
    private var pongsReceived: UInt64 = 0
    private var matchingPongsReceived: UInt64 = 0

    init(observer: (@Sendable (CloudflareSSHDiagnosticEvent) -> Void)? = nil) {
        self.observer = observer
    }

    var snapshot: CloudflareSSHDiagnosticSnapshot {
        lock.withLock {
            CloudflareSSHDiagnosticSnapshot(lastEvent: lastEvent, firstTermination: firstTermination,
                firstFailure: firstFailure, peerCloseCode: peerCloseCode,
                elapsedMilliseconds: elapsed(at: closedAt ?? NIODeadline.now().uptimeNanoseconds),
                pingsSent: pingsSent, pongsReceived: pongsReceived, matchingPongsReceived: matchingPongsReceived)
        }
    }

    func record(_ kind: CloudflareSSHDiagnosticEvent.Kind) {
        let event: CloudflareSSHDiagnosticEvent? = lock.withLock {
            let now = NIODeadline.now().uptimeNanoseconds
            if case .closed = kind, closedAt != nil { return nil }
            let event = CloudflareSSHDiagnosticEvent(kind: kind, elapsedMilliseconds: elapsed(at: now))
            switch kind {
            case .pingSent: pingsSent &+= 1
            case .pongReceived(let matched):
                pongsReceived &+= 1
                if matched { matchingPongsReceived &+= 1 }
            case .failed(let error):
                if firstFailure == nil { firstFailure = error }
                if firstTermination == nil { firstTermination = event }
            case .peerClose(let code):
                if !sawPeerClose { sawPeerClose = true; peerCloseCode = code }
                if firstTermination == nil { firstTermination = event }
            case .cancelled, .localCloseRequested, .transportEOF:
                if firstTermination == nil { firstTermination = event }
            case .closed:
                closedAt = now
            default: break
            }
            lastEvent = event
            return event
        }
        // Call outside the lock so observers may safely inspect a snapshot.
        // Callers should keep callbacks nonblocking; delivery is on the I/O loop.
        if let event { observer?(event) }
    }

    func recordFailure(_ error: Error) {
        let safe = CloudflareSSHDialer.sanitizedError(error)
        if safe is CancellationError { record(.cancelled) }
        else if let failure = safe as? CloudflareSSHTransportError { record(.failed(failure)) }
    }

    private func elapsed(at now: UInt64) -> UInt64 {
        now >= started ? (now - started) / 1_000_000 : 0
    }
}
