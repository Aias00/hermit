import Foundation
import Testing
@testable import Moshpit

@Suite("Voice vocabulary")
struct VoiceVocabularyTests {
    @Test("Terms preserve spelling while normalizing whitespace and Unicode duplicates")
    func normalization() {
        let result = VoiceVocabulary.validate("  Docker  \r\ndocker\n\n git\t commit \u{2028}Hermit\nHErmit\nCafe\u{301}\nCafé\n豆包\n")
        #expect(result.issue == nil)
        #expect(result.terms == ["Docker", "git commit", "Hermit", "Café", "豆包"])
        #expect(result.text == "Docker\ngit commit\nHermit\nCafé\n豆包")
    }

    @Test("Invisible control and formatting characters cannot become recognition context")
    func hiddenCharacters() {
        let result = VoiceVocabulary.validate("\u{202e}Docker\u{202c}\n\u{0000}SSH\u{007f}\n\u{200b}\nCloud\u{00a0}flare")
        #expect(result.issue == nil)
        #expect(result.terms == ["Docker", "SSH", "Cloud flare"])
    }

    @Test("Each configured bound rejects the entire edit without truncating it")
    func limits() {
        #expect(VoiceVocabulary.validate(String(repeating: "术", count: 64)).issue == nil)
        #expect(VoiceVocabulary.validate(String(repeating: "术", count: 65)).issue == .termTooLong)
        let hundred = (0..<100).map { "term\($0)" }
        #expect(VoiceVocabulary.validate(hundred.joined(separator: "\n")).terms == hundred)
        let tooMany = VoiceVocabulary.validate((hundred + ["oneMore"]).joined(separator: "\n"))
        #expect(tooMany.issue == .tooManyTerms)
        #expect(tooMany.terms.isEmpty)
        #expect(VoiceVocabulary.validate(String(repeating: " ", count: 4_096)).issue == nil)
        #expect(VoiceVocabulary.validate(String(repeating: " ", count: 4_097)).issue == .textTooLong)
    }

    @Test("Direct engine requests receive the same sanitization and all-or-nothing bounds")
    func directRequestBounds() {
        #expect(VoiceVocabulary.normalized(["Docker", "docker", " SSH "]) == ["Docker", "SSH"])
        #expect(VoiceVocabulary.normalized(["Docker", String(repeating: "x", count: 65)]).isEmpty)
        #expect(VoiceVocabulary.normalized((0..<101).map { "term\($0)" }).isEmpty)
        #expect(VoiceVocabulary.normalized([String(repeating: "x", count: 4_097)]).isEmpty)
    }

    @Test("Empty vocabulary retains the existing local language primer")
    func existingPrimer() throws {
        let tokens = try #require(VoiceVocabulary.whisperPromptTokens(language: "zh", contextualStrings: [], encode: scalarTokens))
        #expect(decoded(tokens) == "以下是普通话的转写，其中夹杂英文技术词汇，例如 git commit、Docker、SSH。")
        #expect(VoiceVocabulary.whisperPromptTokens(language: nil, contextualStrings: [], encode: scalarTokens) == nil)
        #expect(VoiceVocabulary.whisperPromptTokens(language: "en", contextualStrings: [], encode: scalarTokens) == nil)
    }

    @Test("Custom phrases join the primer and also work without a fixed-language primer")
    func customPrompt() throws {
        let automatic = try #require(VoiceVocabulary.whisperPromptTokens(
            language: nil, contextualStrings: ["Hermit", " hermit ", "Cloudflare"], encode: scalarTokens))
        #expect(decoded(automatic) == "Hermit, Cloudflare")
        let chinese = try #require(VoiceVocabulary.whisperPromptTokens(
            language: "zh", contextualStrings: ["Hermit"], encode: scalarTokens))
        #expect(decoded(chinese).hasSuffix("SSH。 Hermit"))
    }

    @Test("Whisper's context budget keeps full terms in order and never clips a term")
    func boundedPrompt() throws {
        let words = [String(repeating: "a", count: 64),
                     String(repeating: "b", count: 64),
                     String(repeating: "c", count: 64), "later"]
        let tokens = try #require(VoiceVocabulary.whisperPromptTokens(
            language: "en", contextualStrings: words, encode: scalarTokens))
        #expect(tokens.count <= VoiceVocabulary.whisperPromptTokenLimit)
        #expect(decoded(tokens) == words.prefix(2).joined(separator: ", "))
        #expect(!decoded(tokens).contains("c"))
        #expect(!decoded(tokens).contains("later"))
    }

    private func scalarTokens(_ text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    private func decoded(_ tokens: [Int]) -> String {
        String(String.UnicodeScalarView(tokens.compactMap(Unicode.Scalar.init)))
    }
}
