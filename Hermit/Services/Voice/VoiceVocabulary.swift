import Foundation

/// User-supplied recognition hints, kept separate from recordings and cloud
/// configuration. Validation is shared by Settings and every engine boundary.
enum VoiceVocabulary {
    static let maximumTerms = 100
    static let maximumTermCharacters = 64
    static let maximumTextCharacters = 4_096
    static let whisperPromptTokenLimit = 192

    enum Issue: Equatable, Sendable {
        case textTooLong
        case termTooLong
        case tooManyTerms

        var message: String {
            switch self {
            case .textTooLong:
                return String(localized: "Keep the vocabulary within 4,096 characters.")
            case .termTooLong:
                return String(localized: "Keep each term within 64 characters.")
            case .tooManyTerms:
                return String(localized: "Use no more than 100 terms.")
            }
        }
    }

    struct Validation: Equatable, Sendable {
        let terms: [String]
        let issue: Issue?
        var text: String { terms.joined(separator: "\n") }
    }

    /// Reject an over-budget edit as a whole. The editor leaves the original
    /// input visible with an error instead of silently dropping user terms.
    static func validate(_ text: String) -> Validation {
        guard text.count <= maximumTextCharacters else {
            return Validation(terms: [], issue: .textTooLong)
        }
        var seen = Set<String>()
        var terms: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let term = cleaned(line)
            guard !term.isEmpty else { continue }
            guard term.count <= maximumTermCharacters else {
                return Validation(terms: [], issue: .termTooLong)
            }
            let identity = term.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(identity).inserted else { continue }
            terms.append(term)
            guard terms.count <= maximumTerms else {
                return Validation(terms: [], issue: .tooManyTerms)
            }
        }
        return Validation(terms: terms, issue: nil)
    }

    /// A corrupt stored value or an invalid direct request must not bypass
    /// the limits. All-or-nothing matches what Settings allows users to save.
    static func normalized(_ phrases: [String]) -> [String] {
        guard phrases.count <= maximumTextCharacters + 1 else { return [] }
        var characterCount = 0
        for phrase in phrases {
            characterCount += phrase.count
            if characterCount > maximumTextCharacters { return [] }
        }
        let validation = validate(phrases.joined(separator: "\n"))
        return validation.issue == nil ? validation.terms : []
    }

    /// Keep complete terms within Whisper's context budget. A long list uses
    /// its first terms, as explained in Settings; no mid-term token clipping.
    /// The encoder is injected so the budget is testable without a model.
    static func whisperPromptTokens(language: String?, contextualStrings: [String],
                                    encode: (String) -> [Int]) -> [Int]? {
        var prompt = whisperPrimer(language: language)
        var tokens = prompt.isEmpty ? [] : encode(prompt)
        var hasCustomTerm = false
        guard tokens.count <= whisperPromptTokenLimit else { return nil }
        for term in normalized(contextualStrings) {
            let separator = hasCustomTerm ? ", " : " "
            let candidate = prompt.isEmpty ? term : prompt + separator + term
            let candidateTokens = encode(candidate)
            guard candidateTokens.count <= whisperPromptTokenLimit else { break }
            prompt = candidate
            tokens = candidateTokens
            hasCustomTerm = true
        }
        return tokens.isEmpty ? nil : tokens
    }

    private static func whisperPrimer(language: String?) -> String {
        switch language {
        case "zh":
            return "以下是普通话的转写，其中夹杂英文技术词汇，例如 git commit、Docker、SSH。"
        case "yue":
            return "以下是粵語嘅轉寫，其中夾雜英文技術詞彙，例如 git commit、Docker、SSH。"
        case "ja":
            return "以下は日本語の書き起こしで、git commit や Docker などの英語の技術用語が混在します。"
        default:
            return ""
        }
    }

    private static func cleaned(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                result.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar),
                      scalar.properties.generalCategory != .format {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }
}
