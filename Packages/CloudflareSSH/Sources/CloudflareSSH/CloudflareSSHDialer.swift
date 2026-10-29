import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import NIOWebSocket

/// The caller owns the returned channel and must close it on SSH setup failure.
/// Install the SSH byte consumer first, then call `activate()` to release data
/// that arrived together with the HTTP upgrade response.
public struct CloudflareSSHConnection: Sendable {
    public let channel: any Channel
    private let stream: WebSocketByteStreamHandler

    public var diagnostics: CloudflareSSHDiagnosticSnapshot { stream.diagnosticState.snapshot }

    init(channel: any Channel, stream: WebSocketByteStreamHandler) {
        self.channel = channel
        self.stream = stream
    }

    public func activate() async throws {
        try Task.checkCancellation()
        try await channel.pipeline.context(handler: stream).flatMapThrowing { context in
            try self.stream.activate(context: context)
        }.get()
        try Task.checkCancellation()
    }

    public func close() async {
        try? await channel.close().get()
    }
}

/// Experimental compatibility with cloudflared 2026.10.3's Access carrier.
/// Does not log credentials, follow redirects, or perform browser login.
public struct CloudflareSSHDialer: Sendable {
    private let tlsContext: NIOSSLContext

    public init(trustRoots: NIOSSLTrustRoots = .default) throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = trustRoots
        tls.certificateVerification = .fullVerification
        tls.applicationProtocols = ["http/1.1"]
        self.tlsContext = try NIOSSLContext(configuration: tls)
    }

    public func connect(
        endpoint: URL,
        accessToken: String?,
        on group: any EventLoopGroup,
        timeout: TimeAmount = .seconds(15),
        onDiagnostic: (@Sendable (CloudflareSSHDiagnosticEvent) -> Void)? = nil
    ) async throws -> CloudflareSSHConnection {
        let destination = try Destination(endpoint)
        if let accessToken {
            // The token is an HTTP header value, never URL/argv/log data.
            guard !accessToken.isEmpty,
                  accessToken.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7f }) else {
                throw CloudflareSSHTransportError.invalidCredential
            }
        }
        guard timeout.nanoseconds > 0 else { throw CloudflareSSHTransportError.deadlineExceeded }
        try Task.checkCancellation()
        let eventLoop = group.next()
        let diagnostics = CloudflareSSHDiagnostics(observer: onDiagnostic)
        let attempt = DialAttempt(eventLoop: eventLoop, diagnostics: diagnostics)
        return try await withTaskCancellationHandler {
            eventLoop.execute {
                diagnostics.record(.dialStarted)
                attempt.startDeadline(timeout)
                let bootstrap = ClientBootstrap(group: eventLoop)
                    .connectTimeout(timeout)
                    .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .channelOption(ChannelOptions.writeBufferWaterMark,
                                   value: WriteBufferWaterMark(low: 256 * 1024, high: 1024 * 1024))
                    .channelInitializer { channel in
                        guard attempt.attachCandidate(channel) else {
                            return channel.eventLoop.makeFailedFuture(CancellationError())
                        }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                bootstrap.connect(host: destination.host, port: destination.port).whenComplete { result in
                    switch result {
                    case .success(let channel):
                        guard attempt.select(channel) else { return }
                        diagnostics.record(.tcpConnected)
                        do {
                            let ssl = try NIOSSLClientHandler(context: self.tlsContext, serverHostname: destination.host)
                            try channel.pipeline.syncOperations.addHandler(ssl)
                            try channel.pipeline.syncOperations.addHandler(TLSDiagnosticObserver(diagnostics: diagnostics))
                            let future = try Self.configureUpgrade(
                                on: channel, destination: destination, accessToken: accessToken, diagnostics: diagnostics
                            )
                            future.whenComplete { result in attempt.finish(result) }
                        } catch {
                            attempt.finish(.failure(error))
                        }
                    case .failure(let error):
                        attempt.finish(.failure(error))
                    }
                }
            }
            do {
                let result = try await attempt.promise.futureResult.get()
                try Task.checkCancellation()
                return result
            } catch {
                eventLoop.execute { attempt.cancel(error) }
                throw error
            }
        } onCancel: {
            eventLoop.execute { attempt.cancel(CancellationError()) }
        }
    }

    static func configureUpgrade(
        on channel: any Channel,
        destination: Destination,
        accessToken: String?,
        diagnostics: CloudflareSSHDiagnostics = CloudflareSSHDiagnostics()
    ) throws -> EventLoopFuture<CloudflareSSHConnection> {
        channel.eventLoop.assertInEventLoop()
        let stream = WebSocketByteStreamHandler(diagnostics: diagnostics)
        let bodyDiscarder = HandshakeBodyDiscarder()
        let upgrader = NIOTypedWebSocketClientUpgrader<CloudflareSSHConnection>(
            maxFrameSize: 1 << 20,
            // Our adapter sends correctly masked close replies and closes once.
            enableAutomaticErrorHandling: false
        ) { channel, response in
            guard response.headers["Sec-WebSocket-Extensions"].isEmpty,
                  response.headers["Sec-WebSocket-Protocol"].isEmpty else {
                return channel.eventLoop.makeFailedFuture(CloudflareSSHTransportError.unsupportedWebSocketOptions)
            }
            return channel.pipeline.removeHandler(bodyDiscarder).flatMap {
                channel.pipeline.addHandler(stream)
            }.map {
                diagnostics.record(.webSocketUpgraded)
                return CloudflareSSHConnection(channel: channel, stream: stream)
            }
        }
        var headers = HTTPHeaders([
            ("Host", destination.authority),
            ("User-Agent", "Moshpit-CloudflareSSH-P0/1")
        ])
        if let accessToken { headers.add(name: "Cf-Access-Token", value: accessToken) }
        let configuration = NIOTypedHTTPClientUpgradeConfiguration(
            upgradeRequestHead: HTTPRequestHead(version: .http1_1, method: .GET, uri: destination.path, headers: headers),
            upgraders: [upgrader],
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeFailedFuture(CloudflareSSHTransportError.httpStatus(101))
            }
        )
        let encoder = HTTPRequestEncoder()
        // The default typed NIO setup DROPS leftover bytes. Explicitly forward
        // a 101 response followed by the first WS frame in the same TCP read.
        let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
        let observer = UpgradeResponseObserver()
        let upgrade = NIOTypedHTTPClientUpgradeHandler(
            httpHandlers: [encoder, decoder, observer], upgradeConfiguration: configuration
        )
        try channel.pipeline.syncOperations.addHandlers(encoder, decoder, observer, upgrade, bodyDiscarder)
        upgrade.upgradeResultFuture.whenFailure { _ in channel.close(promise: nil) }
        return upgrade.upgradeResultFuture
    }

    struct Destination: Sendable {
        let host: String
        let port: Int
        let authority: String
        let path: String

        init(_ endpoint: URL) throws {
            guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "wss",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.fragment == nil,
                  (components.port == nil || (1...65535).contains(components.port!)),
                  host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
                throw CloudflareSSHTransportError.invalidEndpoint
            }
            self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            self.port = components.port ?? 443
            let formattedHost = self.host.contains(":") ? "[\(self.host)]" : self.host
            self.authority = port == 443 ? formattedHost : "\(formattedHost):\(port)"
            self.path = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
                + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
    }

    static func sanitizedError(_ error: Error) -> Error {
        if error is CloudflareSSHTransportError || error is CancellationError { return error }
        if let tls = error as? NIOSSLExtraError {
            if tls == .failedToValidateHostname { return CloudflareSSHTransportError.tlsFailure(.hostnameMismatch) }
            if tls == .invalidSNIHostname || tls == .cannotUseIPAddressInSNI || tls == .serverHostnameImpossibleToMatch {
                return CloudflareSSHTransportError.tlsFailure(.invalidServerName)
            }
            return CloudflareSSHTransportError.tlsFailure(.handshakeFailed)
        }
        if let tls = error as? NIOSSLError {
            switch tls {
            case .unableToValidateCertificate, .noCertificateToValidate:
                return CloudflareSSHTransportError.tlsFailure(.certificateRejected)
            case .uncleanShutdown:
                return CloudflareSSHTransportError.tlsFailure(.connectionClosed)
            case .handshakeFailed(.sslError(let stack))
                where stack.contains(.eofDuringHandshake)
                    || stack.contains(.eofDuringAdditionalCertficiateChainValidation):
                // NIOSSL reports a transport EOF during these phases as a
                // handshake failure. Preserve its transient nature without
                // treating certificate/protocol failures as retryable.
                return CloudflareSSHTransportError.tlsFailure(.connectionClosed)
            default:
                return CloudflareSSHTransportError.tlsFailure(.handshakeFailed)
            }
        }
        if let dns = error as? SocketAddressError.UnknownHost {
            return CloudflareSSHTransportError.dnsFailure(code: dns.errorCode)
        }
        if let connections = error as? NIOConnectionError {
            if let failure = connections.connectionErrors.first { return sanitizedError(failure.error) }
            if let dns = connections.dnsAError ?? connections.dnsAAAAError { return sanitizedError(dns) }
            return CloudflareSSHTransportError.socketFailure(code: nil)
        }
        if let socket = error as? IOError { return CloudflareSSHTransportError.socketFailure(code: socket.errnoCode) }
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout: return CloudflareSSHTransportError.deadlineExceeded
            case .alreadyClosed, .ioOnClosedChannel, .eof: return CloudflareSSHTransportError.connectionClosed
            default: return CloudflareSSHTransportError.socketFailure(code: nil)
            }
        }
        // Unknown protocol errors may embed response data in descriptions.
        // Preserve the failure stage without copying untrusted text into logs.
        return CloudflareSSHTransportError.upgradeFailed
    }
}

/// Observe TLS completion/errors before HTTP and SSH consumers can swallow
/// them. It forwards everything unchanged and never reads application bytes.
private final class TLSDiagnosticObserver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let diagnostics: CloudflareSSHDiagnostics
    init(diagnostics: CloudflareSSHDiagnostics) { self.diagnostics = diagnostics }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent { diagnostics.record(.tlsEstablished) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        diagnostics.recordFailure(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
        diagnostics.record(.closed)
    }
}

private final class UpgradeResponseObserver: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    private var rejected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        if case .head(let head) = unwrapInboundIn(data), head.status != .switchingProtocols {
            // Forward only the numeric status. Never expose HTML, Location, or
            // response headers (which may contain authentication material).
            rejected = true
            context.fireErrorCaught(CloudflareSSHTransportError.httpStatus(Int(head.status.code)))
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }
}

/// NIO's typed upgrade handler unbuffers HTTP parts even when its upgrade
/// initializer fails. Keep them isolated from any future SSH consumer. Only a
/// successful WebSocket upgrade removes this sink, before releasing its bytes.
private final class HandshakeBodyDiscarder: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

/// Confined to eventLoop, including task cancellation callbacks. Completion,
/// deadline, and channel cleanup may race but the promise completes only once.
private final class DialAttempt: @unchecked Sendable {
    let promise: EventLoopPromise<CloudflareSSHConnection>
    private let eventLoop: any EventLoop
    private var channel: (any Channel)?
    private var candidates: [ObjectIdentifier: any Channel] = [:]
    private var completed = false
    private var deadline: Scheduled<Void>?
    private let diagnostics: CloudflareSSHDiagnostics

    init(eventLoop: any EventLoop, diagnostics: CloudflareSSHDiagnostics) {
        self.eventLoop = eventLoop
        self.promise = eventLoop.makePromise()
        self.diagnostics = diagnostics
    }

    func startDeadline(_ timeout: TimeAmount) {
        guard !completed else { return }
        deadline = eventLoop.scheduleTask(in: timeout) {
            self.cancel(CloudflareSSHTransportError.deadlineExceeded)
        }
    }

    func attachCandidate(_ channel: any Channel) -> Bool {
        guard !completed else { channel.close(promise: nil); return false }
        let identifier = ObjectIdentifier(channel)
        candidates[identifier] = channel
        channel.closeFuture.whenComplete { _ in
            self.candidates.removeValue(forKey: identifier)
            if let selected = self.channel, selected === channel {
                self.finish(.failure(CloudflareSSHTransportError.connectionClosed))
            }
        }
        return true
    }

    func select(_ channel: any Channel) -> Bool {
        guard !completed else { channel.close(promise: nil); return false }
        self.channel = channel
        return true
    }

    func finish(_ result: Result<CloudflareSSHConnection, Error>) {
        guard !completed else { return }
        completed = true
        deadline?.cancel()
        deadline = nil
        if case .failure(let error) = result {
            diagnostics.recordFailure(error)
        }
        promise.completeWith(result.mapError(CloudflareSSHDialer.sanitizedError))
        if case .failure = result { closeCandidates() }
    }

    func cancel(_ error: Error) {
        if error is CancellationError { diagnostics.record(.cancelled) }
        finish(.failure(error))
        closeCandidates()
    }

    private func closeCandidates() {
        let pending = Array(candidates.values)
        for candidate in pending { candidate.close(promise: nil) }
        channel?.close(promise: nil)
    }
}
