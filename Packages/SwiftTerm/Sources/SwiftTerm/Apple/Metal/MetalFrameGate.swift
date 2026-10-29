import Foundation

/// Coalesces draws while the previous frame is using the renderer's buffers.
/// Claiming a frame and recording a skipped draw must use the same lock: a
/// separate semaphore wait followed by a pending flag can lose a request if
/// the GPU completes between those two operations.
final class MetalFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var pendingRedraw = false

    func beginFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else {
            pendingRedraw = true
            return false
        }
        inFlight = true
        return true
    }

    /// Returns whether a draw skipped during this frame needs another pass.
    func completeFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        let redraw = pendingRedraw
        pendingRedraw = false
        return redraw
    }

    /// No command buffer will call us back. Keep any redraw request for the
    /// next successful frame, but do not spin drawing an unavailable surface
    /// (for example while the view is hidden or the app is in the background).
    func abandonFrame(needsRedraw: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        pendingRedraw = pendingRedraw || needsRedraw
    }
}
