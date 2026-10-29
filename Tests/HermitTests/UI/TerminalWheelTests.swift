import SwiftTerm
import Testing
import UIKit
@testable import Moshpit

@Suite("Terminal wheel queue")
struct TerminalWheelQueueTests {
    @Test("A large delta is drained completely in bounded batches")
    func preservesRemainder() {
        var queue = TerminalWheelQueue()
        queue.enqueue(41)
        var batches: [Int] = []
        while queue.pending != 0 { batches.append(queue.take(limit: 6)) }
        #expect(batches == [6, 6, 6, 6, 6, 6, 5])
        queue.enqueue(-19)
        #expect(queue.take(limit: 6) == -6)
        #expect(queue.pending == -13)
    }

    @Test("A reversal replaces old unsent motion, while same-direction ticks add up")
    func reversal() {
        var queue = TerminalWheelQueue()
        queue.enqueue(20)
        #expect(queue.take(limit: 6) == 6)
        queue.enqueue(8)
        #expect(queue.pending == 22)
        let reversed = queue.enqueue(-9)
        #expect(reversed)
        #expect(queue.take(limit: 6) == -6)
        #expect(queue.pending == -3)
        queue.reset()
        #expect(queue.take(limit: 6) == 0)
    }

    @Test("Extreme signed deltas cannot overflow or trap")
    func extremes() {
        var queue = TerminalWheelQueue()
        queue.enqueue(Int.min)
        queue.enqueue(-10)
        #expect(queue.take(limit: 6) == -6)
        queue.enqueue(Int.max)
        queue.enqueue(10)
        #expect(queue.take(limit: 6) == 6)
        #expect(queue.take(limit: 0) == 0)
    }
}

@MainActor
@Suite("Terminal wheel delivery", .serialized)
struct TerminalWheelDeliveryTests {
    @MainActor private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator: SwiftTerminalView.Coordinator
        var packets: [String] = []
        var bytes: [Data] = []

        init(coordinator: SwiftTerminalView.Coordinator = .init()) {
            self.coordinator = coordinator
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(view)
            window.makeKeyAndVisible()
            view.terminalDelegate = coordinator
            coordinator.attach(to: view)
            coordinator.onInput = { [weak self] data in
                self?.packets.append(String(decoding: data, as: UTF8.self))
                self?.bytes.append(data)
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        }

        func close() {
            coordinator.cancelPendingWheel()
            window.isHidden = true
        }

        var ups: Int { packets.filter { $0.hasPrefix("\u{1b}[<64;") }.count }
        var downs: Int { packets.filter { $0.hasPrefix("\u{1b}[<65;") }.count }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }

    @Test("A fast flick sends every wheel tick through the negotiated encoder")
    func deliversRemainder() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 23)
        #expect(f.ups == 6)
        // A same-direction tick joins the scheduled remainder rather than
        // creating an unbounded synchronous burst.
        f.coordinator.sendWheel(lines: 4)
        #expect(f.ups == 6)
        try await settle()
        #expect(f.ups == 27)
        #expect(f.downs == 0)
    }

    @Test("Reversing direction cancels only the old unsent remainder")
    func reversesImmediately() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 30)
        f.coordinator.sendWheel(lines: -11)
        #expect(f.ups == 6)
        #expect(f.downs == 6)
        try await settle()
        #expect(f.ups == 6)
        #expect(f.downs == 11)
    }

    @Test("A typed key ends the queued wheel burst")
    func typingCancelsRemainder() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 30)
        f.coordinator.send(source: f.view, data: ArraySlice([UInt8(0x71)]))
        try await settle()
        #expect(f.ups == 6)
        #expect(f.packets.last == "q")
    }

    @Test("Reconnect and replacement input routes cannot inherit old wheel input")
    func connectionBoundary() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 30)
        f.coordinator.resetInputParser()
        try await settle()
        #expect(f.ups == 6)
        f.coordinator.sendWheel(lines: 30)
        var nextRoute: [Data] = []
        f.coordinator.onInput = { nextRoute.append($0) }
        try await settle()
        #expect(f.ups == 12)
        #expect(nextRoute.isEmpty)
    }

    @Test("Mouse mode off, a hidden terminal and background entry discard queued ticks")
    func lostDestination() async throws {
        for reason in 0..<3 {
            let f = Fixture(); defer { f.close() }
            f.coordinator.sendWheel(lines: 30)
            switch reason {
            case 0: f.view.feed(text: "\u{1b}[?1000l")
            case 1: f.view.removeFromSuperview()
            default: NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            }
            try await settle()
            #expect(f.ups == 6)
            // Restoring the old mode/view does not resurrect the discarded burst.
            if reason == 0 { f.view.feed(text: "\u{1b}[?1000h") }
            try await settle()
            #expect(f.ups == 6)
        }
    }

    @Test("Starting a new drag discards the previous drag's queued motion")
    func newDrag() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 30)
        f.coordinator.scrollWillBegin()
        f.coordinator.sendWheel(lines: -2)
        f.coordinator.scrollDidEnd()
        try await settle()
        #expect(f.ups == 6)
        #expect(f.downs == 2)
    }

    @Test("A program can disable and re-enable mouse mode within the same output chunk")
    func replacedMouseApplication() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 30)
        f.view.feed(text: "\u{1b}[?1000l\u{1b}[?1000h")
        try await settle()
        #expect(f.ups == 6)
        f.coordinator.sendWheel(lines: -3)
        #expect(f.downs == 3)
    }

    @Test("Repeated mode announcements and automatic terminal replies preserve a queued flick")
    func outputIsNotTyping() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 24)
        f.coordinator.feed(data: Data("\u{1b}[?1000h\u{1b}[6n".utf8))
        try await settle()
        #expect(f.ups == 24)
        #expect(f.packets.contains { $0.hasSuffix("R") })
    }

    @Test("Small callbacks share the same wheel interval")
    func smallTicksCoalesce() async throws {
        let f = Fixture(); defer { f.close() }
        f.coordinator.sendWheel(lines: 6)
        f.coordinator.sendWheel(lines: 6)
        #expect(f.ups == 6)
        try await settle()
        #expect(f.ups == 12)
    }

    @Test("Shortcut input and draft submission cancel a previous flick even before a live connection")
    func directUserInputCancels() async throws {
        let connection = ServerConnection(name: "wheel-test", host: "192.0.2.1", port: 22,
                                          username: "test", authMethod: .password)
        let session = SessionHub.ActiveSession(connection: connection)
        let f = Fixture(coordinator: session.coordinator); defer { f.close() }
        f.coordinator.sendWheel(lines: 24)
        session.sendInput(Data([0x1b]))
        try await settle()
        #expect(f.ups == 6)
        f.coordinator.sendWheel(lines: 24)
        do {
            try await session.submitLine("exit")
            Issue.record("an offline session must reject submission")
        } catch {}
        try await settle()
        #expect(f.ups == 12)
    }

    @Test("Pixel mouse reporting uses view coordinates and legacy reporting safely clamps wide grids")
    func protocolCoordinates() {
        let f = Fixture(); defer { f.close() }
        f.view.feed(text: "\u{1b}[?1016h")
        f.coordinator.sendWheel(lines: 1)
        #expect(f.packets.last == "\u{1b}[<64;195;300M")
        f.coordinator.cancelPendingWheel()
        f.view.feed(text: "\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1000h")
        f.view.resize(cols: 600, rows: 24)
        f.coordinator.sendWheel(lines: 1)
        #expect(f.bytes.last == Data([0x1b, 0x5b, 0x4d, 96, 255, 45]))
    }
}
