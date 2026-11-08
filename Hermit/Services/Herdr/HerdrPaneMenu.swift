import Foundation

struct HerdrPaneMenuTarget: Equatable, Sendable {
    let generation: UUID
    let paneID: String
    let tabID: String
    let workspaceID: String
    let terminalID: String?
    let workspaceName: String
    let tabName: String
    let paneIndex: Int
    var title: String { "\(workspaceName) · \(tabName) · \(paneIndex + 1)" }
}

enum HerdrPaneMenuAction: Equatable, Sendable {
    case newTab, splitRight, splitDown, renameTab(String), closePane, switchWorkspace(String)
    func command(target: HerdrPaneMenuTarget) -> String {
        let q = HerdrLaunch.quote
        switch self {
        case .newTab: return "tab create --workspace \(q(target.workspaceID)) --focus"
        case .splitRight: return "pane split \(q(target.paneID)) --direction right --focus"
        case .splitDown: return "pane split \(q(target.paneID)) --direction down --focus"
        case .renameTab(let name): return "tab rename \(q(target.tabID)) \(q(name))"
        case .closePane: return "pane close \(q(target.paneID))"
        case .switchWorkspace(let id): return "workspace focus \(q(id))"
        }
    }
}

enum HerdrPaneMenuError: LocalizedError {
    case targetChanged, unconfirmed, invalidName
    var errorDescription: String? {
        switch self {
        case .targetChanged: return "原连接或窗格已变化，请关闭菜单后重新双击。"
        case .unconfirmed: return "未确认操作结果。请关闭菜单并刷新工作区后检查，避免重复执行。"
        case .invalidName: return "请输入有效名称（最多 100 个字符）。"
        }
    }
}
