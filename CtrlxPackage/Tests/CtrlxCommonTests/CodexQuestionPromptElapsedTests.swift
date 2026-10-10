import Testing
@testable import CtrlxCommon

struct CodexQuestionPromptElapsedTests {
    private func prompt(countLine: String, composer: String = "› Ask Codex to do anything", hint: String = "shift+← to answer") -> CodexQuestionPrompt? {
        CodexQuestionPrompt(
            lines: ["• Queued follow-up inputs", countLine, hint, "", composer],
            cursorRow: 4, cursorColumn: 2
        )
    }

    @Test("Question age is optional decoration, not part of the queue identity", arguments: [
        "", " · 0s", " · 14s", " · 59s", " · 1m", " · 1m 02s", " · 1h", " · 1h 2m 3s",
    ], [1, 4])
    func elapsedSuffix(suffix: String, count: Int) {
        let noun = count == 1 ? "question" : "questions"
        #expect(prompt(countLine: "? \(count) \(noun)\(suffix)")?.count == count)
    }

    @Test("Timer updates cannot re-arm a dismissed question")
    func timerIdentity() throws {
        let original = try #require(prompt(countLine: "? 1 question · 14s"))
        let tick = try #require(prompt(countLine: "? 1 question · 15s"))
        #expect(original == tick)
        var state = CodexQuestionExpansionState()
        let firstOpens = state.observe(original.count)
        let tickOpens = state.observe(tick.count)
        #expect(firstOpens)
        #expect(!tickOpens)
    }

    @Test("Codex 0.160's no-plus shortcut has the same queue identity as older versions")
    func noPlusHint() throws {
        let original = try #require(prompt(countLine: "? 1 question · 14s"))
        let current = try #require(prompt(countLine: "? 1 question · 15s", hint: "shift← to answer"))
        #expect(current == original)
        #expect(prompt(countLine: "? 1 question", composer: "› draft", hint: "shift← to answer") == nil)
    }

    @Test("Reject arbitrary, malformed and partial suffixes", arguments: [
        " ·", " 14s", " · pending", " · -1s", " · 1.5s", " · s", " · 14seconds",
        " · 14s later", " · 14s · 15s", " · 1s 2m", " · 1m 2m", " · １s", " · 1d",
    ])
    func invalidSuffix(suffix: String) {
        #expect(prompt(countLine: "? 1 question\(suffix)") == nil)
    }

    @Test("A timer never relaxes count, pluralization or empty-composer checks", arguments: [
        "? 0 questions · 14s", "? 1000 questions · 14s", "? 1 questions · 14s", "? 2 question · 14s",
    ])
    func invalidCount(line: String) {
        #expect(prompt(countLine: line) == nil)
        #expect(prompt(countLine: "? 1 question · 14s", composer: "› draft") == nil)
    }
}
