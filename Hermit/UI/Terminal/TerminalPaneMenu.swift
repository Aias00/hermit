import SwiftUI
import UIKit

/// A native anchored popover, including on iPhone. It does not dismiss the
/// keyboard, resize the terminal or take first responder just to show actions.
@MainActor
final class TerminalPaneMenuPresenter: NSObject, UIPopoverPresentationControllerDelegate {
    private weak var presented: UIViewController?

    @discardableResult
    func present(from source: UIView, at point: CGPoint, target: HerdrPaneMenuTarget,
                 workspaces: [SessionInfo], perform: @escaping (HerdrPaneMenuAction) async throws -> Void) -> Bool {
        if presented != nil { return true }
        guard source.window != nil else { return false }
        var responder: UIResponder? = source
        var parent: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController { parent = controller; break }
            responder = current.next
        }
        guard let parent, parent.presentedViewController == nil, !parent.isBeingDismissed else { return false }
        let content = TerminalPaneMenu(target: target, workspaces: workspaces, perform: perform,
            close: { [weak self] in self?.dismiss() })
        let controller = UIHostingController(rootView: content)
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = CGSize(width: 288, height: 380)
        guard let popover = controller.popoverPresentationController else { return false }
        popover.sourceView = source
        popover.sourceRect = CGRect(x: min(max(0, point.x), source.bounds.width),
                                    y: min(max(0, point.y), source.bounds.height), width: 1, height: 1)
        popover.permittedArrowDirections = [.up, .down]
        popover.delegate = self
        presented = controller
        parent.present(controller, animated: true)
        return true
    }

    func dismiss() { presented?.dismiss(animated: true); presented = nil }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { presented = nil }
}

private struct TerminalPaneMenu: View {
    enum Page { case actions, rename, confirmClose }
    let target: HerdrPaneMenuTarget
    let workspaces: [SessionInfo]
    let perform: (HerdrPaneMenuAction) async throws -> Void
    let close: () -> Void
    @State private var page: Page = .actions
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HERDR 操作").font(.headline)
                        Text(verbatim: target.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .accessibilityLabel("关闭菜单").accessibilityIdentifier("pane-menu-dismiss")
                }.padding(10)
                Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.orange).padding(12)
                    Button("关闭并检查工作区", action: close).padding(12)
                } else {
                    switch page {
                    case .actions:
                        action("新建标签页", icon: "plus.rectangle.on.rectangle", id: "new-tab") { run(.newTab) }
                        action("左右分屏", icon: "rectangle.split.2x1", id: "split-right") { run(.splitRight) }
                        action("上下分屏", icon: "rectangle.split.1x2", id: "split-down") { run(.splitDown) }
                        if workspaces.count > 1 {
                            Menu {
                                ForEach(workspaces) { workspace in
                                    Button(workspace.name) { run(.switchWorkspace(workspace.id)) }
                                        .disabled(workspace.id == target.workspaceID)
                                }
                            } label: { row("切换工作区", icon: "rectangle.stack") }
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("pane-menu-workspaces")
                        }
                        action("重命名标签页", icon: "pencil", id: "rename") { name = target.tabName; page = .rename }
                        Divider()
                        action("关闭窗格…", icon: "xmark.rectangle", id: "close-pane", destructive: true) { page = .confirmClose }
                    case .rename:
                        Text("标签页名称").font(.subheadline).padding(.horizontal, 12).padding(.top, 8)
                        TextField("名称", text: $name).textFieldStyle(.roundedBorder).padding(12)
                            .focused($editingName).accessibilityIdentifier("pane-menu-name")
                        action("保存名称", icon: "checkmark", id: "save-name") { editingName = false; run(.renameTab(name)) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
                        action("返回", icon: "chevron.left", id: "back") { editingName = false; page = .actions }
                    case .confirmClose:
                        Text("关闭此窗格？").font(.headline).padding(12)
                        Text("只关闭上方标明的窗格，窗格内运行的远端任务可能会被结束。")
                            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12)
                        action("确认关闭窗格", icon: "xmark.rectangle", id: "confirm-close", destructive: true) { run(.closePane) }
                        action("取消", icon: "chevron.left", id: "cancel-close") { page = .actions }
                    }
                }
                if busy { ProgressView("正在处理…").padding(12) }
            }
            .disabled(busy)
            .padding(.bottom, 6)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-pane-menu")
    }

    private func action(_ title: String, icon: String, id: String, destructive: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) { row(title, icon: icon) }
            .foregroundStyle(destructive ? Color.red : .primary)
            .accessibilityIdentifier("pane-menu-\(id)")
    }
    private func row(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 15))
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(Rectangle()).padding(.horizontal, 12)
    }
    private func run(_ action: HerdrPaneMenuAction) {
        guard !busy else { return }
        busy = true
        Task {
            do { try await perform(action); close() }
            catch { self.error = (error as? HerdrPaneMenuError)?.localizedDescription ?? "操作未确认，请关闭菜单后检查工作区。" }
            busy = false
        }
    }
}
