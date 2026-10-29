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
        ["⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /status"],
        ["⚠ weekly limit: only 1% left · resets at 09:05 · /status"],
        ["⚠ weekly limit: 13% left · resets at 2:43 PM on 4 Nov · /status"],
        ["⚠ weekly limit: only 1% left · resets at 12:05 AM · /status"],
        ["⚠ weekly limit: 13% left · resets at", "14:43 on 4 Nov · /status"],
        ["⚠ weekly limit:", "only 13% left · resets at 14:43 on 4 Nov", "· /status"],
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
            ["⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /status"],
            ["⚠ weekly limit: 13% left · resets at", "14:44 on 4 Nov · /status"],
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
        "⚠ weekly limit: 13% left · resets at",
        "⚠ weekly limit: 13% left · resets at · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 on · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov ·",
        "⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /unknown",
        "⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /status extra output",
        "⚠ weekly limit: 13% left · resets at 24:00 · /status",
        "⚠ weekly limit: 13% left · resets at 14:60 · /status",
        "⚠ weekly limit: 13% left · resets at 0:05 AM · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 PM · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 on 0 Nov · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 on 32 Nov · /status",
        "⚠ weekly limit: 13% left · resets at 14:43 on 4 unknown · /status",
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
        ["⚠ weekly limit: 13% left · resets at 14:43", "↳ draft", "on 4 Nov · /status"],
        ["⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /status", "extra output"],
    ])
    func unrelatedOutput(warning: [String]) {
        #expect(prompt(warning: warning) == nil)
    }

    @Test("Known warnings do not relax draft, cursor or answer-hint checks", arguments: [
        "⚠ weekly limit: only 1% left",
        "⚠ weekly limit: 13% left · resets at 14:43 on 4 Nov · /status",
    ])
    func guards(text: String) {
        let warning = [text]
        #expect(prompt(warning: warning, composer: "› draft") == nil)
        #expect(prompt(warning: warning, cursorColumn: 3) == nil)
        #expect(prompt(warning: warning, hint: "⇧→ to answer") == nil)
        #expect(prompt(warning: warning, hint: "⇧←") == nil)
    }
}
