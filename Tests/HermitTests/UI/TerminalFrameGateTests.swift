import Foundation
import Testing
@testable import SwiftTerm

@Suite("Metal frame scheduling")
struct TerminalFrameGateTests {
    @Test("A burst while the GPU is busy requests exactly one follow-up frame")
    func busyFrameCoalescesWithoutLosingLastUpdate() {
        let gate = MetalFrameGate()
        #expect(gate.beginFrame())
        for _ in 0..<100 { #expect(!gate.beginFrame()) }
        #expect(gate.completeFrame())
        #expect(gate.beginFrame())
        #expect(!gate.completeFrame())
    }

    @Test("A completion racing the last update either admits it or schedules it")
    func completionRaceCannotStrandOutput() {
        for _ in 0..<200 {
            let gate = MetalFrameGate()
            let result = RaceResult()
            let group = DispatchGroup()
            #expect(gate.beginFrame())
            group.enter()
            DispatchQueue.global().async {
                result.setBegan(gate.beginFrame())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                result.setRedraw(gate.completeFrame())
                group.leave()
            }
            group.wait()
            let (began, redraw) = result.values
            #expect(began != redraw,
                    "the final update must be rendered now or rescheduled, never lost or submitted twice")
            if began { #expect(!gate.completeFrame()) }
        }
    }

    @Test("Missing drawables and failed encoders release the frame for restoration")
    func abandonedFrameCanResume() {
        let gate = MetalFrameGate()
        for _ in 0..<3 {
            #expect(gate.beginFrame())
            gate.abandonFrame(needsRedraw: true)
        }
        #expect(gate.beginFrame(), "the first visible frame must not remain blocked")
        #expect(gate.completeFrame(), "preserve the outstanding redraw until a frame succeeds")
        #expect(gate.beginFrame())
        #expect(!gate.completeFrame())
    }

    private final class RaceResult: @unchecked Sendable {
        private let lock = NSLock()
        private var began = false
        private var redraw = false
        func setBegan(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }; began = value
        }
        func setRedraw(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }; redraw = value
        }
        var values: (Bool, Bool) {
            lock.lock(); defer { lock.unlock() }; return (began, redraw)
        }
    }
}
