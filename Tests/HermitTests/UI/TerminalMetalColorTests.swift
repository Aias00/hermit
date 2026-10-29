import Testing
import UIKit
import MetalKit
@testable import SwiftTerm
@testable import Moshpit

@Suite("Metal terminal colors", .serialized)
struct TerminalMetalColorTests {
    @Test("foreground colors and emoji survive Metal rendering", arguments: ["ansi", "indexed", "truecolor"] )
    @MainActor
    func ansiColors(_ mode: String) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let terminal = TerminalView(frame: window.bounds,
            font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular))
        controller.view.addSubview(terminal)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        let colors = mode == "indexed" ? ["38;5;196", "38;5;46", "38;5;21"]
            : mode == "truecolor" ? ["38;2;230;30;30", "38;2;30;230;30", "38;2;30;30;230"]
            : ["31", "32", "34"]
        terminal.feed(text: "\u{1b}[\(colors[0])mMMMMMMMM RED 中文\r\n\u{1b}[1;\(colors[1])mMMMMMMMM GREEN 中文\r\n\u{1b}[0;\(colors[2])mMMMMMMMM BLUE 中文\u{1b}[0m\r\n😀")
        let image = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        let data = try #require(image.dataProvider?.data)
        let pixels = CFDataGetBytePtr(data)!
        let bytesPerRow = image.bytesPerRow
        var red = 0, green = 0, blue = 0, yellow = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * bytesPerRow + x * 4
                let b = Int(pixels[offset]), g = Int(pixels[offset + 1]), r = Int(pixels[offset + 2])
                if r > 100 && g > 80 && b < min(r, g) / 2 { yellow += 1 }
                if r > 60 && r > g * 3 / 2 && r > b * 3 / 2 { red += 1 }
                if g > 60 && g > r * 3 / 2 && g > b * 3 / 2 { green += 1 }
                if b > 60 && b > r * 3 / 2 && b > g * 3 / 2 { blue += 1 }
            }
        }
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("metal-\(mode)-colors.png")
        try UIImage(cgImage: image).pngData()?.write(to: imageURL)
        print("Metal screenshot: \(imageURL.path)")
        print("Metal color pixels: red=\(red) green=\(green) blue=\(blue)")
        #expect(red > 100)
        #expect(green > 100)
        #expect(blue > 100)
        #expect(yellow > 100, "Emoji must retain its native colors")
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

    @Test("Metal text stays on the CoreGraphics column grid", arguments: [13.0, 17.0, 20.0])
    @MainActor
    func columnGrid(_ size: Double) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let terminal = TerminalView(frame: window.bounds,
            font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular))
        controller.view.addSubview(terminal)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.feed(text: "\u{1b}[?25l\u{1b}[38;2;255;0;0m" + String(repeating: "|", count: 25)
            + "\r\n\u{1b}[38;2;0;255;0m" + String(repeating: "田", count: 12)
            + "\r\n\u{1b}[1;4;38;2;0;0;255mAB中文CD中文EF中文GH")
        terminal.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let reference = try #require(UIGraphicsImageRenderer(bounds: terminal.bounds, format: format).image { context in
            terminal.layer.render(in: context.cgContext)
        }.cgImage)
        let metal = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        for (label, image) in [("core", reference), ("metal", metal)] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("grid-\(Int(size))-\(label).png")
            try UIImage(cgImage: image).pngData()?.write(to: path)
            print("Grid screenshot: \(path.path)")
        }
        for channel in 0..<3 {
            let expected = try #require(inkBounds(reference, channel: channel))
            let actual = try #require(inkBounds(metal, channel: channel))
            print("Grid \(size) channel \(channel): core=\(expected) metal=\(actual)")
            #expect(abs(expected.lowerBound - actual.lowerBound) <= 2)
            #expect(abs(expected.upperBound - actual.upperBound) <= 2)
        }
    }

    @Test("terminal styles agree across renderers", arguments: ["italic", "dim", "inverse", "decorated", "box", "unicode", "alternate"])
    @MainActor
    func textStyles(_ style: String) async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let attributes = ["italic": "3", "dim": "2", "inverse": "7", "decorated": "4;9"]
        let sample = style == "box" ? "┌──┬──┐ ▀▄█" : style == "unicode" ? "Ae\u{301}中文😀Z" : "MMMM sample"
        var text = "\u{1b}[?25l"
        if style == "alternate" { text += "\u{1b}[?1049h\u{1b}[?25l" }
        for color in ["255;0;0", "0;255;0", "0;0;255"] {
            text += "\u{1b}[0;\(attributes[style] ?? "0");38;2;\(color)m\(sample)\r\n"
        }
        terminal.feed(text: text)
        terminal.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let reference = try #require(UIGraphicsImageRenderer(bounds: terminal.bounds, format: format).image { context in
            terminal.layer.render(in: context.cgContext)
        }.cgImage)
        let metal = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        for (label, image) in [("core", reference), ("metal", metal)] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("style-\(style)-\(label).png")
            try UIImage(cgImage: image).pngData()?.write(to: path)
            print("Style screenshot: \(path.path)")
        }
        for channel in 0..<3 {
            for vertical in [false, true] {
                let expected = try #require(inkBounds(reference, channel: channel, vertical: vertical))
                let actual = try #require(inkBounds(metal, channel: channel, vertical: vertical))
                #expect(abs(expected.lowerBound - actual.lowerBound) <= 2, "\(style), channel \(channel), vertical \(vertical)")
                #expect(abs(expected.upperBound - actual.upperBound) <= 2, "\(style), channel \(channel), vertical \(vertical)")
            }
        }
    }

    @Test("Metal scrolls by pixels within a row")
    @MainActor
    func fractionalScroll() async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        let device = try #require(MTLCreateSystemDefaultDevice())
        terminal.feed(text: "\u{1b}[?25l\u{1b}[31mMARKER\u{1b}[0m\r\n" + String(repeating: "other row\r\n", count: 30))
        terminal.contentOffset = .zero
        terminal.getTerminal().setViewYDisp(0)
        let before = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        terminal.scrollViewport(by: -5)
        let after = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        let a = try #require(inkBounds(before, channel: 0, vertical: true))
        let b = try #require(inkBounds(after, channel: 0, vertical: true))
        #expect(abs(abs(a.upperBound - b.upperBound) - Int(5 * window.screen.scale)) <= 1)
    }

    @Test("Metal preserves the UIKit cursor during Chinese composition")
    @MainActor
    func compositionCursor() throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        terminal.becomeFirstResponder()
        try terminal.setUseMetal(true)
        terminal.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        let caret = try #require(terminal.caretView)
        let label = try #require(terminal.imeCompositionLabel)
        #expect(!caret.isHidden)
        #expect(caret.frame.minX > label.frame.minX)
        #expect(terminal.hasActiveIMEComposition)
        terminal.unmarkText()
        #expect(!terminal.hasActiveIMEComposition)
        #expect(!caret.isHidden)
    }

    @Test("theme and selection updates invalidate cached Metal rows")
    @MainActor
    func cachedAppearance() async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        let device = try #require(MTLCreateSystemDefaultDevice())
        terminal.nativeForegroundColor = .red
        terminal.feed(text: "\u{1b}[?25lMMMMMMMM")
        let red = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(inkBounds(red, channel: 0) != nil)
        terminal.nativeForegroundColor = .green
        terminal.nativeBackgroundColor = .black
        let green = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(inkBounds(green, channel: 1) != nil)
        #expect(inkBounds(green, channel: 0) == nil)
        terminal.selectedTextBackgroundColor = .blue
        terminal.selection.selectAll()
        let selected = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(inkBounds(selected, channel: 2) != nil)
        terminal.closeSelection()
        let cleared = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(inkBounds(cleared, channel: 2) == nil)
    }

    @Test("cursor styles, focus and visibility share the UIKit path", arguments: ["1", "2", "3", "4", "5", "6"])
    @MainActor
    func cursorState(_ style: String) throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        terminal.feed(text: "\u{1b}[\(style) qTEXT")
        terminal.updateCursorPosition()
        let caret = try #require(terminal.caretView)
        let originalFrame = caret.frame
        terminal.becomeFirstResponder()
        try terminal.setUseMetal(true)
        #expect(terminal.caretView === caret)
        #expect(caret.superview === terminal)
        #expect(!caret.isHidden)
        #expect(caret.frame == originalFrame)
        terminal.resignFirstResponder()
        #expect(!caret.isHidden)
        terminal.feed(text: "\u{1b}[?25l")
        terminal.updateCursorPosition()
        #expect(caret.superview == nil)
        terminal.feed(text: "\u{1b}[?25h")
        terminal.updateCursorPosition()
        #expect(caret.superview === terminal)
        try terminal.setUseMetal(false)
        #expect(terminal.caretView === caret)
        #expect(caret.frame == originalFrame)
    }

    @Test("resizing, font changes and alternate screens refresh Metal state")
    @MainActor
    func rendererLifecycle() async throws {
        let (window, terminal) = makeFixture()
        defer { window.isHidden = true }
        let device = try #require(MTLCreateSystemDefaultDevice())
        terminal.feed(text: "\u{1b}[?25l\u{1b}[31mMMMMMMMM")
        _ = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        terminal.frame.size.width = 280
        terminal.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        terminal.layoutIfNeeded()
        let resized = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(resized.width == Int(280 * window.screen.scale))
        let reference = try #require(inkBounds(resized, channel: 0))
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?25l\u{1b}[32mALT SCREEN")
        let alternate = try await captureMetal(terminal, device: device, scale: window.screen.scale)
        #expect(inkBounds(alternate, channel: 1) != nil)
        #expect(inkBounds(alternate, channel: 0) == nil)
        terminal.feed(text: "\u{1b}[?1049l\u{1b}[?25l")
        for _ in 0..<3 {
            try terminal.setUseMetal(false)
            let restored = try await captureMetal(terminal, device: device, scale: window.screen.scale)
            #expect(inkBounds(restored, channel: 0) == reference)
            #expect(inkBounds(restored, channel: 1) == nil)
        }
    }

    @MainActor
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
