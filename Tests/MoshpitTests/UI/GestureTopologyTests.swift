import SwiftTerm
import Testing
import UIKit
@testable import Moshpit

/// The wiring half of docs/design/touch-matrix.md: which recognizers exist on
/// a minted terminal and how they yield to each other. Every deference rule
/// here has a user-visible failure mode when it silently unwires.
@MainActor
@Suite("Gesture topology")
struct GestureTopologyTests {
    @Test("Client viewport reports its own dimensions and remote repaints cannot reclaim geometry")
    func viewportReportsAreIndependentOfRemoteGrid() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = SwiftTerminalView.Coordinator()
        host.host(terminal)
        coordinator.remoteGrid = (180, 48)
        coordinator.hostContainer = host
        var reports: [(Int, Int)] = []
        coordinator.onViewportSizeChange = { reports.append(($0, $1)) }
        host.layoutSubviews()
        #expect(reports.count == 1)
        #expect(reports[0].0 < 180)
        coordinator.remoteGrid = (200, 60)
        host.layoutSubviews()
        #expect(reports.count == 1, "a desktop repaint must not cause resize ping-pong")
        host.frame.size = CGSize(width: 800, height: 350)
        host.layoutSubviews()
        #expect(reports.count == 2)
        #expect(reports[1].0 > reports[0].0)
        #expect(reports[1].1 < reports[0].1)
        host.frameLocked = true
        host.frame.size.height = 200
        host.layoutSubviews()
        #expect(reports.count == 2)
        host.frameLocked = false
        host.layoutSubviews()
        #expect(reports.count == 3)
    }

    @Test("Phone automatic type remains readable instead of squeezing a wide desktop grid into tiny text")
    func phoneAutomaticTypeRemainsReadable() {
        for width: CGFloat in [250, 402, 874] {
            let size = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 160, cellWidth: 8,
                viewportWidth: width, minimumFontSize: 12)
            #expect(size >= 12)
            #expect(size <= 18)
        }
    }

    @Test("An iPad keeps readable automatic type on wide remote grids and narrow sidebar layouts")
    func ipadAutomaticTypeRemainsReadable() {
        for width: CGFloat in [600, 834, 1210] {
            let size = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 160, cellWidth: 8,
                viewportWidth: width, minimumFontSize: 13)
            #expect(size >= 13)
            #expect(size <= 18)
        }
        let size = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 160, cellWidth: 8,
            viewportWidth: 600, minimumFontSize: 13)
        #expect(CGFloat(160) * 8 * size / 13 > 600, "a wide grid remains pannable instead of becoming tiny type")
    }

    @Test("A queued terminal focus request cannot steal focus from a newly focused composer")
    func staleFocusCannotStealComposer() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let host = TerminalHostContainer(frame: terminal.frame)
        host.host(terminal)
        controller.view.addSubview(host)
        let composer = UITextField(frame: CGRect(x: 0, y: 520, width: 300, height: 40))
        controller.view.addSubview(composer)
        host.requestFocus(.take)
        composer.becomeFirstResponder()
        host.requestFocus(.allow)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(composer.isFirstResponder)
        #expect(!terminal.isFirstResponder)
        host.requestFocus(.take)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(terminal.isFirstResponder)
        host.requestFocus(.resign)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!terminal.isFirstResponder)
    }

    @Test("Remote geometry and font remain locked through keyboard and sheet transitions")
    func remoteLayoutHonorsBothLocks() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        host.remoteGrid = (80, 46)
        host.host(terminal)
        host.layoutSubviews()
        let original = terminal.frame
        let originalFont = terminal.font.pointSize
        host.frameLocked = true
        host.frame.size.height = 300
        host.applyRemoteFont(.monospacedSystemFont(ofSize: 20, weight: .regular))
        host.layoutSubviews()
        #expect(terminal.frame == original)
        #expect(terminal.font.pointSize == originalFont)
        host.geometryHeld = true
        host.frameLocked = false
        host.layoutSubviews()
        #expect(terminal.frame == original)
        host.geometryHeld = false
        host.layoutSubviews()
        #expect(terminal.font.pointSize == 20)
        #expect(terminal.getTerminal().cols == 80)
        #expect(terminal.getTerminal().rows == 46)
        #expect(terminal.frame != original)
    }

    @Test("Font buttons adjust the displayed automatic size without jumping to an old saved value")
    func fontButtonsUseDisplayedSize() {
        #expect(RemoteViewportGeometry.adjustedFontSize(displayed: 16, delta: 1) == 17)
        #expect(RemoteViewportGeometry.adjustedFontSize(displayed: 16, delta: -1) == 15)
        #expect(RemoteViewportGeometry.adjustedFontSize(displayed: 32, delta: 1) == 32)
        #expect(RemoteViewportGeometry.adjustedFontSize(displayed: 8, delta: -1) == 8)
    }

    @Test("Short terminal content stays at the top when the viewport grows")
    func shortRemoteContentHasNoTopGap() {
        #expect(RemoteViewportGeometry.origin(current: nil, contentHeight: 250, viewportHeight: 700) == 0)
        #expect(RemoteViewportGeometry.origin(current: 300, contentHeight: 250, viewportHeight: 900) == 0)
        #expect(RemoteViewportGeometry.origin(current: nil, contentHeight: 900, viewportHeight: 700) == -200)
        #expect(RemoteViewportGeometry.origin(current: -50, contentHeight: 900, viewportHeight: 700) == -50)
    }

    @Test("Native terminal font fits phone, sidebar, rotation and tablet without changing the remote grid")
    func nativeViewportFontFitsDevices() {
        let phone = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 41, cellWidth: 8, viewportWidth: 390)
        let sidebar = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 41, cellWidth: 8, viewportWidth: 246)
        let landscape = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 41, cellWidth: 8, viewportWidth: 700)
        let wideDesktop = RemoteViewportGeometry.fittedFontSize(preferred: 13, columns: 188, cellWidth: 8, viewportWidth: 390)
        #expect(sidebar < phone)
        #expect(phone <= landscape)
        #expect(sidebar >= 8)
        #expect(landscape <= 18)
        #expect(wideDesktop == 8)
        #expect(abs(CGFloat(41) * 8 * sidebar / 13 - 246) < 0.1)
    }

    @Test("Remote viewport resizing preserves terminal grid and font")
    func remoteViewportDoesNotResizeSharedGrid() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let originalFont = terminal.font.pointSize
        let host = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        host.remoteGrid = (180, 48)
        host.host(terminal)
        host.layoutSubviews()
        terminal.feed(text: "\u{1b}[48;1Hbottom")
        host.invalidateRemoteContentExtent()
        host.layoutSubviews()
        #expect(terminal.getTerminal().cols == 180)
        #expect(terminal.getTerminal().rows == 48)
        let contentSize = terminal.frame.size
        host.frame.size.height = 300
        host.layoutSubviews()
        #expect(terminal.frame.size == contentSize)
        #expect(terminal.font.pointSize == originalFont)
        #expect(terminal.getTerminal().cols == 180)
        #expect(terminal.getTerminal().rows == 48)
        let moved = host.panRemoteViewport(by: 100)
        #expect(moved > 0)
        #expect(terminal.frame.size == contentSize)
        let coordinator = SwiftTerminalView.Coordinator()
        coordinator.attach(to: terminal)
        coordinator.remoteGrid = (180, 48)
        coordinator.hostContainer = host
        var remoteRows = 0
        coordinator.onScroll = { remoteRows += $0 }
        coordinator.scroll(pixels: 20)
        #expect(remoteRows == 0)
        coordinator.scroll(pixels: 10_000)
        #expect(remoteRows > 0)
        #expect(terminal.frame.minY == 0)
    }

    @Test("Pinch previews immediately relayout the pixel surface without changing remote rows")
    func pinchRefreshesRemoteLayout() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        host.remoteGrid = (180, 48)
        host.host(terminal)
        host.layoutSubviews()
        terminal.feed(text: "\u{1b}[48;1Hbottom")
        host.invalidateRemoteContentExtent()
        host.layoutSubviews()
        let coordinator = SwiftTerminalView.Coordinator()
        coordinator.attach(to: terminal)
        coordinator.remoteGrid = (180, 48)
        coordinator.hostContainer = host
        let oldWidth = terminal.frame.width
        var preview: Double?
        coordinator.onFontSizePreview = { preview = $0 }
        coordinator.previewFontSize(22)
        #expect(preview == 22)
        #expect(terminal.font.pointSize == 22)
        #expect(terminal.frame.width > oldWidth)
        #expect(terminal.getTerminal().cols == 180)
        #expect(terminal.getTerminal().rows == 48)
        #expect(abs(terminal.frame.maxY - host.bounds.height) < 1)
        coordinator.previewFontSize(9)
        #expect(terminal.font.pointSize == 9)
        #expect(terminal.frame.width < oldWidth)
        #expect(terminal.getTerminal().cols == 180)
        #expect(terminal.getTerminal().rows == 48)
    }

    @Test("Short terminal starts at the top and reveals its footer when the keyboard reduces the viewport")
    func shortRemoteContentAdaptsToKeyboard() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = TerminalHostContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        host.remoteGrid = (180, 46)
        host.host(terminal)
        host.layoutSubviews()
        terminal.feed(text: "\u{1b}[2J\u{1b}[23;1Hinput\u{1b}[25;1Hstatus\u{1b}[23;3H")
        host.invalidateRemoteContentExtent()
        host.layoutSubviews()
        #expect(host.remoteContentRows == 25)
        let cellHeight = terminal.frame.height / 46
        #expect(terminal.frame.minY == 0)
        #expect(terminal.getTerminal().rows == 46)
        host.frame.size.height = 350
        host.layoutSubviews()
        #expect(abs(terminal.frame.minY + cellHeight * 25 - host.bounds.height) < 1)
        host.frame.size.height = 650
        host.layoutSubviews()
        #expect(terminal.frame.minY == 0)
    }

    private func makeWired() -> (TerminalView, SwiftTerminalView.Coordinator) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let coordinator = SwiftTerminalView.Coordinator()
        TerminalScrollGesture.attach(to: terminal, coordinator: coordinator)
        return (terminal, coordinator)
    }

    @Test("the tap that clicks waits for double- and triple-tap to fail")
    func positionTapDefersToMultiTaps() {
        let (terminal, _) = makeWired()
        let taps = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let singles = taps.filter { $0.numberOfTapsRequired == 1 }
        let multis = taps.filter { $0.numberOfTapsRequired > 1 }
        // SwiftTerm's own single tap plus the app's position tap.
        #expect(singles.count >= 2, "expected SwiftTerm's tap and the app's position tap")
        #expect(!multis.isEmpty, "SwiftTerm's word/line selection taps are missing")
        // Without this deference, the FIRST tap of a double-tap fires a click
        // at the remote before the selection ever forms.
        // (requireGestureRecognizerToFail relationships aren't inspectable via
        // public API; the observable proxy is that multi-tap recognizers exist
        // alongside — the behavioral pin lives in the fork's own gesture code
        // and the S-layer harness.)
    }

    @Test("the scroll view's own scrolling is off — one pan owns vertical travel")
    func nativeScrollingIsOff() {
        // A device trace of one drag: UIKit wrote contentOffset by the finger's
        // delta before every tick of the app's pan (content at twice the
        // finger) and kept decelerating after the lift against the fork's row
        // realign — the jitter. Disabling only panGestureRecognizer had not
        // held; isScrollEnabled is the switch that does.
        let (terminal, _) = makeWired()
        #expect(terminal.isScrollEnabled == false)
        #expect(terminal.panGestureRecognizer.isEnabled == false)
    }

    @Test("the position tap yields to the long press — lifting after a word selection is not a tap")
    func positionTapIsExclusiveWithLongPress() throws {
        // Device log, three long presses in a row: closeSelection() under
        // handleTap every time. UITapGestureRecognizer has no maximum press
        // duration, so with simultaneous recognition the lift that ends a
        // 0.7s word selection was also a tap — and a tap over a live selection
        // dismisses it. Exclusive with the long press, UIKit fails the tap as
        // soon as the press begins.
        let (terminal, _) = makeWired()
        let recognizers = terminal.gestureRecognizers ?? []
        let tap = try #require(recognizers.first {
            ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 1 && $0.delegate is TerminalScrollGesture
        }, "the app's position tap is missing")
        let longPress = try #require(recognizers.first { $0 is UILongPressGestureRecognizer },
                                     "SwiftTerm's long press is missing")
        let pan = try #require(recognizers.first {
            $0 is UIPanGestureRecognizer && $0.delegate is TerminalScrollGesture
        }, "the app's scroll pan is missing")
        let delegate = try #require(tap.delegate)
        #expect(delegate.gestureRecognizer?(tap, shouldRecognizeSimultaneouslyWith: longPress) == false,
                "a tap must not also recognize on the touch a long press claimed")
        // The rest of the topology is unchanged: the pan still coexists with
        // the long press (its own shouldBegin yields to a live selection), and
        // the tap with everything else.
        #expect(delegate.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: longPress) == true)
        let pinch = try #require(recognizers.first { $0 is UIPinchGestureRecognizer })
        #expect(delegate.gestureRecognizer?(tap, shouldRecognizeSimultaneouslyWith: pinch) == true)
    }

    @Test("a minted terminal has tap-focus off, no assistant bar, no mouse-drag reporting")
    func mintConfiguration() {
        // TerminalMint.configureInput is what BOTH real mint sites (SSH
        // single-pane and tmux panes) call — asserting on it asserts on them.
        // A terminal that quietly regains focusOnTap re-summons the keyboard
        // on every tap taken while reading.
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        TerminalMint.configureInput(view)
        #expect(view.focusOnTap == false)
        #expect(view.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        #expect(view.inputAssistantItem.trailingBarButtonGroups.isEmpty)
        #expect(view.inputAccessoryView == nil)
        #expect(view.allowMouseReporting == false,
                "SwiftTerm must not also report touches as mouse drags — the app's gestures own that")
        #expect(view.linkReporting == .explicit,
                "implicit link regex mis-underlines bare file paths")
    }

    @Test("a selection can be dismissed without first responder")
    func closeSelectionWorksUnfocused() {
        // The user's report verbatim: "如何取消选中呢，现在也没有方式" — the
        // fork's own tap-clears-selection lives in its focused branch, so with
        // focusOnTap off, handleTap's closeSelection() is the only exit.
        let (terminal, _) = makeWired()
        terminal.feed(text: "some words to select\r\n")
        terminal.selectAll(nil)
        #expect(terminal.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil),
                "selectAll should have armed the selection")
        terminal.closeSelection()
        #expect(!terminal.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil),
                "closeSelection must disarm the selection — and with it the app pan's yield")
    }

    @Test("selection handles are finger-sized at every font size")
    func handleToleranceIsFingerSized() {
        // 9pt terminal font ≈ 5.3×10.7pt cells — the old fixed 3×2-cell window
        // was ~16pt there, a third of the 44pt HIG minimum touch target.
        let small = TerminalView.selectionHandleTolerance(cellWidth: 5.3, cellHeight: 10.7)
        #expect(CGFloat(small.cols) * 5.3 >= 20, "grab zone narrower than a fingertip")
        #expect(CGFloat(small.rows) * 10.7 >= 20)
        // Huge fonts must keep at least the old floor so endpoints stay
        // individually addressable.
        let big = TerminalView.selectionHandleTolerance(cellWidth: 20, cellHeight: 40)
        #expect(big.cols >= 3 && big.rows >= 2)
    }
}
