#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreText

/// CoreText indexes UTF-16 and may emit several glyphs for one terminal
/// character. Keep those glyphs in the same cell while preserving their
/// relative offsets (for example the accent in q + U+0308).
struct TerminalGlyphLayout {
    struct GlyphPosition {
        let cell: Int
        let offset: CGPoint
    }

    private let cellsByUTF16Index: [Int]
    private let leadingOffsets: [CGFloat]
    private let trailingOffsets: [CGFloat]
    let cellCount: Int

    init(text: String, line: CTLine) {
        var cells: [Int] = []
        var leading: [CGFloat] = []
        var trailing: [CGFloat] = []
        var utf16Index = 0
        for (cell, character) in text.enumerated() {
            let length = String(character).utf16.count
            cells.append(contentsOf: repeatElement(cell, count: length))
            leading.append(CTLineGetOffsetForStringIndex(line, utf16Index, nil))
            utf16Index += length
            trailing.append(CTLineGetOffsetForStringIndex(line, utf16Index, nil))
        }
        cellsByUTF16Index = cells
        leadingOffsets = leading
        trailingOffsets = trailing
        cellCount = leading.count
    }

    func cells(in range: CFRange) -> Range<Int> {
        guard range.length > 0, !cellsByUTF16Index.isEmpty else { return 0..<0 }
        let first = max(0, min(range.location, cellsByUTF16Index.count - 1))
        let last = max(first, min(range.location + range.length - 1, cellsByUTF16Index.count - 1))
        return cellsByUTF16Index[first]..<(cellsByUTF16Index[last] + 1)
    }

    func positions(in run: CTRun) -> [GlyphPosition] {
        let count = CTRunGetGlyphCount(run)
        guard count > 0, !cellsByUTF16Index.isEmpty else { return [] }
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetPositions(run, CFRange(), &positions)
        CTRunGetStringIndices(run, CFRange(), &indices)
        let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
        return zip(indices, positions).map { index, position in
            let cell = cellsByUTF16Index[max(0, min(index, cellsByUTF16Index.count - 1))]
            let origin = rightToLeft ? min(leadingOffsets[cell], trailingOffsets[cell]) : leadingOffsets[cell]
            return GlyphPosition(cell: cell, offset: CGPoint(x: position.x - origin, y: position.y))
        }
    }
}
#endif
