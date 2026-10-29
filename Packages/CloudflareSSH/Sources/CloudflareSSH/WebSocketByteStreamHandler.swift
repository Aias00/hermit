import Foundation
import NIOCore
import NIOWebSocket

public enum CloudflareSSHTransportError: Error, Equatable, Sendable {
    public enum TLSFailureReason: String, Sendable {
        case hostnameMismatch, certificateRejected, invalidServerName, handshakeFailed, connectionClosed
    }
    case invalidEndpoint
    case invalidCredential
    case deadlineExceeded
    case httpStatus(Int)
    case unsupportedWebSocketOptions
    case invalidWebSocketFrame
    case textFrameUnsupported
    case bufferLimitExceeded
    case connectionClosed
    case heartbeatTimedOut
    case heartbeatWriteTimedOut
    case dnsFailure(code: Int?)
    case tlsFailure(TLSFailureReason)
    case socketFailure(code: Int32?)
    case upgradeFailed
}

extension CloudflareSSHTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Cloudflare 入口无效，请填写有效的 WSS 地址。"
        case .invalidCredential: return "Cloudflare Access 凭据无效，请重新登录。"
        case .deadlineExceeded: return "连接 Cloudflare 入口超时。"
        case .httpStatus(302), .httpStatus(401): return "Cloudflare Access 需要登录或登录已过期。"
        case .httpStatus(403): return "Cloudflare Access 拒绝访问，请检查账户和允许策略。"
        case .httpStatus(502), .httpStatus(503), .httpStatus(530): return "Cloudflare 隧道或 SSH 上游不可达。"
        case .httpStatus(let code): return "Cloudflare WebSocket 升级失败（HTTP \(code)）。"
        case .unsupportedWebSocketOptions: return "入口返回了未支持的 WebSocket 扩展或子协议。"
        case .invalidWebSocketFrame: return "入口返回了无效的 WebSocket 帧。"
        case .textFrameUnsupported: return "入口返回了文本消息，无法作为 SSH 字节流使用。"
        case .bufferLimitExceeded: return "连接缓冲区达到上限，已断开以防止丢失 SSH 数据。"
        case .connectionClosed: return "Cloudflare SSH 传输已关闭。"
        case .heartbeatTimedOut: return "Cloudflare 连接心跳超时。"
        case .heartbeatWriteTimedOut: return "Cloudflare 心跳写入停止推进，连接已关闭。"
        case .dnsFailure(let code): return "无法解析 Cloudflare 入口域名" + (code.map { "（DNS \($0)）。" } ?? "。")
        case .socketFailure(let code): return "无法连接 Cloudflare 入口" + (code.map { "（系统错误 \($0)）。" } ?? "。")
        case .tlsFailure(.hostnameMismatch): return "Cloudflare TLS 证书与入口域名不匹配。"
        case .tlsFailure(.certificateRejected): return "Cloudflare TLS 证书未通过信任验证。"
        case .tlsFailure(.invalidServerName): return "Cloudflare TLS 入口名称无效。"
        case .tlsFailure(.handshakeFailed): return "Cloudflare TLS 握手失败，请检查证书及网络。"
        case .tlsFailure(.connectionClosed): return "Cloudflare TLS 连接已关闭，请重新连接。"
        case .upgradeFailed: return "Cloudflare WebSocket 升级响应校验失败。"
        }
    }
}

/// A binary WebSocket is a byte stream, not a sequence of SSH packets.
/// State belongs exclusively to the channel's event loop. No payload is logged.
final class WebSocketByteStreamHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private let maximumBufferedBytes: Int
    let diagnosticState: CloudflareSSHDiagnostics
    private let heartbeatInterval: TimeAmount?
    private let heartbeatTimeout: TimeAmount
    private var active = false
    private var fragmentedBinary = false
    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    private var pendingWriteBytes = 0
    private var closing = false
    private var errorForwarded = false
    private var heartbeatTask: Scheduled<Void>?
    private var pongDeadline: Scheduled<Void>?
    private var pingWriteDeadline: Scheduled<Void>?
    private var expectedPong: ByteBuffer?
    private var pendingPingWrite: ByteBuffer?
    private var closeDeadline: Scheduled<Void>?
    private var underlyingCloseRequested = false
    private var closeWaiters: [EventLoopPromise<Void>] = []

    init(
        maximumBufferedBytes: Int = 1 << 20,
        heartbeatInterval: TimeAmount? = .seconds(20),
        heartbeatTimeout: TimeAmount = .seconds(10),
        diagnostics: CloudflareSSHDiagnostics = CloudflareSSHDiagnostics()
    ) {
        precondition(maximumBufferedBytes > 0)
        self.maximumBufferedBytes = maximumBufferedBytes
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.diagnosticState = diagnostics
    }

    func handlerAdded(context: ChannelHandlerContext) {
        scheduleHeartbeat(context: context)
    }

    /// Call only after the SSH consumer has been installed. Data arriving with
    /// the HTTP 101 response remains here until that consumer is ready.
    func activate(context: ChannelHandlerContext) throws {
        context.eventLoop.assertInEventLoop()
        guard context.channel.isActive, !closing else {
            throw CloudflareSSHTransportError.connectionClosed
        }
        guard !active else { return }
        active = true
        diagnosticState.record(.activated)
        let pending = buffered
        buffered.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        for bytes in pending where !closing {
            context.fireChannelRead(wrapInboundOut(bytes))
        }
        if !pending.isEmpty, !closing { context.fireChannelReadComplete() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closing else { return }
        let frame = unwrapInboundIn(data)
        guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
            fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
            return
        }
        let payload = frame.unmaskedData
        switch frame.opcode {
        case .binary:
            guard !fragmentedBinary else {
                fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
                return
            }
            fragmentedBinary = !frame.fin
            receive(payload, context: context)
        case .continuation:
            guard fragmentedBinary else {
                fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
                return
            }
            fragmentedBinary = !frame.fin
            receive(payload, context: context)
        case .ping, .pong, .connectionClose:
            guard frame.fin, payload.readableBytes <= 125 else {
                fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
                return
            }
            if frame.opcode == .ping {
                writePong(payload, context: context)
            } else if frame.opcode == .pong {
                diagnosticState.record(.pongReceived(matched: payload == expectedPong))
                if payload == expectedPong {
                    expectedPong = nil
                    pendingPingWrite = nil
                    pingWriteDeadline?.cancel()
                    pingWriteDeadline = nil
                    pongDeadline?.cancel()
                    pongDeadline = nil
                }
            } else {
                guard validClose(payload) else {
                    fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
                    return
                }
                let code: UInt16? = payload.getInteger(at: payload.readerIndex)
                diagnosticState.record(.peerClose(code: code))
                beginClose(payload: payload, context: context)
            }
        case .text:
            fail(CloudflareSSHTransportError.textFrameUnsupported, code: 1003, context: context)
        default:
            fail(CloudflareSSHTransportError.invalidWebSocketFrame, code: 1002, context: context)
        }
    }

    private func receive(_ bytes: ByteBuffer, context: ChannelHandlerContext) {
        guard bytes.readableBytes > 0 else { return }
        if active {
            context.fireChannelRead(wrapInboundOut(bytes))
        } else {
            guard bytes.readableBytes <= maximumBufferedBytes - bufferedBytes else {
                fail(CloudflareSSHTransportError.bufferLimitExceeded, code: 1009, context: context)
                return
            }
            buffered.append(bytes)
            bufferedBytes += bytes.readableBytes
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if active { context.fireChannelReadComplete() }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var bytes = unwrapOutboundIn(data)
        guard !closing else {
            promise?.fail(CloudflareSSHTransportError.connectionClosed)
            return
        }
        let count = bytes.readableBytes
        guard count <= maximumBufferedBytes - pendingWriteBytes else {
            // Promise callbacks may synchronously request close. Preserve the
            // actual write failure before that cleanup can become the cause.
            diagnosticState.recordFailure(CloudflareSSHTransportError.bufferLimitExceeded)
            promise?.fail(CloudflareSSHTransportError.bufferLimitExceeded)
            fail(CloudflareSSHTransportError.bufferLimitExceeded, code: 1009, context: context)
            return
        }
        guard count > 0 else { promise?.succeed(()); return }
        pendingWriteBytes += count
        var writes: [EventLoopFuture<Void>] = []
        while let part = bytes.readSlice(length: min(bytes.readableBytes, 16 * 1024)), part.readableBytes > 0 {
            let completion = context.eventLoop.makePromise(of: Void.self)
            writes.append(completion.futureResult)
            // Observe each 16 KiB frame, not just the whole caller write: a
            // large transfer can drain steadily for longer than one deadline.
            completion.futureResult.whenSuccess { self.outboundWriteProgress(context: context) }
            context.write(wrapOutboundOut(clientFrame(.binary, part)), promise: completion)
        }
        EventLoopFuture.andAllSucceed(writes, on: context.eventLoop).whenComplete { result in
            self.pendingWriteBytes -= count
            if case .failure(let error) = result { self.diagnosticState.recordFailure(error) }
            promise?.completeWith(result.mapError(CloudflareSSHDialer.sanitizedError))
            if case .failure(let error) = result { self.fail(error, code: 1011, context: context) }
        }
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // WebSocket has no TCP half-close. A transport close ends the SSH stream.
        guard context.channel.isActive else { promise?.succeed(()); return }
        if let promise { closeWaiters.append(promise) }
        diagnosticState.record(.localCloseRequested)
        beginClose(payload: closePayload(1000, allocator: context.channel.allocator), context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, code: 1011, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !closing { diagnosticState.record(.transportEOF) }
        diagnosticState.record(.closed)
        closing = true
        clearTimersAndBuffer()
        completeCloseWaiters(.success(()))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        clearTimersAndBuffer()
        completeCloseWaiters(.failure(CloudflareSSHTransportError.connectionClosed))
    }

    private func fail(_ error: Error, code: UInt16, context: ChannelHandlerContext) {
        diagnosticState.recordFailure(error)
        if !errorForwarded {
            errorForwarded = true
            context.fireErrorCaught(CloudflareSSHDialer.sanitizedError(error))
        }
        beginClose(payload: closePayload(code, allocator: context.channel.allocator), context: context)
    }

    private func beginClose(payload: ByteBuffer, context: ChannelHandlerContext) {
        guard !closing else { return }
        closing = true
        clearTimersAndBuffer()
        let written = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(clientFrame(.connectionClose, payload)), promise: written)
        written.futureResult.whenComplete { _ in
            self.closeDeadline?.cancel()
            self.closeDeadline = nil
            self.closeUnderlying(context: context)
        }
        if context.channel.isActive {
            closeDeadline = context.eventLoop.scheduleTask(in: .seconds(2)) {
                self.closeUnderlying(context: context)
            }
        }
    }

    private func closeUnderlying(context: ChannelHandlerContext) {
        guard !underlyingCloseRequested else { return }
        underlyingCloseRequested = true
        let completion = context.eventLoop.makePromise(of: Void.self)
        completion.futureResult.whenComplete { self.completeCloseWaiters($0) }
        context.close(mode: .all, promise: completion)
    }

    private func completeCloseWaiters(_ result: Result<Void, Error>) {
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.completeWith(result) }
    }

    private func scheduleHeartbeat(context: ChannelHandlerContext) {
        guard let interval = heartbeatInterval, !closing else { return }
        heartbeatTask = context.eventLoop.scheduleTask(in: interval) {
            guard !self.closing else { return }
            if self.expectedPong == nil {
                var payload = context.channel.allocator.buffer(capacity: 8)
                payload.writeInteger(UInt64.random(in: .min ... .max))
                self.expectedPong = payload
                self.pendingPingWrite = payload
                self.diagnosticState.record(.pingQueued)
                // Install the write deadline before invoking handlers: a write
                // completion or matching pong can arrive synchronously.
                self.outboundWriteProgress(context: context)
                let written = context.eventLoop.makePromise(of: Void.self)
                written.futureResult.whenComplete { result in
                    guard !self.closing else { return }
                    switch result {
                    case .success:
                        self.diagnosticState.record(.pingSent)
                        guard self.pendingPingWrite == payload else { return }
                        self.pendingPingWrite = nil
                        self.pingWriteDeadline?.cancel()
                        self.pingWriteDeadline = nil
                        guard self.expectedPong == payload else { return }
                        // Queueing behind SSH traffic is not time spent waiting
                        // for the peer. Only a completed write starts this clock.
                        self.pongDeadline = context.eventLoop.scheduleTask(in: self.heartbeatTimeout) {
                            guard !self.closing, self.expectedPong == payload else { return }
                            self.fail(CloudflareSSHTransportError.heartbeatTimedOut, code: 1001, context: context)
                        }
                    case .failure(let error):
                        self.fail(error, code: 1011, context: context)
                    }
                }
                context.writeAndFlush(self.wrapOutboundOut(self.clientFrame(.ping, payload)), promise: written)
            }
            self.scheduleHeartbeat(context: context)
        }
    }

    /// While a ping is queued, completed FIFO writes prove the queue is still
    /// draining. They never extend the pong deadline after the ping is sent.
    private func outboundWriteProgress(context: ChannelHandlerContext) {
        guard !closing, pendingPingWrite != nil else { return }
        pingWriteDeadline?.cancel()
        pingWriteDeadline = context.eventLoop.scheduleTask(in: heartbeatTimeout) {
            guard !self.closing, self.pendingPingWrite != nil else { return }
            self.fail(CloudflareSSHTransportError.heartbeatWriteTimedOut, code: 1001, context: context)
        }
    }

    private func writePong(_ payload: ByteBuffer, context: ChannelHandlerContext) {
        let written = context.eventLoop.makePromise(of: Void.self)
        written.futureResult.whenComplete { result in
            guard !self.closing else { return }
            switch result {
            case .success: self.outboundWriteProgress(context: context)
            case .failure(let error): self.fail(error, code: 1011, context: context)
            }
        }
        context.writeAndFlush(wrapOutboundOut(clientFrame(.pong, payload)), promise: written)
    }

    private func clearTimersAndBuffer() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pongDeadline?.cancel()
        pongDeadline = nil
        pingWriteDeadline?.cancel()
        pingWriteDeadline = nil
        expectedPong = nil
        pendingPingWrite = nil
        closeDeadline?.cancel()
        closeDeadline = nil
        buffered.removeAll(keepingCapacity: false)
        bufferedBytes = 0
    }

    private func clientFrame(_ opcode: WebSocketOpcode, _ payload: ByteBuffer) -> WebSocketFrame {
        WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: payload)
    }

    private func closePayload(_ code: UInt16, allocator: ByteBufferAllocator) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 2)
        payload.writeInteger(code)
        return payload
    }

    private func validClose(_ payload: ByteBuffer) -> Bool {
        guard payload.readableBytes != 1 else { return false }
        guard payload.readableBytes >= 2 else { return true }
        guard let code: UInt16 = payload.getInteger(at: payload.readerIndex),
              ([1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014].contains(Int(code))
                || (3000...4999).contains(Int(code))),
              let reason = payload.getBytes(at: payload.readerIndex + 2, length: payload.readableBytes - 2)
        else { return false }
        return String(bytes: reason, encoding: .utf8) != nil
    }
}
