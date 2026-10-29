import Foundation
import Testing
@testable import Moshpit

@Suite("Feedback mail")
struct FeedbackMailTests {
    private let env = FeedbackMail.Environment(
        app: "Hermit 1.0.3 (398) · dev", system: "iOS 26.2",
        device: "iPhone18,2", language: "zh-Hans")

    @Test("subject names the version, body carries the message then the device facts")
    func assembly() {
        let mail = FeedbackMail(message: "  Scrolling jumps in tmux panes.\n", environment: env,
                                log: nil, version: "1.0.3 (398)")
        #expect(mail.subject == "Hermit feedback · 1.0.3 (398)")
        #expect(mail.body == """
        Scrolling jumps in tmux panes.

        App: Hermit 1.0.3 (398) · dev
        System: iOS 26.2
        Device: iPhone18,2
        Language: zh-Hans

        """)
        #expect(mail.log == nil)
    }

    @Test("device facts are omitted when switched off, and an empty message leaves no blank block")
    func optional() {
        let mail = FeedbackMail(message: "   ", environment: nil, log: "  \n", version: "1.0.3 (398)")
        #expect(mail.body == "\n")
        #expect(mail.log == nil, "a whitespace-only log is no log")
    }

    @Test("the recipient is the support address")
    func recipient() {
        #expect(FeedbackMail.recipient == "rokkki@163.com")
    }

    @Test("the mailto fallback encodes subject and body and appends the log inline")
    func mailto() throws {
        let mail = FeedbackMail(message: "a+b & c", environment: nil,
                                log: "line 1\nline 2", version: "1.0.3 (398)")
        let url = try #require(mail.mailtoURL)
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:rokkki@163.com?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let subject = items.first { $0.name == "subject" }?.value
        let body = items.first { $0.name == "body" }?.value
        #expect(subject == "Hermit feedback · 1.0.3 (398)")
        #expect(body == "a+b & c\n\n--- log ---\nline 1\nline 2\n")
        #expect(!url.absoluteString.contains("+"), "a literal plus must be %2B so no client reads it as a space")
    }

    @Test("an oversized log is tail-truncated in the mailto fallback but kept whole for the attachment")
    func truncation() throws {
        let long = (0..<2_000).map { "row \($0)" }.joined(separator: "\n")
        let mail = FeedbackMail(message: "", environment: nil, log: long, version: "1")
        #expect(mail.log == long)
        let url = try #require(mail.mailtoURL)
        let body = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("…"))
        #expect(body.hasSuffix("row 1999\n"))
        #expect(body.count < FeedbackMail.inlineLogLimit + 40)
    }

    /// The public channel next to the mail one: the app's own repository,
    /// on the template chooser so a report starts in shape.
    @Test("the GitHub channel points at the app's own issue templates")
    func gitHubChannel() {
        let url = FeedbackChannels.newIssueURL
        #expect(url.host() == "github.com")
        #expect(url.path() == "/Aias00/hermit/issues/new/choose")
    }
}
