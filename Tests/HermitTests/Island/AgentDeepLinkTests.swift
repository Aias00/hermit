import Foundation
import Testing
@testable import Moshpit
import MoshpitKit

/// `hermit://connection/<uuid>?pane=<paneId>` is written by the app (Live
/// Activity, widget snapshot) and read back by the app, the share extension and
/// the Shortcuts intent. tmux pane ids start with `%`, which is exactly the
/// percent-escape character — both new and legacy links must survive parsing.
@Suite("AgentDeepLink")
struct AgentDeepLinkTests {
    let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test("pane ids round-trip, including two-digit ones that look like escapes",
          arguments: ["%1", "%5", "%12", "%40", "%123", "w1 p2"])
    func roundTrip(pane: String) throws {
        let link = AgentDeepLink.string(connectionId: id, paneId: pane)
        #expect(URL(string: link)?.scheme == "hermit")
        let parsed = try #require(AgentDeepLink.parse(link))
        #expect(parsed.connectionId == id)
        #expect(parsed.paneId == pane)
    }

    @Test("encoded links from the previous app name still round-trip",
          arguments: ["%1", "%5", "%12", "%40", "%123", "w1 p2"])
    func legacyEncodedRoundTrip(pane: String) throws {
        var components = try #require(URLComponents(string: AgentDeepLink.string(connectionId: id, paneId: pane)))
        components.scheme = "moshpit"
        let link = try #require(components.string)
        let parsed = try #require(AgentDeepLink.parse(link))
        #expect(parsed.connectionId == id)
        #expect(parsed.paneId == pane)
    }

    @Test("the uuid is the path, not the host")
    func uuidIsThePath() throws {
        let url = try #require(URL(string: AgentDeepLink.string(connectionId: id, paneId: "%3")))
        #expect(url.host() == "connection")
        #expect(url.lastPathComponent == id.uuidString)
        // Not a connection link: the uuid in the host slot is rejected.
        #expect(AgentDeepLink.parse("moshpit://\(id.uuidString)?pane=%253") == nil)
    }

    @Test("links written before the encoder existed still land on their pane",
          arguments: ["%1", "%12", "%123"])
    func legacyUnencodedPane(pane: String) throws {
        let parsed = try #require(AgentDeepLink.parse("moshpit://connection/\(id.uuidString)?pane=\(pane)"))
        #expect(parsed.paneId == pane)
    }

    @Test("both app names accept a connection link without a pane",
          arguments: ["hermit", "moshpit"])
    func noPane(scheme: String) throws {
        let parsed = try #require(AgentDeepLink.parse("\(scheme)://connection/\(id.uuidString)"))
        #expect(parsed.connectionId == id)
        #expect(parsed.paneId == nil)
    }

    @Test("other schemes are refused unless the caller allows them")
    func schemes() throws {
        let url = try #require(URL(string: "moshpitdemo://connection/\(id.uuidString)?pane=%2512"))
        #expect(AgentDeepLink.parse(url) == nil)
        #expect(AgentDeepLink.parse(url, schemes: ["moshpit", "moshpitdemo"])?.paneId == "%12")
    }

    @Test("an explicit scheme allowlist never implicitly adds either app name")
    func explicitSchemeAllowlist() throws {
        let current = try #require(URL(string: "hermit://connection/\(id.uuidString)?pane=%2512"))
        let legacy = try #require(URL(string: "moshpit://connection/\(id.uuidString)?pane=%2512"))
        #expect(AgentDeepLink.parse(current)?.paneId == "%12")
        #expect(AgentDeepLink.parse(legacy)?.paneId == "%12")
        #expect(AgentDeepLink.parse(current, schemes: ["hermit"])?.paneId == "%12")
        #expect(AgentDeepLink.parse(legacy, schemes: ["hermit"]) == nil)
        #expect(AgentDeepLink.parse(legacy, schemes: ["moshpit"])?.paneId == "%12")
        #expect(AgentDeepLink.parse(current, schemes: ["moshpit"]) == nil)
        #expect(AgentDeepLink.parse(current, schemes: ["moshpitdemo"]) == nil)
        #expect(AgentDeepLink.parse(legacy, schemes: ["moshpitdemo"]) == nil)
        #expect(AgentDeepLink.parse(current, schemes: []) == nil)
        #expect(AgentDeepLink.parse(legacy, schemes: []) == nil)
    }

    @Test("a widget row's target is what the share sheet and Shortcuts address")
    func widgetItemTarget() throws {
        let item = AgentWidgetState.Item(
            id: "x", command: "claude", location: "work · 4:rugisland",
            state: "attention", startedAt: .now,
            deepLink: AgentDeepLink.string(connectionId: id, paneId: "%12"))
        let target = try #require(item.target)
        #expect(target.connectionId == id)
        #expect(target.paneId == "%12")

        let noLink = AgentWidgetState.Item(id: "y", command: "claude", location: "",
                                           state: "working", startedAt: .now)
        #expect(noLink.target == nil)
    }

    @Test("the app's URL handler opens new and existing links at the exact pane",
          arguments: ["hermit", "moshpit"])
    @MainActor
    func routerRequestsPane(scheme: String) throws {
        let router = DeepLinkRouter()
        var components = try #require(URLComponents(string: AgentDeepLink.string(connectionId: id, paneId: "%12")))
        components.scheme = scheme
        let url = try #require(components.url)
        router.handle(url)
        #expect(router.paneRequest?.connectionId == id)
        #expect(router.paneRequest?.paneId == "%12")
    }
}
