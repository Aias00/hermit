import Foundation
@_spi(EmbeddedTransport) import TailcatSSH

/// One application-owned tailnet node shared by all SSH/control/push streams.
/// Creating this object only validates encrypted local state; network startup
/// and interactive enrollment are explicit operations.
public final class TailscaleNode: @unchecked Sendable {
    let resource: TailscaleNodeResource

    public convenience init(configuration: TailscaleNodeConfiguration) async throws {
        try await self.init(configuration: configuration, api: LiveTailscaleNativeAPI())
    }

    init(configuration: TailscaleNodeConfiguration, api: any TailscaleNativeAPI) async throws {
        let handle = try await TailscaleNativeAttempt.perform(timeout: 10_000_000_000,
                                                              discard: { api.closeNode($0) }) { _ in
            try api.makeNode(configuration)
        }
        self.resource = TailscaleNodeResource(node: handle, api: api)
    }

    public func start() async throws {
        let resource = resource, handle = try resource.handle()
        try await TailscaleNativeAttempt.perform(timeout: 15_000_000_000) { try resource.api.start(node: handle, token: $0) }
    }

    public func status() async throws -> TailscaleNodeStatus {
        let resource = resource, handle = try resource.handle()
        return try await TailscaleNativeAttempt.perform(timeout: 10_000_000_000) { try resource.api.status(node: handle, token: $0) }
    }

    /// Call only in response to an explicit user action. Enrollment is observed
    /// by polling status; an authURL may arrive after this method returns.
    @discardableResult public func startLogin() async throws -> TailscaleNodeStatus {
        let resource = resource, handle = try resource.handle()
        try await TailscaleNativeAttempt.perform(timeout: 15_000_000_000) { try resource.api.startLogin(node: handle, token: $0) }
        return try await status()
    }

    /// Reports failed remote logout to the caller. The app controls whether to
    /// retain/retry or explicitly remove encrypted local account state.
    public func logout() async throws {
        if resource.isClosed { return }
        let resource = resource, handle = try resource.handle()
        try await TailscaleNativeAttempt.perform(timeout: 15_000_000_000) { try resource.api.logout(node: handle, token: $0) }
    }

    /// Idempotent and waits for native destruction, including sibling streams.
    /// A closed node cannot be restarted; create a new node with the same state.
    public func close() async { await resource.close() }

    func dial(host: String, port: UInt16, timeout: Int64) async throws -> any BlockingByteStream {
        let handle = try resource.handle(), api = resource.api
        let resource = resource
        return try await TailscaleNativeAttempt.perform(timeout: timeout, discard: { $0.cancel(); $0.close() }) { token in
            let stream = try api.dial(node: handle, token: token, host: host, port: port)
            return NodeBoundByteStream(node: resource, stream: stream) as any BlockingByteStream
        }
    }
}
