import Observation

/// Session-local inbox state. Pane IDs are only meaningful for this connection.
@MainActor
@Observable
final class AgentInbox {
    private var states: [String: String?] = [:]
    private var unread: Set<String> = []
    private var pinned: Set<String> = []

    func observe(hooks: [String: AgentHook], activePaneId: String?) {
        // An empty read is not evidence that every agent is gone.
        guard !hooks.isEmpty else { return }

        let paneIDs = Set(hooks.keys)
        states = states.filter { paneIDs.contains($0.key) }
        unread.formIntersection(paneIDs)
        pinned.formIntersection(paneIDs)

        for (paneID, hook) in hooks {
            if paneID == activePaneId {
                unread.remove(paneID)
            } else if let previousState = states[paneID], previousState != hook.state,
                      hook.state == "done" || hook.state == "attention" {
                unread.insert(paneID)
            }
            // Keep a dictionary entry even for nil, so first sighting is silent.
            states.updateValue(hook.state, forKey: paneID)
        }
    }

    func markRead(_ paneID: String) { unread.remove(paneID) }

    func togglePin(_ paneID: String) {
        if !pinned.insert(paneID).inserted { pinned.remove(paneID) }
    }

    func isUnread(_ paneID: String) -> Bool { unread.contains(paneID) }
    func isPinned(_ paneID: String) -> Bool { pinned.contains(paneID) }
}
