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

    @Test("Equivalent Shift+Left labels retain the same queue identity", arguments: [
        "shift + ← to answer", "shift+← to answer", "shift← to answer", "Shift + ← to answer",
        "SHIFT+LEFT to answer", "Shift Left to answer", "shiftleft to answer",
        "⇧← to answer", "⇧+← to answer", "⇧ + ← to answer", "⇧ ← to answer", "⇧Left to answer",
        "Shift\t+\tLeft to answer", "⇧\u{00a0}← to\u{2009}answer",
    ])
    func equivalentHint(hint: String) throws {
        let original = try #require(prompt(countLine: "? 1 question · 14s"))
        let updated = try #require(prompt(countLine: "? 1 question · 15s", hint: hint))
        #expect(updated == original)
        #expect(prompt(countLine: "? 1 question", composer: "› draft", hint: hint) == nil)
    }

    @Test("Presentation-only wrapping and inline hints keep the footer recognizable", arguments: [
        ["• Queued follow-up inputs", "? 1 question", "⇧← to answer"],
        ["• Queued follow-up inputs", "? 1 question ⇧← to answer"],
        ["• Queued follow-up inputs ? 1 question", "Shift+Left to answer"],
        ["• Queued follow-up", "inputs", "? 1 question", "⇧← to answer"],
        ["Queued follow-up inputs", "? 1 question", "⇧←", "to answer"],
        ["Queued follow-up inputs", "? 1 question", "Shift +", "Left to", "answer"],
        ["Queued follow-up inputs", "? 1 question · 1m", "02s", "⇧", "← to answer"],
    ])
    func footerLayout(footer: [String]) {
        let lines = ["• Working"] + footer + ["", "› Ask Codex to do anything"]
        #expect(CodexQuestionPrompt(lines: lines, cursorRow: lines.count - 1, cursorColumn: 2)?.count == 1)
    }

    @Test("Unknown bindings and incomplete hints remain manual", arguments: [
        "⇧→ to answer", "⇧←", "⌃⇧← to answer", "Shift+Alt+Left to answer",
        "shift++← to answer", "left to answer", "press ⇧← to answer", "⇧← to answer later",
    ])
    func unknownHint(hint: String) {
        #expect(prompt(countLine: "? 1 question", hint: hint) == nil)
    }

    @Test("Unrelated content cannot become part of a wrapped Questions footer")
    func unrelatedFooterContent() {
        for footer in [
            ["• Queued follow-up inputs", "↳ draft", "? 1 question", "⇧← to answer"],
            ["• Queued follow-up inputs", "? 1 question", "⇧← to answer", "extra output"],
            ["• Queued follow-up inputs", "⇧← to answer", "? 1 question"],
        ] {
            let lines = footer + ["", "› Ask Codex to do anything"]
            #expect(CodexQuestionPrompt(lines: lines, cursorRow: lines.count - 1, cursorColumn: 2) == nil)
        }
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
