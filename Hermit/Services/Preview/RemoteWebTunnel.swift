import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// An address on the SSH HOST, never on the phone. Only HTTP loopback
/// services are supported; HTTPS is not silently downgraded or trusted.
struct RemoteWebAddress: Equatable, Sendable {
    let url: URL
    var port: Int { url.port ?? 80 }
    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0", "::", "[::]"].contains(url.host?.lowercased() ?? "")
    }
    init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: text.contains("://") ? text : "http://" + text),
              url.scheme?.lowercased() == "http", Self.isLoopback(url),
              url.user == nil, url.password == nil,
              (1...65535).contains(url.port ?? 80) else { throw RemoteWebPreviewError.invalidAddress }
        self.url = url
    }
    func localURL(port: Int) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = port
        return parts.url!
    }
}

enum RemoteWebPreviewError: LocalizedError {
    case invalidAddress, unavailable, tooManyConnections
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入远端 HTTP 本地服务地址，例如 localhost:3000。暂不支持 HTTPS 或其他主机。"
        case .unavailable: "SSH 连接不可用，请重新连接主机后重试。"
        case .tooManyConnections: "预览连接数已达上限，请刷新后重试。"
        }
    }
}

/// One short-lived loopback listener. Raw streaming preserves assets, SSE and
/// WebSocket upgrades. Each direction allows one bounded read in flight and
/// resumes only after its peer has flushed; no full HTTP body is buffered.
final class RemoteWebTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var listener: Channel?
    private var clients: [ObjectIdentifier: (Channel, SSHChildChannelScope)] = [:]
    private let client: SSHClient
    let remotePort: Int
    private(set) var localPort = 0

    private init(client: SSHClient, port: Int) { self.client = client; self.remotePort = port }
    static func start(client: SSHClient, port: Int) async throws -> RemoteWebTunnel {
        let tunnel = RemoteWebTunnel(client: client, port: port)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let listener = try await ServerBootstrap(group: client.eventLoop)
                    .serverChannelOption(ChannelOptions.backlog, value: 16)
                    .childChannelOption(ChannelOptions.autoRead, value: false)
                    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                    .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
                    .childChannelInitializer { [weak tunnel] local in
                        guard let tunnel else { return local.eventLoop.makeFailedFuture(CancellationError()) }
                        return tunnel.accept(local)
                    }
                    .bind(host: "127.0.0.1", port: 0).get()
                let cancelled = tunnel.lock.withLock {
                    if tunnel.stopped { return true }
                    tunnel.listener = listener; tunnel.localPort = listener.localAddress?.port ?? 0
                    return false
                }
                if cancelled { try? await listener.close().get(); throw CancellationError() }
                try Task.checkCancellation()
                return tunnel
            } catch { tunnel.stop(); throw error }
        } onCancel: { tunnel.stop() }
    }
    private func accept(_ local: Channel) -> EventLoopFuture<Void> {
        let scope = SSHChildChannelScope(), id = ObjectIdentifier(local)
        lock.lock()
        let accepted = !stopped && clients.count < 16
        if accepted { clients[id] = (local, scope) }
        lock.unlock()
        guard accepted else {
            local.close(promise: nil)
            return local.eventLoop.makeFailedFuture(RemoteWebPreviewError.tooManyConnections)
        }
        local.closeFuture.whenComplete { [weak self] _ in
            scope.cancel()
            guard let self else { return }
            self.lock.lock(); self.clients.removeValue(forKey: id); self.lock.unlock()
        }
        let inbound = PreviewBytePump()
        return local.pipeline.addHandler(inbound).map {
            let deadline = local.eventLoop.scheduleTask(in: .seconds(15)) {
                scope.cancel(); local.close(promise: nil)
            }
            Task { [client = self.client, remotePort = self.remotePort] in
                do {
                    let outbound = PreviewBytePump()
                    let channel = try await client.createDirectTCPIPChannel(using: .init(
                        targetHost: "127.0.0.1", targetPort: remotePort,
                        originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)), cancellationScope: scope) { remote in
                            remote.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                remote.pipeline.addHandler(outbound)
                            }
                        }
                    deadline.cancel()
                    // Both channels use the SSH event loop. Linking and reads
                    // happen only after both handlers have been installed.
                    local.eventLoop.execute {
                        guard local.isActive, channel.isActive else { scope.cancel(); local.close(promise: nil); return }
                        inbound.peer = channel; outbound.peer = local
                        local.read(); channel.read()
                    }
                } catch { deadline.cancel(); scope.cancel(); local.close(promise: nil) }
            }
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let listener = self.listener; self.listener = nil
        let clients = Array(self.clients.values); self.clients.removeAll()
        lock.unlock()
        listener?.close(promise: nil)
        for (local, scope) in clients { scope.cancel(); local.close(promise: nil) }
    }
    deinit { stop() }
}

private final class PreviewBytePump: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var peer: Channel?
    private var pending = 0
    private var readComplete = false
    private var context: ChannelHandlerContext?
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; peer = nil }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer, peer.isActive else { context.close(promise: nil); return }
        pending += 1
        peer.writeAndFlush(unwrapInboundIn(data)).whenComplete { result in
            self.pending -= 1
            if case .failure = result { context.close(promise: nil); return }
            self.resumeRead()
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) { readComplete = true; resumeRead() }
    private func resumeRead() {
        if pending == 0 && readComplete { readComplete = false; context?.read() }
    }
    func channelInactive(context: ChannelHandlerContext) {
        let other = peer; peer = nil
        other?.close(promise: nil); context.fireChannelInactive()
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Forward a remote FIN after outstanding bytes have been flushed.
        if let event = event as? ChannelEvent, event == .inputClosed {
            peer?.close(mode: .output, promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
