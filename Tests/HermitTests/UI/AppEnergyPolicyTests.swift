import Foundation
import Testing
import UIKit
import SwiftTerm
@testable import Moshpit

@Suite("Adaptive energy budget")
struct AppEnergyPolicyTests {
    @Test("power saving never overrides a stricter thermal budget")
    func thermalAndLowPowerBudgets() {
        let states: [(ProcessInfo.ThermalState, Int, TimeInterval)] = [
            (.nominal, 60, 2), (.fair, 30, 4), (.serious, 15, 6), (.critical, 10, 10),
        ]
        for (thermal, frames, sampling) in states {
            let normal = AppEnergyPolicy(lowPowerMode: false, thermalState: thermal)
            #expect(normal.terminalFramesPerSecond == frames)
            #expect(normal.samplingInterval == sampling)
            let saving = AppEnergyPolicy(lowPowerMode: true, thermalState: thermal)
            #expect(saving.terminalFramesPerSecond <= min(30, frames))
            #expect(saving.samplingInterval >= max(4, sampling))
        }
    }

    @Test("a reduced presentation rate never delays terminal parsing")
    @MainActor
    func parsingIsImmediate() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        terminal.maximumFramesPerSecond = 10
        terminal.feed(text: "abc\u{1b}[31m中文")
        #expect(terminal.getTerminal().getCursorLocation().x == 7)
    }
}
