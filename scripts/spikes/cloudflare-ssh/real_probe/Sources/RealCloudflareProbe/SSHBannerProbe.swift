import Foundation
import NIOCore
import NIOPosix
import CloudflareSSH

struct SSHBannerResult: Sendable {
    let protocolVersion: String
    let identificationBytes: Int
}

struct SSHBannerParser {
    private var bytes: [UInt8] = []
    private var lines = 0
    private var consumedBytes = 0

    mutating func consume(_ input: ByteBuffer) throws -> SSHBannerResult? {
        // Everything after identification belongs to SSH key exchange, which
        // this banner-only probe deliberately does not inspect or authenticate.
        bytes.append(contentsOf: input.readableBytesView.prefix(max(0, 8193 - consumedBytes - bytes.count)))
        while let end = bytes.firstIndex(of: 10) {
            let line = Array(bytes.prefix(end + 1))
            bytes.removeFirst(end + 1)
            consumedBytes += line.count
            lines += 1
            if line.starts(with: Array("SSH-".utf8)) {
                guard line.count <= 255, line.dropLast().allSatisfy({ $0 == 13 || (32...126).contains($0) }),
                      let text = String(bytes: line, encoding: .utf8) else { throw ProbeError.invalidBanner }
                if text.hasPrefix("SSH-2.0-"), line.count > 10 {
                    return SSHBannerResult(protocolVersion: "2.0", identificationBytes: line.count)
                }
                if text.hasPrefix("SSH-1.99-"), line.count > 11 {
                    return SSHBannerResult(protocolVersion: "1.99", identificationBytes: line.count)
                }
                throw ProbeError.invalidBanner
            }
            guard lines <= 50, consumedBytes <= 8192 else { throw ProbeError.invalidBanner }
        }
        guard consumedBytes + bytes.count <= 8192 else { throw ProbeError.invalidBanner }
        return nil
    }
}

private final class SSHBannerReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let result: EventLoopPromise<SSHBannerResult>
    private var parser = SSHBannerParser()
    private var completed = false
    private var timeout: Scheduled<Void>?

    init(result: EventLoopPromise<SSHBannerResult>) { self.result = result }

    func handlerAdded(context: ChannelHandlerContext) {
        timeout = context.eventLoop.scheduleTask(in: .seconds(15)) {
            self.finish(.failure(ProbeError.bannerTimedOut))
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        do {
            if let banner = try parser.consume(unwrapInboundIn(data)) { finish(.success(banner)) }
        } catch { finish(.failure(error)); context.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ProbeError.connectionClosed))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish(.failure(ProbeError.connectionClosed)) }

    private func finish(_ value: Result<SSHBannerResult, Error>) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        timeout = nil
        result.completeWith(value)
    }
}

enum SSHBannerProbe {
    static func run(hostname: String, accessToken: String) async throws -> SSHBannerResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let dialer = try CloudflareSSHDialer()
            let connection = try await dialer.connect(endpoint: URL(string: "wss://" + hostname)!, accessToken: accessToken, on: group,
                onDiagnostic: { event in
                    emit("transport_phase", ["phase": String(describing: event.kind),
                         "elapsed_ms": event.elapsedMilliseconds])
                })
            emit("wss_upgraded", ["tls_trust": "system", "tls_hostname_verification": true])
            do {
                let banner = try await withTaskCancellationHandler {
                    let result = connection.channel.eventLoop.makePromise(of: SSHBannerResult.self)
                    try await connection.channel.eventLoop.submit {
                        try connection.channel.pipeline.syncOperations.addHandler(SSHBannerReceiver(result: result))
                    }.get()
                    try await connection.activate()
                    try await connection.channel.writeAndFlush(ByteBuffer(string: "SSH-2.0-Moshpit_Cloudflare_P0\r\n")).get()
                    return try await result.futureResult.get()
                } onCancel: {
                    connection.channel.close(promise: nil)
                }
                await connection.close()
                try await group.shutdownGracefully()
                return banner
            } catch {
                await connection.close()
                throw error
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
