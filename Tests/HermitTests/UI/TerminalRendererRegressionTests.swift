import Testing
import UIKit
import MetalKit
@testable import SwiftTerm

@Suite("Terminal renderer regressions", .serialized)
@MainActor
struct TerminalRendererRegressionTests {
    private final class BufferSink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("Keyboard and column resizes keep unused 50k scrollback slots unallocated")
    func resizeDoesNotMaterializeScrollbackCapacity() {
        let buffer = Buffer(cols: 80, rows: 24, tabStopWidth: 8, scrollback: 50_000)
        buffer.fillViewportRows()
        let makeEmpty = buffer.lines.makeEmpty!
        var lazyAllocations = 0
        buffer.lines.makeEmpty = { index in
            lazyAllocations += 1
            return makeEmpty(index)
        }
        #expect(buffer.lines.getArray().compactMap { $0 }.count == 24)
        // The old maxLength postcondition allocates 50,000 unused BufferLines
        // on the first height-only resize. These checks count actual slots and
        // factory calls, so they do not depend on simulator timing or RAM usage.
        for (cols, rows) in [(80, 50), (80, 24), (132, 24), (40, 24), (100, 45), (80, 24)] {
            buffer.resize(newCols: cols, newRows: rows)
            let materialized = buffer.lines.getArray().compactMap { $0 }.count
            #expect(buffer.lines.maxLength == 50_000 + rows, "the history limit must remain unchanged")
            #expect(lazyAllocations == 0, "resize must not touch unused capacity")
            #expect(materialized <= 50, "only the largest populated viewport needs physical rows")
            for index in 0..<buffer.lines.count { #expect(buffer.lines[index].count >= cols) }
        }
    }

    @Test("Lazy logical rows use the correct width during and after a column change")
    func resizeHandlesLazyLogicalRows() {
        let buffer = Buffer(cols: 8, rows: 4, tabStopWidth: 8, scrollback: 50_000)
        // Exercise the list's lazy factory, which reads buffer.cols while the
        // resize is still in progress and therefore initially makes 8 columns.
        buffer.lines.count = 4
        let makeEmpty = buffer.lines.makeEmpty!
        var lazyAllocations = 0
        buffer.lines.makeEmpty = { index in
            lazyAllocations += 1
            return makeEmpty(index)
        }
        buffer.resize(newCols: 16, newRows: 4)
        #expect(lazyAllocations == 4)
        for index in 0..<4 { #expect(buffer.lines[index].count == 16) }
        #expect(buffer.lines.getArray().compactMap { $0 }.count == 4)
        // A later lazy row must use the new width once resize has committed.
        buffer.lines.count = 5
        #expect(buffer.lines[4].count == 16)
        #expect(lazyAllocations == 5)
    }

    @Test("Narrowing and widening preserve wrapped history and subsequent output")
    func columnResizePreservesHistory() {
        let terminal = Terminal(delegate: BufferSink(),
            options: TerminalOptions(cols: 24, rows: 4, scrollback: 50_000))
        let history = (0..<12).map { "row-\($0)-abcdefghijklmnopqrstuvwx" }
        terminal.feed(text: history.joined(separator: "\r\n") + "\r\n")
        #expect(logicalLines(in: terminal) == history)
        for (cols, rows) in [(48, 4), (16, 8), (32, 4), (24, 4)] {
            terminal.resize(cols: cols, rows: rows)
            #expect(logicalLines(in: terminal) == history)
            for index in 0..<terminal.buffer.lines.count {
                #expect(terminal.buffer.lines[index].count >= cols)
            }
        }
        terminal.feed(text: "after-resize\r\n")
        #expect(logicalLines(in: terminal) == history + ["after-resize"])
    }

    @Test("Inactive popped slots and full circular-buffer recycling remain valid after resize")
    func resizePreservesCircularReuse() {
        let buffer = Buffer(cols: 8, rows: 8, tabStopWidth: 8, scrollback: 4)
        buffer.fillViewportRows()
        buffer.resize(newCols: 8, newRows: 4)
        #expect(buffer.lines.count == 4)
        #expect(buffer.lines.getArray().compactMap { $0 }.count > buffer.lines.count,
                "pop deliberately retains old physical slots outside the logical count")
        buffer.resize(newCols: 16, newRows: 4)
        buffer.resize(newCols: 16, newRows: 8)
        for index in 0..<buffer.lines.count { #expect(buffer.lines[index].count == 16) }

        let terminal = Terminal(delegate: BufferSink(),
            options: TerminalOptions(cols: 8, rows: 4, scrollback: 4))
        terminal.feed(text: (0..<12).map { "r\($0)\r\n" }.joined())
        #expect(terminal.buffer.lines.isFull)
        #expect(terminal.buffer.lines.getStartIndex() != 0)
        let retained = logicalLines(in: terminal)
        terminal.resize(cols: 16, rows: 4)
        terminal.resize(cols: 5, rows: 4)
        #expect(logicalLines(in: terminal) == retained)
        terminal.feed(text: (12..<24).map { "r\($0)\r\n" }.joined())
        #expect(terminal.buffer.lines.isFull)
        #expect(logicalLines(in: terminal).last == "r23")
        for index in 0..<terminal.buffer.lines.count { #expect(terminal.buffer.lines[index].count == 5) }
    }

    private func logicalLines(in terminal: Terminal) -> [String] {
        var result: [String] = []
        for index in 0..<terminal.buffer.lines.count {
            let line = terminal.buffer.lines[index]
            let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                                               characterProvider: terminal.getCharacter)
            if line.isWrapped, !result.isEmpty { result[result.count - 1] += text }
            else { result.append(text) }
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private final class WeakTerminal {
        weak var value: TerminalView?
    }

    @Test("discarding a terminal releases it", arguments: [false, true])
    func terminalLifetime(_ invalidate: Bool) async throws {
        let weakTerminal = WeakTerminal()
        autoreleasepool {
            let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
            weakTerminal.value = terminal
            if invalidate { terminal.updateUiClosed() }
        }
        // Allow the initialization's queued UIKit work to finish first.
        try await Task.sleep(for: .milliseconds(200))
        #expect(weakTerminal.value == nil, "Terminal survives after owner release; explicit invalidate=\(invalidate)")
        // If this regresses, avoid retaining failed fixtures for later tests.
        weakTerminal.value?.updateUiClosed()
    }

    @Test("combining marks do not advance the next terminal cell", arguments: [false, true], ["q\u{0308}", "x\u{0301}"])
    func combiningCellAlignment(_ metal: Bool, _ character: String) async throws {
        let (plainWindow, plainTerminal) = makeFixture()
        let (combinedWindow, combinedTerminal) = makeFixture()
        defer {
            plainWindow.isHidden = true
            combinedWindow.isHidden = true
            plainTerminal.updateUiClosed()
            combinedTerminal.updateUiClosed()
        }
        plainTerminal.feed(text: "\u{1b}[?25lx\u{1b}[38;2;255;0;0mA")
        combinedTerminal.feed(text: "\u{1b}[?25l\(character)\u{1b}[38;2;255;0;0mA")
        let model = combinedTerminal.getTerminal()
        #expect(model.buffer.x == 2)
        #expect(model.getCharacter(for: model.getLine(row: 0)![0]) == Character(character))
        let first: CGImage
        let second: CGImage
        if metal {
            let device = try #require(MTLCreateSystemDefaultDevice())
            first = try await captureMetal(plainTerminal, device: device, scale: plainWindow.screen.scale)
            second = try await captureMetal(combinedTerminal, device: device, scale: combinedWindow.screen.scale)
        } else {
            first = try captureCore(plainTerminal, scale: plainWindow.screen.scale)
            second = try captureCore(combinedTerminal, scale: combinedWindow.screen.scale)
        }
        let expected = try #require(inkBounds(first, channel: 0))
        let actual = try #require(inkBounds(second, channel: 0))
        print("Combining grid metal=\(metal): A expected=\(expected), actual=\(actual), cellWidth=\(combinedTerminal.cellDimension.width)")
        #expect(abs(actual.lowerBound - expected.lowerBound) <= 2,
                "The combining mark must not shift the following A into another column")
    }

    @Test("combining glyphs share a cell within one color run", arguments: [false, true])
    func combiningInsideRun(_ metal: Bool) async throws {
        let (plainWindow, plainTerminal) = makeFixture()
        let (combinedWindow, combinedTerminal) = makeFixture()
        defer {
            plainWindow.isHidden = true
            combinedWindow.isHidden = true
            plainTerminal.updateUiClosed()
            combinedTerminal.updateUiClosed()
        }
        plainTerminal.feed(text: "\u{1b}[?25l\u{1b}[38;2;255;0;0mqA")
        combinedTerminal.feed(text: "\u{1b}[?25l\u{1b}[38;2;255;0;0mq\u{0308}A")
        let expected: CGImage
        let actual: CGImage
        if metal {
            let device = try #require(MTLCreateSystemDefaultDevice())
            expected = try await captureMetal(plainTerminal, device: device, scale: plainWindow.screen.scale)
            actual = try await captureMetal(combinedTerminal, device: device, scale: combinedWindow.screen.scale)
        } else {
            expected = try captureCore(plainTerminal, scale: plainWindow.screen.scale)
            actual = try captureCore(combinedTerminal, scale: combinedWindow.screen.scale)
        }
        let expectedInk = try #require(inkBounds(expected, channel: 0))
        let actualInk = try #require(inkBounds(actual, channel: 0))
        #expect(abs(expectedInk.upperBound - actualInk.upperBound) <= 2,
                "The final A must occupy the same cell even without an attribute boundary")
    }

    @Test("replacing a Kitty image refreshes pixels after the header", arguments: [false, true])
    func kittyImageReplacement(_ metal: Bool) async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true; terminal.updateUiClosed() }
        var red = [UInt8](repeating: 0, count: 20 * 20 * 4)
        for i in 0..<400 {
            red[i * 4] = i < 16 ? 0 : 255
            red[i * 4 + 3] = 255
        }
        var green = red
        for i in 16..<400 {
            green[i * 4] = 0
            green[i * 4 + 1] = 255
        }
        terminal.feed(text: "\u{1b}[?25l\u{1b}_Ga=T,f=32,s=20,v=20,i=1,p=1,U=1,c=1,r=1,q=2;\(Data(red).base64EncodedString())\u{1b}\\\u{1b}[38;2;1;0;0m\u{10EEEE}")
        #expect(terminal.getTerminal().kittyGraphicsState.imagesById[1] != nil)
        let initial: CGImage
        let updated: CGImage
        if metal {
            let device = try #require(MTLCreateSystemDefaultDevice())
            initial = try await captureMetal(terminal, device: device, scale: window.screen.scale)
            terminal.feed(text: "\u{1b}_Ga=t,f=32,s=20,v=20,i=1,q=2;\(Data(green).base64EncodedString())\u{1b}\\")
            terminal.updateDisplay()
            updated = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        } else {
            initial = try captureCore(terminal, scale: window.screen.scale)
            terminal.feed(text: "\u{1b}_Ga=t,f=32,s=20,v=20,i=1,q=2;\(Data(green).base64EncodedString())\u{1b}\\")
            updated = try captureCore(terminal, scale: window.screen.scale)
        }
        #expect(inkBounds(initial, channel: 0) != nil)
        #expect(inkBounds(updated, channel: 1) != nil,
                "New green pixels must replace the cached red image, metal=\(metal)")
        #expect(inkBounds(updated, channel: 0) == nil,
                "Old red pixels must disappear after image replacement, metal=\(metal)")
    }

    @Test("Output after narrow and restored layouts replaces the previous frame", arguments: [false, true])
    func finalOutputAfterResize(_ metal: Bool) async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true; terminal.updateUiClosed() }
        let device = metal ? try #require(MTLCreateSystemDefaultDevice()) : nil
        terminal.feed(text: "\u{1b}[?25l\u{1b}[38;2;255;0;0mOLD-FRAME")
        let initial: CGImage
        if let device { initial = try await captureMetal(terminal, device: device, scale: window.screen.scale) }
        else { initial = try captureCore(terminal, scale: window.screen.scale) }
        #expect(inkBounds(initial, channel: 0) != nil)

        for width in [230.0, 540.0, 390.0] {
            terminal.frame.size.width = width
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[38;2;0;255;0mFINAL-\(Int(width))")
            terminal.updateDisplay()
        }
        let final: CGImage
        if let device { final = try await captureMetal(terminal, device: device, scale: window.screen.scale) }
        else { final = try captureCore(terminal, scale: window.screen.scale) }
        #expect(inkBounds(final, channel: 1) != nil,
                "the final green output must reach the drawable after the last resize")
        #expect(inkBounds(final, channel: 0) == nil,
                "resizing must not leave cached pixels from the old red frame")
    }

    private func makeFixture() -> (UIWindow, TerminalView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let terminal = TerminalView(frame: window.bounds,
            font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular))
        controller.view.addSubview(terminal)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        return (window, terminal)
    }

    private func captureCore(_ terminal: TerminalView, scale: CGFloat) throws -> CGImage {
        terminal.layoutIfNeeded()
        terminal.updateDisplay()
        terminal.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return try #require(UIGraphicsImageRenderer(bounds: terminal.bounds, format: format).image { context in
            terminal.layer.render(in: context.cgContext)
        }.cgImage)
    }
    @MainActor
    private func captureMetal(_ terminal: TerminalView, device: MTLDevice, scale: CGFloat) async throws -> CGImage {
        try terminal.setUseMetal(true)
        let surface = try #require(terminal.subviews.compactMap { $0 as? MTKView }.first)
        surface.isPaused = true
        surface.enableSetNeedsDisplay = false
        surface.framebufferOnly = false
        terminal.layoutIfNeeded()
        // Flush UIKit autoresizing and the font change before acquiring a drawable.
        try await Task.sleep(for: .milliseconds(50))
        terminal.layoutIfNeeded()
        surface.drawableSize = CGSize(width: surface.bounds.width * scale, height: surface.bounds.height * scale)
        let renderer = try #require(surface.delegate)
        let probe = DrawableProbe(renderer: renderer)
        surface.delegate = probe
        // MTKView.draw() manages drawable recycling; calling its delegate
        // directly can read the previous frame after resizing.
        surface.draw()
        surface.delegate = renderer
        let drawable = try #require(probe.drawable)
        try await Task.sleep(for: .milliseconds(300))
        let texture = drawable.texture
        let bytesPerRow = ((texture.width * 4 + 255) / 256) * 256
        let buffer = try #require(device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let data = Data(bytes: buffer.contents(), count: buffer.length)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: texture.width, height: texture.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue:
                CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return image
    }

    private final class DrawableProbe: NSObject, MTKViewDelegate {
        let renderer: MTKViewDelegate
        var drawable: CAMetalDrawable?
        init(renderer: MTKViewDelegate) { self.renderer = renderer }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.mtkView(view, drawableSizeWillChange: size)
        }
        func draw(in view: MTKView) {
            renderer.draw(in: view)
            drawable = view.currentDrawable
        }
    }

    private func inkBounds(_ image: CGImage, channel: Int, vertical: Bool = false) -> ClosedRange<Int>? {
        // Normalize both UIKit and Metal images to identical RGBA bytes.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var first = vertical ? image.height : image.width, last = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                if bytes[offset + channel] > 100 && bytes[offset + (channel + 1) % 3] < 50
                    && bytes[offset + (channel + 2) % 3] < 50 {
                    let position = vertical ? y : x
                    first = min(first, position); last = max(last, position)
                }
            }
        }
        return last >= first ? first...last : nil
    }

}
