import Foundation
import Testing
@testable import Moshpit

@Suite("Launchpad commands")
struct LaunchItemTests {
    @Test func directoryIsShellQuoted() {
        let item = LaunchItem(name: "test", command: "codex", directory: "/tmp/a'b $(touch nope)")
        #expect(item.shellCommand == "cd -- '/tmp/a'\\''b $(touch nope)' && codex")
    }
    @Test func directoryOnlyDoesNotLeaveDanglingOperator() {
        #expect(LaunchItem(name: "project", command: "", directory: "/tmp/repo").shellCommand == "cd -- '/tmp/repo'")
        #expect(LaunchItem(name: "action", command: "date").shellCommand == "date")
    }
    @Test func savedItemsPreserveHostAndProject() throws {
        let item = LaunchItem(name: "project", hostID: UUID(), command: "codex", directory: "/tmp/repo", isProject: true)
        #expect(try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
