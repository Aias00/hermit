import SwiftUI

struct AgentNotificationSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var showInfo = false

    var body: some View {
        @Bindable var settings = settings
        FormGroup(title: "锁屏任务", footer: "任务完成、等待处理仅更新锁屏实时活动，不发送普通通知或声音。卡片关闭或被移除时也不会补发通知。") {
            ToggleRow(label: "Show detail on lock screen", subtitle: "关闭后仅显示任务状态和位置",
                      isOn: $settings.lockScreenDetailEnabled)
                .disabled(!settings.liveActivityEnabled)
            ChevronRow(label: "锁屏任务如何工作") { showInfo = true }
        }
        .appSheet(isPresented: $showInfo) { NotificationInfoView() }
    }
}
