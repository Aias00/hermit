import Foundation
import Testing
@testable import Moshpit

@Suite("Tailscale login presentation")
struct TailscaleLoginPresentationTests {
    private let url = URL(string: "https://login.tailscale.com/a/disposable-test")!

    @Test("Restoring an account's login URL never opens a browser by itself")
    func restoredLoginIsNotConsent() {
        let presentation = TailscaleLoginPresentation()
        #expect(presentation.automaticPageURL(loginURL: url, state: .needsLogin) == nil)
    }

    @Test("Only an explicit login opens the validated page while login is pending")
    func explicitLoginAndCancellation() {
        var presentation = TailscaleLoginPresentation()
        presentation.requestLogin()
        #expect(presentation.automaticPageURL(loginURL: url, state: .needsLogin) == url)
        for state in [TailscaleAccountState.signedOut, .starting, .needsApproval, .connected, .failed] {
            #expect(presentation.automaticPageURL(loginURL: url, state: state) == nil)
        }
        presentation.cancel()
        #expect(presentation.automaticPageURL(loginURL: url, state: .needsLogin) == nil)
    }

    @Test("A plaintext or untrusted login URL is never presented", arguments: [
        "http://login.tailscale.com/a/test", "https://login.tailscale.com.evil.example/a/test",
        "https://example.com/a/test", "https://user:pass@login.tailscale.com/a/test"
    ])
    func invalidLoginURL(_ value: String) {
        var presentation = TailscaleLoginPresentation()
        presentation.requestLogin()
        #expect(presentation.automaticPageURL(loginURL: URL(string: value), state: .needsLogin) == nil)
    }
}
