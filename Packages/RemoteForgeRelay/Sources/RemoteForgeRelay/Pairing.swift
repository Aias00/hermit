import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

func privateSessionConfiguration() -> URLSessionConfiguration {
  let c = URLSessionConfiguration.ephemeral
  c.httpShouldSetCookies = false
  c.httpCookieStorage = nil
  c.urlCredentialStorage = nil
  c.urlCache = nil
  c.requestCachePolicy = .reloadIgnoringLocalCacheData
  c.timeoutIntervalForRequest = 15
  c.timeoutIntervalForResource = 30
  return c
}

public enum RelayPairingClient {
  /// Consumes an invitation once. A lost response requires a new invitation.
  public static func redeem(_ invitation: RelayInvitation, name: String) async throws
    -> RelayCredential
  {
    guard invitation.expiresAt > Date() else { throw RelayError.invitationExpired }
    guard name.utf8.count <= 80, !name.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 })
    else {
      throw RelayError.invalidName
    }
    let session = URLSession(
      configuration: privateSessionConfiguration(), delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: invitation.endpoint.resource("/v1/pairings/redeem"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["code": invitation.code, "name": name])
    do {
      try Task.checkCancellation()
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw RelayError.networkFailure }
      guard http.statusCode == 201 else { throw RelayError.httpStatus(http.statusCode) }
      guard response.expectedContentLength <= 65536 else { throw RelayError.protocolViolation }
      var data = Data()
      for try await byte in bytes {
        guard data.count < 65536 else { throw RelayError.protocolViolation }
        data.append(byte)
      }
      struct Grant: Decodable {
        let client_id: String
        let device: String
        let service: String
        let token: String
        let expires_at: String
      }
      guard let g = try? JSONDecoder().decode(Grant.self, from: data),
        g.device == invitation.device, g.service == invitation.service,
        let expires = relayDate(g.expires_at)
      else { throw RelayError.invalidCredential }
      try Task.checkCancellation()
      return try RelayCredential(
        endpoint: invitation.endpoint, device: g.device, service: g.service,
        clientID: g.client_id, expiresAt: expires, token: g.token)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let error = error as? RelayError { throw error }
      throw RelayError.networkFailure
    }
  }
}
