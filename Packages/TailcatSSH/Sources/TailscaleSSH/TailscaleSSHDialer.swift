import Darwin
import Foundation
import NIOCore
@_spi(EmbeddedTransport) import TailcatSSH

public struct TailscaleSSHDiagnosticEvent: Sendable {
    public enum Kind: String, Sendable { case dialStarted, tunnelConnected, streamActivated, connectionClosed }
    public let kind: Kind
    public let elapsedMilliseconds: UInt64
}

/// One TCP stream on a shared account node. Installing SSH handlers before
/// activation keeps early server banners inside the bridge's bounded buffers.
public struct TailscaleSSHConnection: Sendable {
    public let channel: any Channel
    private let underlying: TailcatSSHConnection
    private let diagnostics: TailscaleDiagnostics

    init(underlying: TailcatSSHConnection, diagnostics: TailscaleDiagnostics) {
        self.underlying = underlying; self.channel = underlying.channel; self.diagnostics = diagnostics
    }

    public func activate() async throws {
        do { try await underlying.activate() }
        catch { throw TailscaleSSHDialer.mapBridgeError(error) }
    }

    public func close() async { await underlying.close() }
}

public struct TailscaleSSHDialer: Sendable {
    public init() {}

    public func connect(node: TailscaleNode, host: String, port: Int,
                        on group: any EventLoopGroup, timeout: TimeAmount = .seconds(20),
                        onDiagnostic: (@Sendable (TailscaleSSHDiagnosticEvent) -> Void)? = nil) async throws -> TailscaleSSHConnection {
        let host = try Self.normalizedHost(host)
        guard (1...65535).contains(port) else { throw TailscaleSSHTransportError.invalidPort }
        guard timeout.nanoseconds > 0 else { throw TailscaleSSHTransportError.invalidTimeout }
        try Task.checkCancellation()
        let diagnostics = TailscaleDiagnostics(onDiagnostic)
        diagnostics.record(.dialStarted)
        let stream = try await node.dial(host: host, port: UInt16(port), timeout: timeout.nanoseconds)
        diagnostics.record(.tunnelConnected)
        return try await Self.adapt(stream: stream, on: group, diagnostics: diagnostics)
    }

    static func adapt(stream: any BlockingByteStream, on group: any EventLoopGroup,
                      diagnostics: TailscaleDiagnostics = TailscaleDiagnostics(nil)) async throws -> TailscaleSSHConnection {
        do {
            let underlying = try await TailcatSSHDialer.adaptByteStream(stream, on: group) { event in
                if event.kind == .streamActivated { diagnostics.record(.streamActivated) }
                if event.kind == .connectionClosed { diagnostics.record(.connectionClosed) }
            }
            do {
                try await underlying.channel.pipeline.addHandler(TailscaleErrorMappingHandler()).get()
                try Task.checkCancellation()
                return TailscaleSSHConnection(underlying: underlying, diagnostics: diagnostics)
            } catch { await underlying.close(); throw error }
        } catch { throw mapBridgeError(error) }
    }

    public static func normalizedHost(_ input: String) throws -> String {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw TailscaleSSHTransportError.invalidHost
        }
        let address = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return address.lowercased() }
        let dns = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard dns.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { throw TailscaleSSHTransportError.invalidHost }
        return dns.lowercased()
    }

    static func mapBridgeError(_ error: Error) -> Error {
        guard let error = error as? TailcatSSHTransportError else { return error }
        switch error {
        case .bridgeFailure(let code): return TailscaleSSHTransportError.bridgeFailure(code: code)
        case .connectionClosed: return TailscaleSSHTransportError.connectionClosed
        case .backpressureExceeded: return TailscaleSSHTransportError.backpressureExceeded
        default: return TailscaleSSHTransportError.invalidNativeStatus
        }
    }
}

final class TailscaleDiagnostics: @unchecked Sendable {
    private let started = DispatchTime.now().uptimeNanoseconds
    private let observer: (@Sendable (TailscaleSSHDiagnosticEvent) -> Void)?
    init(_ observer: (@Sendable (TailscaleSSHDiagnosticEvent) -> Void)?) { self.observer = observer }
    func record(_ kind: TailscaleSSHDiagnosticEvent.Kind) {
        observer?(.init(kind: kind, elapsedMilliseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
    }
}

private final class TailscaleErrorMappingHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(TailscaleSSHDialer.mapBridgeError(error))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let promise else { context.write(data, promise: nil); return }
        let completion = context.eventLoop.makePromise(of: Void.self)
        completion.futureResult.whenComplete {
            switch $0 {
            case .success: promise.succeed(())
            case .failure(let error): promise.fail(TailscaleSSHDialer.mapBridgeError(error))
            }
        }
        context.write(data, promise: completion)
    }
}
