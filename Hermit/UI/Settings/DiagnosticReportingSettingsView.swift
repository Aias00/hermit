import SwiftUI

struct DiagnosticReportingSettingsView: View {
    @State private var reporter = DiagnosticReporter.shared
    @State private var showManual = false

    var body: some View {
        Form {
            Section {
                LabeledContent("自动上报", value: reporter.isEnabled ? "已开启" : "未开启")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(reporter.isEnabled ? "自动上报：已开启" : "自动上报：未开启")
                    .accessibilityIdentifier("diagnostics-enabled-state")
                if let configuration = reporter.configuration {
                    LabeledContent("接收端", value: configuration.endpoint.host ?? "")
                }
                if let last = reporter.lastSuccess {
                    LabeledContent("最近成功", value: last.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("diagnostics-last-success")
                }
                if let status = reporter.statusMessage { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("只上报连接阶段、错误分类、网络恢复、App 和 iOS 版本。终端内容、输入的命令、主机地址、密码和 Token 不进入诊断批次。")
            }
            Section {
                if let text = Bundle.main.object(forInfoDictionaryKey: "HermitDiagnosticsSetupURL") as? String,
                   let url = URL(string: text), url.scheme == "https" {
                    Link("配置我的接收端", destination: url)
                        .accessibilityIdentifier("diagnostics-open-setup")
                }
                Button("手动配置接收端") { showManual = true }.accessibilityIdentifier("diagnostics-manual-setup")
                if reporter.configuration != nil {
                    Button(reporter.isEnabled ? "立即上报" : "开启自动上报") {
                        Task {
                            if reporter.isEnabled { await reporter.flush(force: true) }
                            else if let configuration = reporter.configuration { await reporter.enable(configuration) }
                        }
                    }.disabled(reporter.isUploading)
                }
                if reporter.isEnabled {
                    Button("停止自动上报") { Task { await reporter.disable() } }
                }
                Button("清除记录并解除上报绑定", role: .destructive) { Task { await reporter.forget() } }
                    .accessibilityIdentifier("diagnostics-forget")
            } footer: {
                Text("前台每 5 分钟检查一次，进入后台时提交已有批次。后台传输由 iOS 调度；断网后保留记录并退避重试。每日日志内容最多上报 1 MB，本地最多保留约 3 MB、7 天。清除不会删除接收端已经收到的记录。")
            }
        }
        .navigationTitle("自动诊断上报")
        .sheet(isPresented: $showManual) { DiagnosticReportingManualSetup() }
        .task { if reporter.isEnabled { await reporter.flush() } }
    }
}

struct DiagnosticReportingConsentView: View {
    let configuration: DiagnosticReceiverConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("诊断接收端") {
                    Text(configuration.endpoint.absoluteString).textSelection(.enabled)
                    Text("请确认这是你自己的接收端。设备凭据仅保存于本机钥匙串。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("启用后会定期上报 Hermit 的结构化连接与恢复记录，以及 App、iOS 版本。不会上传终端正文、命令、主机地址或 SSH 凭据。")
                    Button("启用自动诊断上报") {
                        busy = true
                        Task {
                            await DiagnosticReporter.shared.enable(configuration)
                            busy = false
                            if DiagnosticReporter.shared.isEnabled { dismiss() }
                        }
                    }.disabled(busy).accessibilityIdentifier("diagnostics-confirm-enable")
                    if let status = DiagnosticReporter.shared.statusMessage { Text(status).font(.footnote) }
                }
            }.navigationTitle("配置诊断上报")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct DiagnosticReportingManualSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var token = ""
    @State private var proposed: DiagnosticReceiverConfiguration?
    @State private var invalid = false
    var body: some View {
        if let proposed {
            DiagnosticReportingConsentView(configuration: proposed)
        } else {
          NavigationStack {
            Form {
                TextField("HTTPS 接收地址", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("diagnostics-endpoint")
                SecureField("设备上报凭据", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // This is an app-managed device token, not a website login.
                    // Prevent iOS's save-password sheet from intercepting setup.
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("diagnostics-device-token")
                Button("检查配置") {
                    if let url = URL(string: endpoint) { proposed = try? DiagnosticReceiverConfiguration(endpoint: url, token: token) }
                    invalid = proposed == nil
                }.accessibilityIdentifier("diagnostics-check-configuration")
                if invalid { Text("请输入有效的 HTTPS 接收地址和设备凭据。地址中不能包含用户名、密码或查询参数。") }
                Text("接收端须支持 Hermit 诊断格式。也可以从接收端的受保护配对页面直接打开 App。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("手动配置")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("diagnostics-manual-cancel") } }
          }
        }
    }
}
