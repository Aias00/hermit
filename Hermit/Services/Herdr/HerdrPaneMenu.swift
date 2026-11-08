import Foundation

enum HerdrMenuResource: Equatable, Sendable {
    case workspace(String), tab(String), pane(String)
}

struct HerdrPaneMenuTarget: Equatable, Sendable {
    let generation: UUID
    let resource: HerdrMenuResource
    let paneID: String?
    let tabID: String?
    let workspaceID: String
    let terminalID: String?
    let workspaceName: String
    let tabName: String?
    let paneIndex: Int?
    init(generation: UUID, paneID: String?, tabID: String?, workspaceID: String,
         terminalID: String?, workspaceName: String, tabName: String?, paneIndex: Int?, resource: HerdrMenuResource? = nil) {
        self.generation = generation; self.paneID = paneID; self.tabID = tabID; self.workspaceID = workspaceID
        self.terminalID = terminalID; self.workspaceName = workspaceName; self.tabName = tabName; self.paneIndex = paneIndex
        self.resource = resource ?? paneID.map(HerdrMenuResource.pane) ?? .workspace(workspaceID)
    }
    var title: String {
        switch resource {
        case .workspace: return workspaceName
        case .tab: return [workspaceName, tabName].compactMap { $0 }.joined(separator: " · ")
        case .pane: return [workspaceName, tabName, paneIndex.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }
    var renameTitle: String { if case .workspace = resource { return "重命名工作区" }; return "重命名标签页" }
    var closeTitle: String {
        switch resource { case .workspace: return "关闭工作区"; case .tab: return "关闭标签页"; case .pane: return "关闭窗格" }
    }
    var canSplit: Bool { if case .workspace = resource { return false }; return paneID != nil }
    var closeAction: HerdrPaneMenuAction {
        switch resource { case .workspace: return .closeWorkspace; case .tab: return .closeTab; case .pane: return .closePane }
    }
    func renameAction(_ name: String) -> HerdrPaneMenuAction {
        if case .workspace = resource { return .renameWorkspace(name) }; return .renameTab(name)
    }
    func allows(_ action: HerdrPaneMenuAction) -> Bool {
        switch action {
        case .newTab, .switchWorkspace: return true
        case .splitRight, .splitDown: return canSplit
        case .renameWorkspace, .closeWorkspace: if case .workspace = resource { return true }; return false
        case .renameTab: return tabID != nil && !isWorkspace
        case .closeTab: if case .tab = resource { return true }; return false
        case .closePane: if case .pane = resource { return true }; return false
        }
    }
    private var isWorkspace: Bool { if case .workspace = resource { return true }; return false }
}

enum HerdrPaneMenuAction: Equatable, Sendable {
    case newTab, splitRight, splitDown, renameTab(String), renameWorkspace(String), closePane, closeTab, closeWorkspace, switchWorkspace(String)
    func command(target: HerdrPaneMenuTarget) -> String? {
        guard target.allows(self) else { return nil }
        let q = HerdrLaunch.quote
        switch self {
        case .newTab: return "tab create --workspace \(q(target.workspaceID)) --focus"
        case .splitRight: return target.paneID.map { "pane split \(q($0)) --direction right --focus" }
        case .splitDown: return target.paneID.map { "pane split \(q($0)) --direction down --focus" }
        case .renameTab(let name): return target.tabID.map { "tab rename \(q($0)) \(q(name))" }
        case .renameWorkspace(let name): return "workspace rename \(q(target.workspaceID)) \(q(name))"
        case .closePane: return target.paneID.map { "pane close \(q($0))" }
        case .closeTab: return target.tabID.map { "tab close \(q($0))" }
        case .closeWorkspace: return "workspace close \(q(target.workspaceID))"
        case .switchWorkspace(let id): return "workspace focus \(q(id))"
        }
    }
}

enum HerdrPaneMenuError: LocalizedError {
    case targetChanged, unconfirmed, invalidName
    var errorDescription: String? {
        switch self {
        case .targetChanged: return "原连接或操作对象已变化，请关闭菜单后重新打开。"
        case .unconfirmed: return "未确认操作结果。请关闭菜单并刷新工作区后检查，避免重复执行。"
        case .invalidName: return "请输入有效名称（最多 100 个字符）。"
        }
    }
}
