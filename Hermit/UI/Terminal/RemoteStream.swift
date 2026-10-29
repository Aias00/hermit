import AVFoundation
import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Playing a host video without downloading it

/// Feeds AVFoundation a host file straight from SFTP. Each byte range the
/// player (or a cover generator) asks for is read through the open file and
/// handed over in order as it lands, so playback starts on the first
/// megabyte, a seek jumps straight to the bytes it needs, and nothing is
/// fetched whole. The loading requests arrive on `queue`; reads run in their
/// own tasks, one per request, cancelled when AVFoundation drops it.
final class RemoteStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// A made-up scheme, so the requests come to the delegate instead of
    /// the network.
    static let scheme = "moshpit-stream"
    /// 64 KiB reads, sixteen in flight: a megabyte on the wire at a time —
    /// enough that a long round trip doesn't set the pace, little enough
    /// that a seek doesn't queue behind a backlog.
    static let chunk: UInt32 = 64 * 1024
    static let window = 16

    private let source: RemoteFileHandle
    private let url: URL
    private let contentType: String?
    private let queue = DispatchQueue(label: "com.cluas.moshpit.remote-stream")
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(source: RemoteFileHandle, name: String) {
        self.source = source
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "host"
        parts.path = "/" + name
        url = parts.url ?? URL(string: "\(Self.scheme)://host/video.mp4")!
        contentType = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Cancels every read and closes the file. Requests after this fail.
    func stop() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            stopped = true
            defer { running.removeAll() }
            return Array(running.values)
        }
        tasks.forEach { $0.cancel() }
        let source = source
        Task { await source.close() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if lock.withLock({ stopped }) { return false }
        let size = source.size
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(size)
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let start = UInt64(max(0, data.requestedOffset))
        let end = data.requestsAllDataToEndOfResource
            ? size : min(size, start + UInt64(max(0, data.requestedLength)))
        guard start < end else {
            request.finishLoading()
            return true
        }
        let key = ObjectIdentifier(request)
        let source = source
        let task = Task { [weak self] in
            var order = InOrderBytes()
            do {
                _ = try await WindowedRead.pull(
                    size: end - start, chunk: Self.chunk, window: Self.window,
                    read: { offset, length in try await source.read(from: start + offset, length: length) },
                    write: { offset, bytes in
                        try Task.checkCancellation()
                        let ready = order.take(offset, bytes)
                        if !ready.isEmpty { data.respond(with: Data(ready)) }
                    })
                try Task.checkCancellation()
                request.finishLoading()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { request.finishLoading(with: error) }
            }
            self?.forget(key)
        }
        lock.withLock { running[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        lock.withLock { running.removeValue(forKey: ObjectIdentifier(request)) }?.cancel()
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.withLock { _ = running.removeValue(forKey: key) }
    }
}

// MARK: - The player

/// Plays a host video in the system player, streamed (`RemoteStreamLoader`).
@MainActor
enum RemoteVideoPlayer {
    /// Puts the player sheet over whatever is on screen and starts it.
    /// `onClose` runs once it has gone (its close button, or a swipe down);
    /// the file is closed with it. `files` is how its share button fetches
    /// the whole file.
    static func present(_ entry: RemoteFileEntry, source: RemoteFileHandle, files: RemoteFileAccess,
                        onClose: @escaping @MainActor () -> Void) {
        guard let top = topController() else {
            Task { await source.close() }
            onClose()
            return
        }
        top.present(RemoteVideoController(entry: entry, source: source, files: files, onClose: onClose),
                    animated: true)
    }

    /// Whatever is frontmost — the terminal, or a sheet over it — for the
    /// controllers presented from outside SwiftUI.
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// The player sheet: the system player, embedded under a bar of our own —
/// close, the file's name, share. AVPlayerViewController presented by itself
/// takes no extra buttons and says nothing when it closes; owning the sheet
/// gives share a place and makes the close a plain `viewDidDisappear`.
private final class RemoteVideoController: UIViewController {
    private let entry: RemoteFileEntry
    private let files: RemoteFileAccess
    private let loader: RemoteStreamLoader
    private let onClose: @MainActor () -> Void
    private let playerController = AVPlayerViewController()
    private let shareButton = UIButton(type: .system)
    /// The whole-file download a share waits on.
    private var shareTask: Task<Void, Never>?
    private var started = false
    private var closed = false

    init(entry: RemoteFileEntry, source: RemoteFileHandle, files: RemoteFileAccess,
         onClose: @escaping @MainActor () -> Void) {
        self.entry = entry
        self.files = files
        self.loader = RemoteStreamLoader(source: source, name: entry.name)
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        // A card, like the folder sheet: a swipe down closes it.
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.detents = [.large()]
        sheetPresentationController?.prefersGrabberVisible = true
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Ink.modalBG)
        playerController.player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
        // Picture in picture would outlive the sheet, and with it the close
        // that stops the stream.
        playerController.allowsPictureInPicturePlayback = false
        let bar = makeBar()
        addChild(playerController)
        let player = playerController.view!
        player.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        view.addSubview(player)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 44),
            player.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            player.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            player.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerController.didMove(toParent: self)
        // Sound even with the ring switch on silent, like any video player.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        playerController.player?.play()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A share sheet over this, or a swipe let go of halfway, is not a
        // close; being dismissed (alone or with what presented it) is.
        guard !closed, isBeingDismissed || presentingViewController?.isBeingDismissed == true
                || presentingViewController == nil else { return }
        closed = true
        shareTask?.cancel()
        playerController.player?.pause()
        loader.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onClose()
    }

    private func makeBar() -> UIView {
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
                       for: .normal)
        close.tintColor = UIColor(Ink.primary)
        close.accessibilityLabel = String(localized: "Close")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let title = UILabel()
        title.text = entry.name
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = UIColor(Ink.primary)
        title.textAlignment = .center
        title.lineBreakMode = .byTruncatingMiddle

        setShareProgress(nil)
        shareButton.accessibilityLabel = String(localized: "Share")
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .touchUpInside)

        for button in [close, shareButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let bar = UIStackView(arrangedSubviews: [close, title, shareButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return bar
    }

    /// The share button's face: its icon, or the download's progress while
    /// a share waits for the whole file.
    private func setShareProgress(_ fraction: Double?) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = fraction == nil ? UIColor(Ink.primary) : UIColor(Ink.accent)
        if let fraction {
            config.showsActivityIndicator = true
            config.title = "\(Int(fraction * 100))%"
            config.imagePadding = 6
        } else {
            config.image = UIImage(systemName: "square.and.arrow.up",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        }
        shareButton.configuration = config
    }

    /// Fetch the whole file (or reuse the copy a preview already made), then
    /// the share sheet, pointing at the button.
    private func share() {
        guard shareTask == nil else { return }
        if let url = RemotePreviewCache.cached(entry, scope: files.scope) {
            presentShare(url)
            return
        }
        setShareProgress(0)
        let entry = entry, files = files
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.shareTask != nil else { return }
                self.setShareProgress(fraction)
            }
        }
        shareTask = Task { [weak self] in
            do {
                let url = try await RemotePreviewCache.fetch(entry, files: files, progress: progress)
                guard let self, !Task.isCancelled else { return }
                self.shareTask = nil
                self.setShareProgress(nil)
                self.presentShare(url)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.shareTask = nil
                self.setShareProgress(nil)
                let alert = UIAlertController(title: String(localized: "CAN'T OPEN"),
                                              message: RemotePreviewCache.message(for: error),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
                self.present(alert, animated: true)
            }
        }
    }

    private func presentShare(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = shareButton
        present(controller, animated: true)
    }
}

// MARK: - Sharing

/// The system share sheet for a fetched host file — Messages, WeChat,
/// AirDrop, Save to Files. The copy keeps the host file's name, so that is
/// the name the other side gets.
@MainActor
enum RemoteShareSheet {
    static func present(_ url: URL) {
        guard let top = RemoteVideoPlayer.topController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            // iPad: no tile to point at from here, so centred, arrowless.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

// MARK: - Covers

/// A video's poster for the folder grid: a frame from near the start, and
/// the running time, read through the same stream — a few hundred
/// kilobytes, not the file.
enum RemoteVideoCover {
    struct Cover {
        let image: UIImage?
        let seconds: Double?
    }

    static func make(_ entry: RemoteFileEntry, files: RemoteFileAccess) async -> Cover? {
        guard let source = try? await files.channel().openRemoteFile(entry.path) else { return nil }
        let loader = RemoteStreamLoader(source: source, name: entry.name)
        defer { loader.stop() }
        let asset = loader.makeAsset()
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // A second in (or a tenth of a short clip): the very first frame is
        // often a black fade-in.
        let at = CMTime(seconds: min(1, (seconds ?? 0) / 10), preferredTimescale: 600)
        let image = try? await generator.image(at: at).image
        guard image != nil || seconds != nil else { return nil }
        return Cover(image: image.map(UIImage.init(cgImage:)), seconds: seconds)
    }

    /// "0:42", "12:07", "1:02:33".
    static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
