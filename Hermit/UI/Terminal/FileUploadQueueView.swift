import SwiftUI
import UIKit

struct FileUploadQueueView: View {
    let queue: FileUploadQueue
    let canRetry: Bool
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(queue.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(item.name, systemImage: "doc")
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            switch item.state {
                            case .queued:
                                Text("Waiting to upload").foregroundStyle(.secondary)
                            case .uploading(let progress):
                                ProgressView(value: progress)
                                Text("Uploading…").foregroundStyle(.secondary)
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
                        }
                        .font(.subheadline)
                        .padding(.vertical, 6)
                    }
                } footer: {
                    Text("已完成的路径保留在原窗格的草稿中。上传记录会保留到清除、断开连接或退出 App。")
                }
                Section {
                    if queue.isRunning {
                        Button("Cancel uploads", role: .destructive) { queue.cancel() }
                            .accessibilityIdentifier("file-upload-cancel")
                    } else {
                        if queue.hasRetryableItems {
                            Button("Retry unfinished files", action: onRetry)
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
