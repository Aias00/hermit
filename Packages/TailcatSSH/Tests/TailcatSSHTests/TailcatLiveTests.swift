import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import TailcatSSH

/// Opt-in only. The private fixture is supplied by the local integration
/// harness; no credential, address, peer text, or key is printed on failure.
final class TailcatLiveTests: XCTestCase {
    func testTwoRealStreamsShareIdentityAndCloseIndependently() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOSHPIT_TAILCAT_LIVE_FIXTURE"] else {
            throw XCTSkip("Set MOSHPIT_TAILCAT_LIVE_FIXTURE to a private local fixture file.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let one = Task { try await TailcatSSHDialer().connect(address: fixture.address, clientKey: fixture.client_private_key,
                                                            port: fixture.port, on: group) }
        let two = Task { try await TailcatSSHDialer().connect(address: fixture.address, clientKey: fixture.client_private_key,
                                                            port: fixture.port, on: group) }
        var first: TailcatSSHConnection?
        var second: TailcatSSHConnection?
        do {
            first = try await one.value
            second = try await two.value
            let firstBanner = expectation(description: "first SSH server banner")
            let secondBanner = expectation(description: "second SSH server banner")
            let secondPackets = expectation(description: "second stream continues after first closes")
            let firstReader = SSHBannerReader(banner: { firstBanner.fulfill() }, packet: {})
            let secondReader = SSHBannerReader(banner: { secondBanner.fulfill() }, packet: { secondPackets.fulfill() })
            try await first!.channel.pipeline.addHandler(firstReader).get()
            try await second!.channel.pipeline.addHandler(secondReader).get()
            try await first!.activate()
            try await second!.activate()
            await fulfillment(of: [firstBanner, secondBanner], timeout: 5)
            await first!.close()
            XCTAssertTrue(second!.channel.isActive)
            var version = second!.channel.allocator.buffer(capacity: 64)
            version.writeString("SSH-2.0-MoshpitTailcatFixture\r\n")
            try await second!.channel.writeAndFlush(version).get()
            await fulfillment(of: [secondPackets], timeout: 5)
            await second!.close()
            try await group.shutdownGracefully()
        } catch {
            one.cancel(); two.cancel()
            if let first { await first.close() }
            else if let late = try? await one.value { await late.close() }
            if let second { await second.close() }
            else if let late = try? await two.value { await late.close() }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private struct Fixture: Decodable {
        let address: String
        let client_private_key: String
        let port: Int
    }
}

private final class SSHBannerReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var bytes = Data()
    private var hasBanner = false
    private var hasPacket = false
    private let banner: () -> Void
    private let packet: () -> Void
    init(banner: @escaping () -> Void, packet: @escaping () -> Void) { self.banner = banner; self.packet = packet }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard let end = bytes.firstIndex(of: 10) else { return }
        if !hasBanner, bytes.starts(with: Data("SSH-2.0-".utf8)) { hasBanner = true; banner() }
        if hasBanner, !hasPacket, bytes.count > end + 5 { hasPacket = true; packet() }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
