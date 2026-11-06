import Foundation

/// Local comparison against user-supplied ground truth. This measures text
/// differences, never recognition confidence, and retains no recordings.
enum RecognitionAccuracy {
    static let maximumCharacters = 2_000

    struct Result: Equatable, Sendable {
        let referenceCount: Int
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let trailingOmissions: Int
        let retainedTerms: [String]
        let missingTerms: [String]
        let numberCount: Int
        let retainedNumberCount: Int
        var errorCount: Int { substitutions + deletions + insertions }
        // CER can exceed 100% when the recognizer inserts many characters.
        var errorRate: Double { Double(errorCount) / Double(referenceCount) }
    }

    static func compare(reference: String, recognized: String, terms: String = "",
                        ignorePunctuation: Bool = true) -> Result? {
        guard reference.count <= maximumCharacters, recognized.count <= maximumCharacters else { return nil }
        let expected = characters(reference, ignorePunctuation: ignorePunctuation)
        let actual = characters(recognized, ignorePunctuation: ignorePunctuation)
        guard !expected.isEmpty else { return nil }
        let width = actual.count + 1
        var directions = [UInt8](repeating: 0, count: (expected.count + 1) * width)
        var previous = Array(0...actual.count)
        for j in 1..<width { directions[j] = 3 }
        for i in 1...expected.count {
            if Task.isCancelled { return nil }
            var current = [Int](repeating: 0, count: width)
            current[0] = i
            directions[i * width] = 2
            for j in 1..<width {
                let equal = expected[i - 1] == actual[j - 1]
                var best = previous[j - 1] + (equal ? 0 : 1)
                var direction: UInt8 = equal ? 0 : 1
                if previous[j] + 1 < best { best = previous[j] + 1; direction = 2 }
                if current[j - 1] + 1 < best { best = current[j - 1] + 1; direction = 3 }
                current[j] = best
                directions[i * width + j] = direction
            }
            previous = current
        }
        var i = expected.count, j = actual.count
        var substitutions = 0, deletions = 0, insertions = 0, trailing = 0
        var atEnd = true
        while i > 0 || j > 0 {
            switch directions[i * width + j] {
            case 2:
                deletions += 1; i -= 1
                if atEnd { trailing += 1 }
            case 3:
                insertions += 1; j -= 1; atEnd = false
            default:
                if directions[i * width + j] == 1 { substitutions += 1 }
                i -= 1; j -= 1; atEnd = false
            }
        }
        var seen = Set<String>()
        let keywords = terms.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 128 && reference.contains($0) && seen.insert($0).inserted }
            .prefix(32)
        var numbers = numberTokens(in: recognized)
        let expectedNumbers = numberTokens(in: reference)
        var retainedNumbers = 0
        for number in expectedNumbers {
            if let index = numbers.firstIndex(of: number) {
                numbers.remove(at: index); retainedNumbers += 1
            }
        }
        return Result(referenceCount: expected.count, substitutions: substitutions, deletions: deletions,
                      insertions: insertions, trailingOmissions: trailing,
                      retainedTerms: keywords.filter { recognized.contains($0) },
                      missingTerms: keywords.filter { !recognized.contains($0) },
                      numberCount: expectedNumbers.count, retainedNumberCount: retainedNumbers)
    }

    private static func characters(_ text: String, ignorePunctuation: Bool) -> [Character] {
        guard ignorePunctuation else { return Array(text) }
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return Array(String(text.unicodeScalars.filter { !ignored.contains($0) }))
    }

    private static func numberTokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[+-]?[0-9]+(?:\.[0-9]+)*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
