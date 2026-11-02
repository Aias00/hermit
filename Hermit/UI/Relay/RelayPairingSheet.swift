import CoreImage
import Foundation
import MoshpitKit
import RemoteForgeRelay
import SwiftUI
import UniformTypeIdentifiers

/// Secret invitation input stays in this transient sheet. Only the confirmed
/// public scope is shown; exchange happens after an explicit user action.
struct RelayPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPaired: (RelayCredential) -> Void
    @State private var input = ""
    @State private var invitation: RelayInvitation?
    @State private var error: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var fileImporter = false
    @State private var scanner = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if invitation == nil {
                    Section {
                        SecureField("粘贴配对链接", text: Binding(get: { input }, set: { value in
                            guard invitation == nil, value != input else { return }
                            input = value
                        }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(busy)
                            .focused($inputFocused)
                            .submitLabel(.done)
                            .onSubmit { parseText() }
                            .privacySensitive().accessibilityIdentifier("relay-invitation-input")
                        if let error {
                            Text(error).foregroundStyle(.orange).accessibilityIdentifier("relay-pairing-error")
                        }
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { input = value; parseText() }
                        }
                        .disabled(busy).accessibilityIdentifier("relay-paste-invitation")
                        Button("导入邀请文件或二维码图片", systemImage: "doc.badge.plus") { fileImporter = true }
                            .disabled(busy).accessibilityIdentifier("relay-import-invitation")
                        Button("扫描二维码", systemImage: "qrcode.viewfinder") { scanner = true }
                            .disabled(busy || !RelayQRScanner.isSupported)
                            .accessibilityIdentifier("relay-scan-invitation")
                    } header: { Text("配对邀请") } footer: {
                        Text("在目标电脑上生成 Relay 配对邀请。邀请五分钟内有效，只能使用一次；请勿公开链接或二维码。")
                    }
                }
                if let invitation {
                    Section("确认接入的设备") {
                        LabeledContent("中继", value: invitation.endpoint.url.absoluteString)
                            .accessibilityIdentifier("relay-confirm-server")
                        LabeledContent("设备", value: invitation.device)
                        LabeledContent("服务", value: invitation.service)
                        LabeledContent("有效至") { Text(invitation.expiresAt, style: .time) }
                        Button("更换邀请") { self.invitation = nil; input = ""; error = nil }
                            .disabled(busy)
                    }
                    if let error {
                        Text(error).foregroundStyle(.orange).accessibilityIdentifier("relay-pairing-error")
                    }
                }
            }
            .navigationTitle("配对 Relay").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { operation?.cancel(); dismiss() }.accessibilityIdentifier("relay-cancel-pairing")
                }
                if let invitation {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "正在配对…" : "确认配对") { pair(invitation) }
                            .disabled(busy).accessibilityIdentifier("relay-confirm-pairing")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("读取邀请") { parseText() }
                            .disabled(input.isEmpty || busy)
                            .accessibilityIdentifier("relay-parse-invitation")
                    }
                }
            }
            .interactiveDismissDisabled(busy)
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.json, .plainText, .image]) { result in
                importFile(result)
            }
            .appFullScreenCover(isPresented: $scanner) {
                RelayQRScanner { value in
                    scanner = false
                    input = value
                    parseText()
                } onCancel: { scanner = false }
            }
            .onDisappear { operation?.cancel() }
        }
    }

    private func parseText() {
        Log.ssh.notice("relay pairing: validating invitation")
        do {
            invitation = try RelayInvitation(uri: input.trimmingCharacters(in: .whitespacesAndNewlines),
                allowInsecureLoopback: RelayRuntimePolicy.allowsInsecureLoopback)
            inputFocused = false
            error = nil
        } catch {
            Log.ssh.notice("relay pairing: invitation rejected locally")
            invitation = nil
            self.error = RelayErrorMessage.message(error)
        }
    }
    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        operation?.cancel()
        busy = true
        error = nil
        operation = Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 5 * 1024 * 1024 else { throw RelayError.invalidInvitation }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try RelayInvitationImport.parse(data, allowInsecureLoopback: RelayRuntimePolicy.allowsInsecureLoopback)
                }.value
                try Task.checkCancellation()
                invitation = parsed
                input = ""
                error = nil
            } catch {
                if !Task.isCancelled { self.error = RelayErrorMessage.message(error) }
            }
            busy = false
        }
    }
    private func pair(_ invite: RelayInvitation) {
        busy = true
        error = nil
        operation = Task {
            do {
                let credential = try await RelayPairingClient.redeem(invite, name: "Hermit")
                try Task.checkCancellation()
                onPaired(credential)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = RelayErrorMessage.message(error) }
            }
            busy = false
        }
    }
}

/// QR decoding is entirely local; no image or invitation is uploaded.
enum RelayInvitationImport {
    static func parse(_ data: Data, allowInsecureLoopback: Bool = false) throws -> RelayInvitation {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") { return try RelayInvitation(json: data, allowInsecureLoopback: allowInsecureLoopback) }
            return try RelayInvitation(uri: trimmed, allowInsecureLoopback: allowInsecureLoopback)
        }
        guard data.count <= 5 * 1024 * 1024, let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                       options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            throw RelayError.invalidInvitation
        }
        let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        guard codes.count == 1, let uri = codes.first else { throw RelayError.invalidInvitation }
        return try RelayInvitation(uri: uri, allowInsecureLoopback: allowInsecureLoopback)
    }
}
