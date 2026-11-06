import Testing
@testable import Moshpit

@Suite("Recognition accuracy against local ground truth")
struct RecognitionAccuracyTests {
    @Test("Chinese substitutions, omissions and insertions remain distinct")
    func characterErrors() throws {
        let wrong = try #require(RecognitionAccuracy.compare(reference: "打开终端", recognized: "打开中端"))
        #expect(wrong.substitutions == 1 && wrong.deletions == 0 && wrong.insertions == 0)
        #expect(wrong.errorRate == 0.25)
        let short = try #require(RecognitionAccuracy.compare(reference: "打开终端", recognized: "打开"))
        #expect(short.deletions == 2 && short.trailingOmissions == 2)
        let extra = try #require(RecognitionAccuracy.compare(reference: "好", recognized: "非常好啊"))
        #expect(extra.insertions == 3 && extra.errorRate == 3)
        let empty = try #require(RecognitionAccuracy.compare(reference: "你好", recognized: ""))
        #expect(empty.deletions == 2 && empty.trailingOmissions == 2 && empty.errorRate == 1)
    }

    @Test("Punctuation normalization is optional; command symbols and case can be compared exactly")
    func normalization() throws {
        let spoken = try #require(RecognitionAccuracy.compare(reference: "你好，世界！", recognized: "你好 世界"))
        #expect(spoken.errorCount == 0)
        let exact = try #require(RecognitionAccuracy.compare(reference: "ls -la", recognized: "ls la", ignorePunctuation: false))
        #expect(exact.deletions == 1)
        let unicode = try #require(RecognitionAccuracy.compare(reference: "é😀", recognized: "e\u{301}😀", ignorePunctuation: false))
        #expect(unicode.errorCount == 0 && unicode.referenceCount == 2)
        #expect(RecognitionAccuracy.compare(reference: "， ！", recognized: "你好") == nil)
    }

    @Test("Technical terms preserve case; repeated numeric tokens require repeated recognition")
    func termsAndNumbers() throws {
        let result = try #require(RecognitionAccuracy.compare(
            reference: "Docker 端口 8080 和 8080，版本 3.14，参数 --force",
            recognized: "docker 端口 8080，版本 3.14，参数 force",
            terms: "Docker\n--force\n3.14\n不存在\nDocker"))
        #expect(result.retainedTerms == ["3.14"])
        #expect(result.missingTerms == ["Docker", "--force"])
        #expect(result.numberCount == 3 && result.retainedNumberCount == 2)
    }

    @Test("Inputs exceeding the comparison budget are rejected rather than silently truncated")
    func boundedInputs() {
        let long = String(repeating: "字", count: RecognitionAccuracy.maximumCharacters + 1)
        #expect(RecognitionAccuracy.compare(reference: long, recognized: "字") == nil)
        #expect(RecognitionAccuracy.compare(reference: "字", recognized: long) == nil)
    }
}
