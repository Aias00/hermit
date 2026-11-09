import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import Moshpit

@Suite("LAN and Tailscale route selection")
struct SSHRouteSelectionTests {
    private func server() -> ServerConnection {
        var value = ServerConnection(host: "mini.tailnet.ts.net", username: "user", transportRaw: "tailscale",
                                     tailscaleAccountID: UUID().uuidString, tailscalePeerID: "node-mini")
        value.preferLocalNetwork = true
        value.localEndpoints = [.init(host: "192.168.1.10"), .init(host: "10.0.0.10", port: 2222)]
        value.multiplexer = .herdr
        value.keychainRef = "shared-secret-reference"
        return value
    }

    @Test("A reachable first LAN address avoids Tailscale startup and preserves logical server identity")
    func reachableLAN() async throws {
        let original = server()
        var attempted: [ServerConnection] = []
        let selected = try await SSHRouteSelection.connect(original) { candidate, local in
            attempted.append(candidate)
            #expect(local)
            return candidate
        }
        #expect(attempted.count == 1)
        #expect(selected.host == "192.168.1.10")
        #expect(selected.transport == .direct)
        #expect(selected.id == original.id)
        #expect(selected.keychainRef == original.keychainRef)
        #expect(selected.multiplexer == .herdr)
        #expect(original.host == "mini.tailnet.ts.net")
        #expect(original.transport == .tailscale)
    }

    @Test("An unavailable LAN address advances in order, then falls back to the configured Tailscale peer")
    func fallback() async throws {
        let original = server()
        var attempted: [String] = []
        let selected = try await SSHRouteSelection.connect(original) { candidate, local in
            attempted.append(candidate.host)
            if local { throw LocalSSHRouteUnavailable() }
            #expect(candidate.tailscaleAccountID == original.tailscaleAccountID)
            #expect(candidate.tailscalePeerID == original.tailscalePeerID)
            return candidate
        }
        #expect(attempted == ["192.168.1.10", "10.0.0.10", original.host])
        #expect(selected == original)
    }

    @Test("A reachable second LAN address uses its configured port without trying Tailscale")
    func secondLAN() async throws {
        var attempts = 0
        let selected = try await SSHRouteSelection.connect(server()) { candidate, _ in
            attempts += 1
            if attempts == 1 { throw LocalSSHRouteUnavailable() }
            return candidate
        }
        #expect(attempts == 2)
        #expect(selected.port == 2222)
    }

    @Test("Authentication, trust, cancellation and post-TCP failures never try another address")
    func failClosed() async throws {
        let failures: [Error] = [SSHError.authenticationFailed, SSHError.authMethodRejected,
                                 HostKeyRejected(), CancellationError(), SSHError.handshakeFailed,
                                 SSHError.credentialUnavailable, SSHError.connectionFailed]
        for failure in failures {
            var attempts = 0
            do {
                let _: Bool = try await SSHRouteSelection.connect(server()) { _, _ in
                    attempts += 1
                    throw failure
                }
                Issue.record("expected failure")
            } catch { #expect(attempts == 1) }
        }
    }

    @Test("Tailscale's actual final error is retained when all LAN addresses are unavailable")
    func finalFailure() async throws {
        do {
            let _: Bool = try await SSHRouteSelection.connect(server()) { _, local in
                if local { throw LocalSSHRouteUnavailable() }
                throw TailscaleAccountError.accountMismatch
            }
            Issue.record("expected account mismatch")
        } catch { #expect(error as? TailscaleAccountError == .accountMismatch) }
    }

    @Test("Cancelling selection before it starts performs no dial")
    func cancelledSelection() async throws {
        let connection = server()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SSHRouteSelection.connect(connection) { _, _ in
                Issue.record("cancelled selection dialed")
                return false
            }
        }
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test("All endpoint variants validate against the existing Tailscale SSH fingerprint")
    func sameServerTrust() async throws {
        let connection = server()
        let identity = try #require(try connection.automaticRouteTrustIdentity())
        let validator = HostKeyValidator.inMemory()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let key = try NIOSSHPublicKey(openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDgQhgqywG4eG3cXK2gEELsrEXf5Q4v4JzrxSrrRVcFg")
        let differentKey = try NIOSSHPublicKey(openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMFa+0q0K1zmVeI1zHCP+qXugextFVAzuNqxA0jtU957")
        await validator.trust(host: identity, port: connection.port, fingerprint: HostKeyValidator.fingerprint(of: key))
        for candidate in try connection.routeCandidates() {
            let delegate = TOFUHostKeyDelegate(validator: validator, host: identity, port: connection.port,
                onNewHost: { _, _, _ in Issue.record("known server unexpectedly unknown"); return false },
                onChangedHost: { _, _, _, _ in false })
            let promise: EventLoopPromise<Void> = group.next().makePromise()
            delegate.validateHostKey(hostKey: key, validationCompletePromise: promise)
            try await promise.futureResult.get()
            #expect(candidate.id == connection.id)
            let rejected: EventLoopPromise<Void> = group.next().makePromise()
            delegate.validateHostKey(hostKey: differentKey, validationCompletePromise: rejected)
            do { try await rejected.futureResult.get(); Issue.record("different server trusted") }
            catch { #expect(error is HostKeyRejected) }
        }
        try await group.shutdownGracefully()
    }

    @Test("Routing metadata persists without duplicating credentials and legacy connections still decode")
    func persistence() throws {
        let original = server()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ServerConnection.self, from: data) == original)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "preferLocalNetwork")
        legacy.removeValue(forKey: "localEndpoints")
        let decoded = try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(try decoded.routeCandidates() == [decoded])
        #expect(decoded.preferLocalNetwork == nil)
    }

    @Test("Editing and saving endpoints preserves account, credentials and local port values")
    func formRoundTrip() throws {
        let original = server()
        var form = ConnectionTransportForm(connection: original)
        #expect(form.preferLocalNetwork)
        form.localEndpoints[0].host = " 192.168.2.10 "
        form.localEndpoints[0].port = 2223
        let saved = try form.validatedConnection(from: original, host: original.host, port: "22", usesMosh: false)
        #expect(saved.localEndpoints?.first?.host == "192.168.2.10")
        #expect(saved.localEndpoints?.first?.port == 2223)
        #expect(saved.tailscaleAccountID == original.tailscaleAccountID)
        #expect(saved.tailscalePeerID == original.tailscalePeerID)
        #expect(saved.keychainRef == original.keychainRef)
        #expect(saved.id == original.id)
        #expect(HostListPresentation.routeLabel(for: saved).contains("自动"))
        #expect(HostListPresentation.filtered([saved], query: "192.168.2.10") == [saved])
        form.preferLocalNetwork = false
        let disabled = try form.validatedConnection(from: saved, host: saved.host, port: "22", usesMosh: false)
        #expect(try disabled.routeCandidates() == [disabled])
        #expect(disabled.localEndpoints?.count == 2)
        #expect(HostListPresentation.filtered([disabled], query: "192.168.2.10").isEmpty)
    }

    @Test("Switching to a different transport disables automatic local attempts")
    func changingTransport() throws {
        let original = server()
        var form = ConnectionTransportForm(connection: original)
        form.selection = .direct
        let saved = try form.validatedConnection(from: original, host: "other.internal", port: "22", usesMosh: false)
        #expect(saved.preferLocalNetwork == false)
        #expect(try saved.routeCandidates() == [saved])
        #expect(try saved.automaticRouteTrustIdentity() == nil)
    }

    @Test("Automatic LAN routing rejects public, loopback, link-local and malformed endpoints",
          arguments: ["8.8.8.8", "100.80.1.2", "127.0.0.1", "169.254.1.2", "ssh://192.168.1.2",
                      "192.168.1.2:22", "192.168.1.2 bad", "localhost", "fe80::1", "2001:db8::1", ""])
    func invalidLocalAddress(host: String) {
        #expect(!SSHLocalEndpoint(host: host).isValid)
    }

    @Test("Private IPv4 and unique-local IPv6 addresses are supported",
          arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1", "fd12:3456::1"])
    func validLocalAddress(host: String) {
        #expect(SSHLocalEndpoint(host: host).isValid)
    }

    @Test("Invalid multi-route configuration fails before any endpoint is attempted")
    func invalidConfiguration() async throws {
        var invalid: [ServerConnection] = []
        var value = server(); value.localEndpoints = []; invalid.append(value)
        value = server(); value.localEndpoints = Array(repeating: .init(host: "10.0.0.1"), count: 5); invalid.append(value)
        value = server(); value.localEndpoints = [.init(host: "10.0.0.1", port: 0)]; invalid.append(value)
        value = server(); value.localEndpoints = [.init(host: "10.0.0.1"), .init(host: "10.0.0.1")]; invalid.append(value)
        value = server(); value.selectTransport(.direct); invalid.append(value)
        value = server(); value.connectionProtocol = .mosh; invalid.append(value)
        for connection in invalid {
            do {
                let _: Bool = try await SSHRouteSelection.connect(connection) { _, _ in
                    Issue.record("invalid configuration attempted a dial"); return false
                }
                Issue.record("expected validation failure")
            } catch { #expect(error is ConnectionTransportError) }
        }
    }
}
