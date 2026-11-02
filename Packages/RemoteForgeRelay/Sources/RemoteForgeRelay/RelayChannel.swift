import Foundation

private final class UpgradeGate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Void, Error>?
  private var waiter: CheckedContinuation<Void, Error>?

  func finish(_ result: Result<Void, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard self.result == nil else { return nil }
      self.result = result
      let pending = waiter
      waiter = nil
      return pending
    }
    continuation?.resume(with: result)
  }
  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let settled = lock.withLock { () -> Result<Void, Error>? in
        if let result { return result }
        waiter = continuation
        return nil
      }
      if let settled { continuation.resume(with: settled) }
    }
  }
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    if `protocol` == nil {
      finish(.success(()))
    } else {
      finish(.failure(RelayError.protocolViolation))
      webSocketTask.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    finish(.failure(RelayError.closed))
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
      finish(.failure(RelayError.httpStatus(response.statusCode)))
    } else {
      finish(.failure(RelayError.networkFailure))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    finish(.failure(RelayError.httpStatus(response.statusCode)))
    completionHandler(nil)
  }
}

/// Foundation tasks are thread safe; only terminal state uses this lock.
private final class RelaySocket: @unchecked Sendable {
  let task: URLSessionWebSocketTask
  private let session: URLSession
  private let gate: UpgradeGate
  private let lock = NSLock()
  private var terminal: RelayError?

  init(credential: RelayCredential) {
    gate = UpgradeGate()
    let configuration = privateSessionConfiguration()
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    session = URLSession(configuration: configuration, delegate: gate, delegateQueue: nil)
    var request = URLRequest(
      url: credential.endpoint.resource(
        "/v1/connect/\(credential.device)/\(credential.service)", webSocket: true))
    request.timeoutInterval = 10
    request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = RelayChannel.maximumFrameSize
  }
  var failure: RelayError? { lock.withLock { terminal } }
  func close(_ reason: RelayError = .closed) {
    let first = lock.withLock { () -> Bool in
      guard terminal == nil else { return false }
      terminal = reason
      return true
    }
    if first {
      gate.finish(.failure(reason))
      task.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
  }
  deinit { close() }

  func open() async throws {
    task.resume()
    try await deadline(seconds: 10) { [gate] in try await gate.wait() }
  }

  func deadline<T: Sendable>(
    seconds: UInt64 = 30, _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { [self] in
          try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
          close(.timedOut)
          throw RelayError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    } onCancel: {
      self.close()
    }
  }

  func ping() async throws {
    try await deadline { [task] in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        task.sendPing { error in
          if error != nil {
            continuation.resume(throwing: RelayError.networkFailure)
          } else {
            continuation.resume()
          }
        }
      }
    }
  }
}

/// One reader and one writer may operate concurrently. There is no queued data
/// stream or automatic reconnection. Close this object when its owner finishes.
public actor RelayChannel {
  public static let maximumFrameSize = 32 * 1024
  private let socket: RelaySocket
  private var writing = false
  private var reading = false
  private var writeEnded = false
  private var readEnded = false
  private var heartbeat: Task<Void, Never>?
  private var eofMonitor: Task<Void, Never>?

  private init(socket: RelaySocket) {
    self.socket = socket
    heartbeat = Task { [socket] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: 20_000_000_000)
          try Task.checkCancellation()
          try await socket.ping()
        }
      } catch {
        if !Task.isCancelled { socket.close(socket.failure ?? .networkFailure) }
      }
    }
  }

  /// Waits for HTTP upgrade, not target readiness or SSH authentication.
  public static func connect(using credential: RelayCredential) async throws -> RelayChannel {
    guard credential.expiresAt > Date() else { throw RelayError.invalidCredential }
    try Task.checkCancellation()
    let socket = RelaySocket(credential: credential)
    do {
      try await socket.open()
      try Task.checkCancellation()
      return RelayChannel(socket: socket)
    } catch {
      let sanitized = socket.failure ?? (error as? RelayError) ?? .networkFailure
      socket.close(sanitized)
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw sanitized
    }
  }

  /// Empty data is a no-op. Large inputs are sent in <=32 KiB messages;
  /// each send is awaited before allocating the next message.
  public func send(_ data: Data) async throws {
    try Task.checkCancellation()
    if let failure = socket.failure { throw failure }
    guard !writing else { throw RelayError.operationInProgress }
    guard !writeEnded else { throw RelayError.writeClosed }
    writing = true
    defer { writing = false }
    do {
      for offset in stride(from: 0, to: data.count, by: Self.maximumFrameSize) {
        try Task.checkCancellation()
        let chunk = data.subdata(in: offset..<min(data.count, offset + Self.maximumFrameSize))
        try await socket.deadline { [socket] in try await socket.task.send(.data(chunk)) }
        try Task.checkCancellation()
      }
    } catch { throw terminate(error) }
  }

  /// Sends the protocol EOF marker. The read direction remains usable.
  public func shutdownWrite() async throws {
    try Task.checkCancellation()
    if let failure = socket.failure { throw failure }
    guard !writing else { throw RelayError.operationInProgress }
    if writeEnded { return }
    writing = true
    defer { writing = false }
    do {
      try await socket.deadline { [socket] in try await socket.task.send(.data(Data())) }
      try Task.checkCancellation()
      writeEnded = true
    } catch { throw terminate(error) }
  }

  /// Returns one bounded message, or nil for the peer's write EOF. There is no
  /// read-ahead queue. An abrupt WebSocket close is an error, never clean EOF.
  public func receive() async throws -> Data? {
    try Task.checkCancellation()
    if readEnded { return nil }
    if let failure = socket.failure { throw failure }
    guard !reading else { throw RelayError.operationInProgress }
    reading = true
    defer { reading = false }
    do {
      let message = try await withTaskCancellationHandler {
        try await socket.task.receive()
      } onCancel: { [socket] in
        socket.close()
      }
      try Task.checkCancellation()
      guard case .data(let data) = message, data.count <= Self.maximumFrameSize else {
        throw RelayError.protocolViolation
      }
      if data.isEmpty {
        readEnded = true
        // Continue observing disconnects and reject data after EOF.
        // This task captures the socket, never the channel, so deinit
        // can cancel it and release the underlying connection.
        eofMonitor = Task { [socket] in
          do {
            _ = try await socket.task.receive()
            socket.close(.protocolViolation)
          } catch { socket.close() }
        }
        return nil
      }
      return data
    } catch { throw terminate(error) }
  }

  public func close() {
    heartbeat?.cancel()
    eofMonitor?.cancel()
    socket.close()
  }
  deinit {
    heartbeat?.cancel()
    eofMonitor?.cancel()
    socket.close()
  }
  private func terminate(_ error: Error) -> Error {
    let safe = socket.failure ?? (error as? RelayError) ?? .networkFailure
    close()
    if Task.isCancelled || error is CancellationError { return CancellationError() }
    return safe
  }
}
