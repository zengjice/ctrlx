import Testing
@testable import CtrlxCommon

struct CodexQuestionPromptUsageWarningTests {
    private func prompt(
        warning: [String],
        composer: String = "› Ask Codex to do anything",
        cursorColumn: Int = 2,
        hint: String = "⇧← to answer"
    ) -> CodexQuestionPrompt? {
        let lines = ["• Queued follow-up inputs", "? 1 question · 19s", hint, ""]
            + warning + ["", composer]
        return CodexQuestionPrompt(lines: lines, cursorRow: lines.count - 1, cursorColumn: cursorColumn)
    }

    @Test("Known weekly-limit warnings may wrap between Questions and the empty composer", arguments: [
        ["                              ⚠ weekly limit: 8% left · /status"],
        ["⚠ weekly limit: only 1% left"],
        ["⚠ weekly limit: 0% left · /status"],
        ["⚠ weekly limit: 8% left", "  · /status"],
        ["⚠ weekly limit:", "  only 1% left"],
        ["⚠ weekly limit:", "8% left ·", "/status"],
    ])
    func knownWarning(warning: [String]) {
        #expect(prompt(warning: warning)?.count == 1)
        #expect(prompt(warning: warning, composer: "›")?.count == 1)
    }

    @Test("Changing or removing the usage warning cannot re-arm a dismissed question")
    func warningIdentity() throws {
        var state = CodexQuestionExpansionState()
        let original = try #require(prompt(warning: []))
        let firstOpens = state.observe(original.count)
        #expect(firstOpens)
        for warning in [
            ["⚠ weekly limit: 8% left · /status"],
            ["⚠ weekly limit: only 1% left"],
            ["⚠ weekly limit: only", "1% left"],
            [],
        ] {
            let updated = try #require(prompt(warning: warning))
            #expect(updated == original)
            let reopens = state.observe(updated.count)
            #expect(!reopens)
        }
    }

    @Test("Incomplete or unknown warnings do not clear the queue", arguments: [
        "⚠", "⚠ weekly limit:", "⚠ weekly limit: only 1%", "⚠ weekly limit: 8% left ·",
        "⚠ weekly limit: 8% left · /unknown", "⚠ weekly limit: 8% left extra output",
        "⚠ weekly limit: -1% left", "⚠ weekly limit: 101% left", "⚠ weekly limit: 1.5% left",
        "⚠ weekly limit: １% left", "⚠ weekly limit: +1% left", "⚠ weekly limit: % left",
        "⚠ weekly limit: 8 left", "⚠ daily limit: 8% left", "⚠ unrelated warning",
        "⚠ Heads up, you have less than 10% of your weekly limit left. Run /status for a breakdown.",
    ])
    func unknownWarning(warning: String) {
        #expect(prompt(warning: [warning]) == nil)
    }

    @Test("Known warnings cannot hide unrelated output or queued draft text", arguments: [
        ["extra output", "⚠ weekly limit: 8% left · /status"],
        ["⚠ weekly limit: 8% left · /status", "extra output"],
        ["⚠ weekly limit: 8% left", "↳ draft", "· /status"],
        ["⚠ weekly limit: 8% left", "⚠ weekly limit: only 1% left"],
    ])
    func unrelatedOutput(warning: [String]) {
        #expect(prompt(warning: warning) == nil)
    }

    @Test("Known warnings do not relax draft, cursor or answer-hint checks")
    func guards() {
        let warning = ["⚠ weekly limit: only 1% left"]
        #expect(prompt(warning: warning, composer: "› draft") == nil)
        #expect(prompt(warning: warning, cursorColumn: 3) == nil)
        #expect(prompt(warning: warning, hint: "⇧→ to answer") == nil)
        #expect(prompt(warning: warning, hint: "⇧←") == nil)
    }
}
