import SwiftUI
import UIKit
import UserNotifications

struct AgentNotificationSettingsSection: View {
    let onSetup: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var message: String?
    @State private var showInfo = false

    var body: some View {
        @Bindable var settings = settings
        FormGroup(title: "NOTIFICATIONS", footer: "任务状态优先更新锁屏实时活动，关键事件只提醒一次；实时活动不可用时使用普通通知。长期后台仍需远端推送，普通推送会保留通知兜底。") {
            ToggleRow(label: "Notifications", subtitle: "任务完成或需要你处理时提醒",
                      identifier: "settings-agent-notifications", isOn: $settings.notificationsEnabled)
            ToggleRow(label: "Alert sound", subtitle: "Play a sound when the agent needs you",
                      isOn: $settings.attentionSoundEnabled).disabled(!settings.notificationsEnabled)
            ToggleRow(label: "Show detail on lock screen", subtitle: "关闭后仅显示任务状态和位置",
                      isOn: $settings.lockScreenDetailEnabled)
                .disabled(!settings.notificationsEnabled && !settings.liveActivityEnabled)
            LabeledContent("系统通知权限", value: permissionLabel)
                .accessibilityIdentifier("settings-notification-permission")
            if authorization == .denied {
                Button("前往系统设置开启通知") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("发送测试通知") { Task { await testNotification() } }
                .disabled(!settings.notificationsEnabled)
                .accessibilityIdentifier("settings-notification-test")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-notification-result")
            }
            if RemotePushCapability.environment == nil {
                Text(RemotePushCapability.unavailableMessage)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-push-unavailable")
            } else {
                ChevronRow(label: "Set up this host", subtitle: "配置离线推送", action: onSetup)
            }
            ChevronRow(label: "How notifications work") { showInfo = true }
        }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshPermission() } }
        }
        .onChange(of: settings.notificationsEnabled) { _, enabled in
            if enabled { Task { await requestPermission() } }
        }
        .appSheet(isPresented: $showInfo) { NotificationInfoView() }
    }

    private var permissionLabel: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return String(localized: "已允许")
        case .denied: return String(localized: "未允许")
        case .notDetermined: return String(localized: "尚未授权")
        @unknown default: return String(localized: "未知")
        }
    }

    private func refreshPermission() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch { message = error.localizedDescription }
        await refreshPermission()
    }

    private func testNotification() async {
        await requestPermission()
        guard authorization != .denied else {
            message = String(localized: "请在系统设置中允许 Hermit 通知。")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Hermit"
        content.body = String(localized: "本地通知正常。HERDR 任务等待输入或完成时会在这里提醒。")
        if settings.attentionSoundEnabled { content.sound = .default }
        do {
            try await UNUserNotificationCenter.current().add(.init(
                identifier: "hermit.notification-test", content: content, trigger: nil))
            message = String(localized: "测试通知已提交。系统专注模式和通知设置可能影响展示。")
        } catch { message = error.localizedDescription }
    }
}
