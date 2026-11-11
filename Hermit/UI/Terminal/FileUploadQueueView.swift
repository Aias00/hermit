import SwiftUI
import UIKit

struct FileUploadQueueView: View {
    let queue: FileUploadQueue
    let canRetry: Bool
    let onRetry: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copiedID: UUID?

    private func isUploading(_ state: FileUploadQueue.State) -> Bool {
        if case .uploading = state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(queue.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(item.name, systemImage: "doc")
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            if let size = item.source.byteCount {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            switch item.state {
                            case .queued:
                                Text("Waiting to upload").foregroundStyle(.secondary)
                            case .uploading(let progress):
                                ProgressView(value: progress)
                                Text("上传中 · \(Int(progress * 100))%")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            case .uploaded(let path):
                                Label("Uploaded · added to draft", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(verbatim: path).font(.caption.monospaced())
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                Button {
                                    UIPasteboard.general.string = path
                                    copiedID = item.id
                                } label: {
                                    Label(copiedID == item.id ? String(localized: "Copied") : String(localized: "Copy path"),
                                          systemImage: copiedID == item.id ? "checkmark" : "doc.on.doc")
                                }.accessibilityIdentifier("file-upload-copy-\(item.name)")
                            case .failed(let message):
                                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            case .cancelled:
                                Text("Upload cancelled").foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                if item.state.canRetry {
                                    Button("重试此文件") { onRetry(item.id) }
                                        .disabled(!canRetry || queue.isRunning)
                                        .frame(minHeight: 44)
                                        .accessibilityIdentifier("file-upload-retry-" + item.id.uuidString)
                                }
                                if item.state == .queued || isUploading(item.state) {
                                    Button("取消此文件") { queue.cancel(itemID: item.id) }
                                        .frame(minHeight: 44)
                                        .accessibilityIdentifier("file-upload-cancel-" + item.id.uuidString)
                                }
                                Button("移除记录", role: .destructive) { queue.remove(itemID: item.id) }
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("file-upload-remove-" + item.id.uuidString)
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 6)
                    }
                } footer: {
                    Text("Completed paths stay in the original pane's draft. Upload history is kept until cleared, disconnected, or the app closes. Removing a record does not delete the remote file or draft path. Interrupted uploads resume from where they stopped when retried.")
                }
                Section {
                    if queue.isRunning {
                        Button("Cancel uploads", role: .destructive) { queue.cancel() }
                            .accessibilityIdentifier("file-upload-cancel")
                    } else {
                        if queue.hasRetryableItems {
                            Button("Retry unfinished files") { onRetry(nil) }
                                .disabled(!canRetry)
                                .accessibilityIdentifier("file-upload-retry")
                        }
                        Button("Clear upload history", role: .destructive) {
                            queue.clear()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("File uploads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
