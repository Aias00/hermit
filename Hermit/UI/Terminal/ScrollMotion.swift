import CoreGraphics
import Foundation

/// Finger travel in points → whole rows, carrying the sub-row remainder to the
/// next tick instead of throwing it away. Routes that can only move by rows (a
/// forwarded wheel, tmux copy-mode over mosh, herdr) use it so a slow drag
/// adds up to the same rows a fast one does — the old `Int(dy / cellHeight)`
/// dropped up to a row per tick and made a slow drag barely move.
struct ScrollRowCarry {
    private(set) var remainder: CGFloat = 0

    /// Positive = toward older output. Returns the whole rows now due.
    mutating func take(pixels: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0, pixels.isFinite else { return 0 }
        remainder += pixels
        let rows = Int((remainder / cellHeight).rounded(.towardZero))
        remainder -= CGFloat(rows) * cellHeight
        return rows
    }

    mutating func reset() { remainder = 0 }
}

/// Wheel ticks waiting for the next display interval. Reversing direction
/// discards unsent motion in the old direction so it cannot fight the finger.
struct TerminalWheelQueue {
    private(set) var pending = 0

    @discardableResult
    mutating func enqueue(_ lines: Int) -> Bool {
        guard lines != 0 else { return false }
        let reversed = pending != 0 && (pending > 0) != (lines > 0)
        if reversed { pending = 0 }
        let (sum, overflow) = pending.addingReportingOverflow(lines)
        pending = overflow ? (lines > 0 ? Int.max : Int.min) : sum
        return reversed
    }

    mutating func take(limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        let batch = min(limit, max(-limit, pending))
        pending -= batch
        return batch
    }

    mutating func reset() { pending = 0 }
}
