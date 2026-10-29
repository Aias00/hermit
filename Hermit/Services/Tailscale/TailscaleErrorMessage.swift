import Foundation
import TailscaleSSH

extension TailscaleSSHTransportError {
    var moshpitMessage: String {
        switch self {
        case .authenticationRequired: return TailscaleAccountError.loginRequired.localizedDescription
        case .approvalRequired: return TailscaleAccountError.approvalRequired.localizedDescription
        case .storageUnavailable: return TailscaleAccountError.storageUnavailable.localizedDescription
        case .invalidStoredState: return TailscaleAccountError.invalidStoredState.localizedDescription
        case .invalidHost: return TailscaleAccountError.peerUnavailable.localizedDescription
        case .invalidPort, .invalidConfiguration:
            return String(localized: "Check the Tailscale device address and SSH port in this connection.")
        case .invalidLoginURL:
            return String(localized: "Tailscale returned an unexpected login address. Login was stopped.")
        case .unsupportedABI, .invalidNativeStatus, .invalidTimeout:
            return String(localized: "The Tailscale component could not start. Update Hermit and try again.")
        case .nodeAlreadyOpen:
            return String(localized: "Tailscale is still closing its previous connection. Please try again shortly.")
        case .nativeFailure(_, 3):
            return String(localized: "Tailscale timed out. Check the network, device status, and access permissions.")
        case .nativeFailure(.dial, 1):
            return TailscaleAccountError.peerUnavailable.localizedDescription
        case .connectionClosed:
            return String(localized: "The Tailscale connection closed. Reconnect to continue.")
        case .backpressureExceeded:
            return String(localized: "The Tailscale connection is too slow to accept queued data. Reconnect to continue.")
        case .nativeFailure, .bridgeFailure:
            return String(localized: "Tailscale could not connect. Check your network and try again.")
        }
    }
}
