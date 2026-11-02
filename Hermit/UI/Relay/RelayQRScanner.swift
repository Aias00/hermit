import AVFoundation
import SwiftUI
import VisionKit

struct RelayQRScanner: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void
    @State private var ready = false
    @State private var failure: String?
    static var isSupported: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                if ready { CameraScanner(onCode: onCode, onFailure: { failure = "扫描未能启动，请重试或导入邀请文件。"; ready = false }) }
                else if let failure { ContentUnavailableView("无法使用相机", systemImage: "camera", description: Text(failure)) }
                else { ProgressView("准备扫描…") }
            }
            .navigationTitle("扫描 Relay 邀请").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) } }
        }
        .task {
            guard Self.isSupported else { failure = "可以返回后粘贴邀请链接或导入二维码图片。"; return }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard !Task.isCancelled else { return }
            guard allowed, DataScannerViewController.isAvailable else {
                failure = "请在系统设置中允许相机权限，或使用文件导入。"; return
            }
            ready = true
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.start(scanner)
    }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stop()
        scanner.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private var startTask: Task<Void, Never>?
        private var delivered = false
        let onCode: (String) -> Void
        let onFailure: () -> Void
        init(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }
        func start(_ scanner: DataScannerViewController) {
            guard startTask == nil else { return }
            startTask = Task { @MainActor [weak scanner] in
                do {
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard let scanner else { return }
                        if scanner.viewIfLoaded?.window != nil { try scanner.startScanning(); return }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    onFailure()
                } catch { if !Task.isCancelled { onFailure() } }
            }
        }
        func stop() { startTask?.cancel(); startTask = nil }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            stop()
            onFailure()
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    delivered = true
                    scanner.stopScanning()
                    onCode(value)
                    break
                }
            }
        }
    }
}
