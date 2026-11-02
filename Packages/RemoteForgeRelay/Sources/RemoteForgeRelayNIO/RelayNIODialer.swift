import Darwin
import Foundation
import NIOCore
import NIOPosix
import RemoteForgeRelay

public enum RelayNIOError: Error, Equatable, Sendable {
  case socketPairFailed, bufferLimitExceeded, closed, invalidTimeout, activationTimedOut
}

/// Retain the carrier until SSH teardown. Install the SSH handlers before
/// activate(), and close on every setup/authentication failure.
public struct RelayNIOConnection: Sendable {
  public let channel: any Channel
  private let state: BridgeState

  fileprivate init(channel: any Channel, state: BridgeState) {
    self.channel = channel
    self.state = state
  }

  public func activate() async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await state.loop.flatSubmit { self.state.activate() }.get()
      try Task.checkCancellation()
    } onCancel: {
      self.state.loop.execute { self.state.finish(CancellationError()) }
    }
  }

  public func close() async {
    let cleanup = try? await state.loop.submit {
      self.state.finish(nil)
      return self.state.cleanup
    }.get()
    await cleanup?.value
    _ = try? await state.loop.submit {}.get()
    try? await channel.closeFuture.get()
  }
}

public enum RelayNIODialer {
  /// Uses private socketpair descriptors: no public/local listening port.
  /// HTTP upgrade alone does not prove target readiness or SSH authentication.
  public static func connect(
    using credential: RelayCredential, on group: MultiThreadedEventLoopGroup,
    activationTimeout: TimeAmount = .seconds(30)
  ) async throws -> RelayNIOConnection {
    guard activationTimeout.nanoseconds > 0 else { throw RelayNIOError.invalidTimeout }
    let relay = try await RelayChannel.connect(using: credential)
    let loop = group.next()
    let state = BridgeState(loop: loop, relay: relay)
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
          throw RelayNIOError.socketPairFailed
        }
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        for fd in descriptors {
          guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw RelayNIOError.socketPairFailed }
        }
        func bootstrap<Handler: ChannelHandler & Sendable>(_ handler: Handler) -> ClientBootstrap {
          ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(
              ChannelOptions.recvAllocator,
              value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024)
            )
            .channelOption(
              ChannelOptions.writeBufferWaterMark,
              value: ChannelOptions.Types.WriteBufferWaterMark(low: 64 * 1024, high: 256 * 1024)
            )
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
        }
        let publicFD = descriptors[0]
        descriptors[0] = -1  // Ownership passes to NIO even on setup failure.
        let client = try await bootstrap(PublicGuard(state: state)).withConnectedSocket(publicFD)
          .get()
        try await loop.submit { try state.attachClient(client) }.get()
        try Task.checkCancellation()
        let bridgeFD = descriptors[1]
        descriptors[1] = -1
        let bridge = try await bootstrap(RelayOutbound(state: state)).withConnectedSocket(bridgeFD)
          .get()
        try await loop.submit {
          try state.attachBridge(bridge, activationTimeout: activationTimeout)
        }.get()
        try Task.checkCancellation()
        return RelayNIOConnection(channel: client, state: state)
      } onCancel: {
        loop.execute { state.finish(CancellationError()) }
      }
    } catch {
      await relay.close()
      _ = try? await loop.submit { state.finish(error) }.get()
      if Task.isCancelled { throw CancellationError() }
      if error is RelayError || error is RelayNIOError || error is CancellationError { throw error }
      throw RelayNIOError.closed
    }
  }
}

// State, handler callbacks and activation all belong to one selectable loop.
// Tasks capture immutable socket/relay references, then submit results to it.
private final class BridgeState: @unchecked Sendable {
  let loop: any EventLoop
  let relay: RelayChannel
  private var client: (any Channel)?
  private var bridge: (any Channel)?
  private var activated = false
  private(set) var closing = false
  private(set) var cleanup: Task<Void, Never>?
  private var receiving: Task<Void, Never>?
  private var sending: Task<Void, Never>?
  private var outputEnded = false
  private var inputEnded = false
  private var localReadEOF = false
  private var publicOutputRequested = false
  private var publicClosed = false
  private var activationDeadline: Scheduled<Void>?

  init(loop: any EventLoop, relay: RelayChannel) {
    self.loop = loop
    self.relay = relay
  }

  func attachClient(_ channel: any Channel) throws {
    loop.preconditionInEventLoop()
    guard !closing else {
      channel.close(promise: nil)
      throw RelayNIOError.closed
    }
    client = channel
    channel.closeFuture.whenComplete { _ in
      self.publicClosed = true
      if self.inputEnded && self.publicOutputRequested {
        self.finishIfDrained()
      } else {
        self.finish(nil)
      }
    }
  }
  func attachBridge(_ channel: any Channel, activationTimeout: TimeAmount) throws {
    loop.preconditionInEventLoop()
    guard !closing else {
      channel.close(promise: nil)
      throw RelayNIOError.closed
    }
    bridge = channel
    channel.closeFuture.whenComplete { _ in
      if !(self.inputEnded && self.localReadEOF) { self.finish(RelayNIOError.closed) }
    }
    activationDeadline = loop.scheduleTask(in: activationTimeout) {
      self.finish(RelayNIOError.activationTimedOut)
    }
  }

  func activate() -> EventLoopFuture<Void> {
    loop.preconditionInEventLoop()
    guard !closing, let client, let bridge, client.isActive, bridge.isActive else {
      return loop.makeFailedFuture(RelayNIOError.closed)
    }
    if activated { return loop.makeSucceededVoidFuture() }
    activated = true
    activationDeadline?.cancel()
    activationDeadline = nil
    return client.setOption(ChannelOptions.autoRead, value: true).flatMapThrowing {
      guard !self.closing else { throw RelayNIOError.closed }
      bridge.read()
      self.receiving = Task { [relay = self.relay, bridge, loop = self.loop] in
        do {
          while let bytes = try await relay.receive() {
            try Task.checkCancellation()
            var buffer = bridge.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            // One bounded message awaits its local socket write before reading
            // the next. Native socket backpressure reaches the relay receiver.
            try await bridge.writeAndFlush(buffer).get()
          }
          try await loop.submit { self.inputEnded = true }.get()
          try await bridge.close(mode: .output).get()
        } catch {
          loop.execute { self.finish(error) }
        }
      }
    }.flatMapError { error in
      self.finish(error)
      return self.loop.makeFailedFuture(error)
    }
  }

  func send(_ bytes: ByteBuffer) {
    loop.preconditionInEventLoop()
    guard !closing, sending == nil, bytes.readableBytes <= 32 * 1024 else {
      finish(RelayNIOError.bufferLimitExceeded)
      return
    }
    let data = Data(bytes.readableBytesView)
    sending = Task { [relay] in
      do {
        try await relay.send(data)
        self.loop.execute {
          if !self.localReadEOF {
            self.sending = nil
            if !self.closing { self.bridge?.read() }
          }
        }
      } catch { self.loop.execute { self.finish(error) } }
    }
  }

  func localEOF() {
    loop.preconditionInEventLoop()
    guard !closing, !localReadEOF else { return }
    localReadEOF = true
    // EOF may arrive in the same read as the final data. Wait for that send
    // task first, then send exactly one protocol EOF marker.
    let pending = sending
    sending = Task { [relay] in
      await pending?.value
      do {
        try Task.checkCancellation()
        try await relay.shutdownWrite()
        self.loop.execute {
          self.sending = nil
          self.outputEnded = true
          self.finishIfDrained()
        }
      } catch { self.loop.execute { self.finish(error) } }
    }
  }
  func publicOutputClose() {
    loop.preconditionInEventLoop()
    publicOutputRequested = true
  }
  private func finishIfDrained() {
    if publicClosed && localReadEOF && outputEnded { finish(nil) }
  }
  func finish(_ error: Error?) {
    loop.preconditionInEventLoop()
    guard !closing else { return }
    closing = true
    activationDeadline?.cancel()
    activationDeadline = nil
    let rx = receiving
    let tx = sending
    rx?.cancel()
    tx?.cancel()
    receiving = nil
    sending = nil
    if let error {
      let safe: Error =
        (error is RelayError || error is RelayNIOError || error is CancellationError)
        ? error : RelayNIOError.closed
      client?.pipeline.fireErrorCaught(safe)
    }
    client?.close(promise: nil)
    bridge?.close(promise: nil)
    client = nil
    bridge = nil
    cleanup = Task { [relay] in
      await relay.close()
      await rx?.value
      await tx?.value
    }
  }
}

private final class RelayOutbound: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  let state: BridgeState
  init(state: BridgeState) { self.state = state }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    state.send(unwrapInboundIn(data))
  }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let e = event as? ChannelEvent, e == .inputClosed {
      state.localEOF()
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { state.finish(error) }
}

/// Caps queued NIO writes even if a producer ignores channel writability.
private final class PublicGuard: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = ByteBuffer
  let state: BridgeState
  private var pending = 0
  init(state: BridgeState) { self.state = state }
  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let bytes = unwrapOutboundIn(data)
    let count = bytes.readableBytes
    guard !state.closing else {
      promise?.fail(RelayNIOError.closed)
      return
    }
    guard count <= 1024 * 1024 - pending else {
      promise?.fail(RelayNIOError.bufferLimitExceeded)
      state.finish(RelayNIOError.bufferLimitExceeded)
      return
    }
    pending += count
    let written = context.eventLoop.makePromise(of: Void.self)
    written.futureResult.whenComplete { result in
      self.pending -= count
      promise?.completeWith(result)
    }
    context.write(data, promise: written)
  }
  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    if mode == .output {
      state.publicOutputClose()
      context.close(mode: mode, promise: promise)
    } else {
      context.close(mode: .all, promise: promise)
      state.finish(nil)
    }
  }
}
