import Foundation

/// Browser presentation is a user decision, independent of restoring a node
/// whose persisted state already contains an authentication URL.
struct TailscaleLoginPresentation {
    private(set) var explicitlyRequested = false

    mutating func requestLogin() { explicitlyRequested = true }
    mutating func cancel() { explicitlyRequested = false }

    func automaticPageURL(loginURL: URL?, state: TailscaleAccountState) -> URL? {
        guard explicitlyRequested, state == .needsLogin else { return nil }
        return TailscaleRuntime.validLoginURL(loginURL)
    }
}
