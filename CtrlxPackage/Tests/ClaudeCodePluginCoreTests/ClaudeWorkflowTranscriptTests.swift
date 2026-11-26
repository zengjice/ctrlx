import CtrlxPluginProtocol
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeWorkflowTranscriptTests {
    @Test(arguments: 300...399)
    func automaticHandoffAcceptsConfiguredCLIRange(patch: Int) {
        let provider: any AgentWorkflowProviding = ClaudeCodePluginCore()
        #expect(provider.workflowRuntimeIssue(cliVersion: "2.1.\(patch) (Claude Code)") == nil)
    }

    @Test
    func unavailableCLIVersionDoesNotBlockAnExistingAgent() {
        let provider: any AgentWorkflowProviding = ClaudeCodePluginCore()
        #expect(provider.workflowRuntimeIssue(cliVersion: nil) == nil)
        #expect(provider.workflowRuntimeIssue(cliVersion: "") == nil)
    }

    @Test
    func automaticHandoffRejectsOutsideRangeAndUnknownCLIFormats() {
        let provider: any AgentWorkflowProviding = ClaudeCodePluginCore()
        for version in [
            "2.1.299 (Claude Code)", "2.1.400 (Claude Code)", "2.1.3000 (Claude Code)",
            "2.0.308 (Claude Code)", "2.2.308 (Claude Code)", "3.1.308 (Claude Code)",
            "2.1.0308 (Claude Code)", "2.1.-308 (Claude Code)", "2.1 (Claude Code)",
            "2.1.308-beta (Claude Code)", "2.1.308+build (Claude Code)", "2.1.308 (Claude Code)\n",
            "2.1.308", "codex-cli 0.163.0",
        ] {
            #expect(provider.workflowRuntimeIssue(cliVersion: version) != nil, "Unexpectedly accepted: \(version)")
        }
        let issue = provider.workflowRuntimeIssue(cliVersion: "2.1.400 (Claude Code)")
        #expect(issue?.contains("2.1.300–2.1.399") == true)
        #expect(issue?.contains("Verified build") == false)
    }

    private func record(_ id: String, parent: String?, _ extra: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "session", "isSidechain": false, "uuid": id, "parentUuid": parent as Any? ?? NSNull(),
        ].merging(extra) { _, value in value })
    }

    @Test
    func collapsedImagePasteMatchesTheSameHookBody() throws {
        let body = "Review the patch.\n[CtrlX workflow invocation: fixture]"
        let wrapped = "[Image #1]\n\n<pasted_content id=\"8e79\">\n" + body + "\n</pasted_content id=\"8e79\">\n"
        let parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: "[Image #1]" + body, candidate: "")
        let user = try record("user", parent: nil, ["type": "user", "promptId": "prompt", "message": ["content": [["type": "text", "text": wrapped], ["type": "image", "source": ["type": "base64", "data": "fixture"]]]]])
        #expect(try parser.submittedInput(in: user) == "[Image #1]" + body)
    }

    private func started() throws -> ClaudeWorkflowTranscript {
        var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: "Review", candidate: "Final answer")
        #expect(try parser.consume(record("user", parent: nil, ["type": "user", "promptId": "prompt", "message": ["content": "Review"]])) == nil)
        return parser
    }

    private func answer(_ id: String, parent: String, text: String = "Final answer", extra: [String: Any] = [:]) throws -> Data {
        try record(id, parent: parent, [
            "type": "assistant", "message": ["id": id, "stop_reason": "end_turn", "content": [["type": "text", "text": text]]],
        ].merging(extra) { _, value in value })
    }

    private func summary(_ id: String, parent: String, errors: [String] = [], extra: [String: Any] = [:]) throws -> Data {
        try record(id, parent: parent, [
            "type": "system", "subtype": "stop_hook_summary", "hookErrors": errors,
            "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": "",
        ].merging(extra) { _, value in value })
    }

    @Test(arguments: ["workflow invocation", "message"], [false, true])
    func rejectedSubmissionRequiresNativeMetadataAndTheCompleteInvocationInput(marker: String, wrapped: Bool) throws {
        let prompt = "$review-changes\nReview this task.\n[CtrlX \(marker): 6E81E042-A0E6-4C94-B718-41A79C17F1D8]"
        let input = wrapped ? "<pasted_content id=\"8e79\">\n" + prompt + "\n</pasted_content id=\"8e79\">\n" : prompt
        let fields: [String: Any] = [
            "type": "system", "subtype": "informational", "preventContinuation": true,
            "content": "UserPromptSubmit operation blocked by hook:\n[fixture]: Not allowed.\n\n\nOriginal prompt: " + input,
            "promptSubmitEnding": ["ending": ["kind": "blocked_by_hook", "reason": "Not allowed."], "promptKept": false],
        ]
        for extra: [String: Any] in [
            ["sessionId": "other"], ["isSidechain": true], ["type": "assistant"],
            ["preventContinuation": false], ["promptSubmitEnding": ["ending": ["kind": "accepted"]]],
            ["content": "UserPromptSubmit operation blocked by hook:\n[fixture]\nOriginal prompt: " + prompt + "\nChanged input"],
        ] {
            var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: prompt, candidate: "")
            let line = try record("rejected", parent: "previous", fields.merging(extra) { _, value in value })
            #expect(try parser.isTurnStart(line) == false)
            #expect(try parser.consume(line) == nil)
        }
        var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: prompt, candidate: "")
        let rejection = try record("rejected", parent: "previous", fields)
        #expect(try parser.isTurnStart(rejection))
        #expect(try parser.consume(rejection) == .failed("Not allowed."))
        #expect(parser.recoveredCompletion == .failed("Not allowed."))
        _ = try parser.consume(record("user", parent: "previous", ["type": "user", "promptId": "prompt", "message": ["content": prompt]]))
        #expect(parser.recoveredCompletion == nil)
        _ = try parser.consume(answer("retry-answer", parent: "user"))
        _ = try parser.consume(summary("retry-stop", parent: "retry-answer"))
        #expect(parser.recoveredCompletion == .succeeded("Final answer"))
    }

    @Test
    func toolReplyWithNativeStopWhitespaceNormalizationStillRequiresAnUnblockedSummary() throws {
        var parser = try started()
        parser.captureActivity()
        _ = try parser.consume(record("unrelated-tool", parent: "previous-turn", [
            "type": "assistant", "message": ["id": "other-message", "content": [["type": "tool_use", "id": "other", "name": "Other"]]],
        ]))
        _ = try parser.consume(record("tool", parent: "user", [
            "type": "assistant", "timestamp": "1970-01-01T00:00:01Z",
            "message": ["id": "tool-message", "stop_reason": "tool_use", "content": [
                ["type": "thinking", "thinking": "Private reasoning"],
                ["type": "text", "text": "I’ll check the saved tasks."],
                ["type": "tool_use", "id": "list", "name": "Bash", "input": ["command": "Hidden input"]],
            ]],
        ]))
        _ = try parser.consume(record("tool-result", parent: "tool", ["type": "user", "promptId": "prompt", "message": ["content": [["type": "tool_result", "tool_use_id": "list", "content": "Saved tasks"]]]]))
        _ = try parser.consume(answer("answer", parent: "tool-result", text: " \nFinal answer\n\n"))
        #expect(try parser.consume(summary("blocked", parent: "answer", errors: ["Continue"])) == nil)
        #expect(parser.updateCandidate("Final answer") == nil)
        _ = try parser.consume(answer("final", parent: "blocked", text: "Final answer\n"))
        #expect(try parser.consume(summary("stop", parent: "final")) == .succeeded("Final answer"))
        #expect(parser.activity.map(\.kind) == [.update, .tool])
        #expect(parser.activity.map(\.text) == ["I’ll check the saved tasks.", "Called Bash"])
        #expect(parser.activity.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: 1) })
    }

    @Test
    func whitespaceNormalizationPreservesInternalTextAndLateCandidateChecks() throws {
        var parser = try started()
        _ = try parser.consume(answer("answer", parent: "user", text: "\nFinal\n  answer\n"))
        #expect(try parser.consume(summary("stop", parent: "answer")) == nil)
        #expect(parser.updateCandidate("Final answer") == nil)
        #expect(parser.updateCandidate("  \nFinal\n  answer\r\n") == .succeeded("Final\n  answer"))
        #expect(parser.updateCandidate(" \n ") == nil)
    }

    @Test(arguments: ["tool-result", "feedback", "feedback-block", "meta", "same-id-input", "new-input"])
    func onlyHumanInputsDefineSubmissionBoundaries(kind: String) throws {
        let human = kind == "same-id-input" || kind == "new-input"
        let id = kind == "new-input" ? "next" : "prompt"
        let content: Any = switch kind {
        case "tool-result": [["type": "tool_result", "tool_use_id": "tool", "content": "Result"]]
        case "feedback": "Stop hook feedback: Continue"
        case "feedback-block": [["type": "text", "text": "Stop hook feedback: Continue"]]
        default: "Continue this task"
        }
        let line = try record("input", parent: "previous", [
            "type": "user", "promptId": id, "isMeta": kind == "meta", "message": ["role": "user", "content": content],
        ])
        let parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: "Review", candidate: "")
        #expect(try parser.submittedTurnID(in: line) == (human ? id : nil))
        var resumed = parser
        #expect(try resumed.resumedTurnID(in: line) == (human ? id : nil))
        #expect(try parser.isTurnStart(line) == (human && id == "prompt"))
    }

    @Test
    func onlyDurableUnblockedSummaryCompletes() throws {
        var parser = try started()
        #expect(try parser.consume(answer("answer", parent: "user")) == nil)
        #expect(try parser.consume(summary("stop", parent: "answer")) == .succeeded("Final answer"))
    }

    @Test
    func recoveryWithoutStopCandidateRequiresUnblockedNativeCompletion() throws {
        var parser = try started()
        #expect(parser.updateCandidate("") == nil)
        _ = try parser.consume(answer("proposal", parent: "user"))
        #expect(parser.recoveredCompletion == nil)
        _ = try parser.consume(summary("blocked", parent: "proposal", errors: ["Continue"]))
        #expect(parser.recoveredCompletion == nil)
        _ = try parser.consume(answer("final", parent: "blocked"))
        #expect(try parser.consume(summary("stop", parent: "final")) == nil)
        #expect(parser.recoveredCompletion == .succeeded("Final answer"))
        // A later continuation of this prompt invalidates that earlier answer.
        _ = try parser.consume(record("feedback", parent: "stop", ["type": "user", "promptId": "prompt"]))
        #expect(parser.recoveredCompletion == nil)
    }

    @Test
    func lateCandidateReusesUnblockedSummaryAndRejectsSupersededAnswer() throws {
        var parser = try started()
        #expect(parser.updateCandidate("") == nil)
        _ = try parser.consume(answer("first", parent: "user", text: "First"))
        #expect(try parser.consume(summary("first-stop", parent: "first")) == nil)
        #expect(parser.updateCandidate("Wrong") == nil)
        #expect(parser.updateCandidate("First") == .succeeded("First"))
        _ = try parser.consume(record("feedback", parent: "first-stop", ["type": "user", "promptId": "prompt"]))
        #expect(parser.updateCandidate("First") == nil)
        _ = try parser.consume(answer("second", parent: "feedback"))
        #expect(try parser.consume(summary("blocked", parent: "second", errors: ["Continue"])) == nil)
        #expect(parser.updateCandidate("Final answer") == nil)
        _ = try parser.consume(answer("third", parent: "blocked"))
        #expect(try parser.consume(summary("last-stop", parent: "third")) == .succeeded("Final answer"))
    }

    @Test
    func lateCompletionRemainsBoundToItsTaskAfterHumanStartsAnother() throws {
        var parser = try started()
        #expect(parser.updateCandidate("") == nil)
        _ = try parser.consume(answer("answer", parent: "user"))
        #expect(try parser.consume(summary("stop", parent: "answer")) == nil)
        #expect(try parser.consume(record("human", parent: "stop", ["type": "user", "promptId": "new"])) == nil)
        #expect(try parser.consume(answer("new-answer", parent: "human", text: "Unrelated answer")) == nil)
        #expect(try parser.consume(summary("new-stop", parent: "new-answer")) == nil)
        #expect(parser.updateCandidate("Unrelated answer") == nil)
        #expect(parser.updateCandidate("Final answer") == .succeeded("Final answer"))
    }

    @Test
    func blockedStopContinuesSamePromptUntilNewFinalAnswer() throws {
        var parser = try started()
        #expect(try parser.consume(answer("first", parent: "user", text: "Partial")) == nil)
        #expect(try parser.consume(record("feedback", parent: "first", ["type": "user", "promptId": "prompt", "message": ["content": "Stop hook feedback: continue"]])) == nil)
        #expect(try parser.consume(summary("blocked", parent: "feedback", errors: ["Continue"])) == nil)
        #expect(try parser.consume(answer("second", parent: "blocked")) == nil)
        #expect(try parser.consume(summary("complete", parent: "second")) == .succeeded("Final answer"))
    }

    @Test
    func unrelatedSessionSidechainAndHumanPromptCannotComplete() throws {
        var parser = try started()
        #expect(try parser.consume(answer("side", parent: "user", extra: ["isSidechain": true])) == nil)
        #expect(try parser.consume(summary("side-stop", parent: "side")) == nil)
        #expect(try parser.consume(answer("foreign", parent: "user", extra: ["sessionId": "other"])) == nil)
        #expect(try parser.consume(summary("foreign-stop", parent: "foreign")) == nil)
        #expect(try parser.consume(record("human", parent: "user", ["type": "user", "promptId": "new", "message": ["content": "Different task"]])) == .failed("A different user prompt interrupted this workflow turn."))
    }

    @Test
    func hookErrorsAndAdditionalContextPreventHandoffEvenWithFinalText() throws {
        for extra: [String: Any] in [["hookErrors": ["Continue"]], ["hookAdditionalContext": ["New task"]], ["preventedContinuation": true], ["stopReason": "Stop blocked"]] {
            var parser = try started()
            _ = try parser.consume(answer("answer", parent: "user"))
            #expect(try parser.consume(summary("stop", parent: "answer", extra: extra)) == nil)
        }
    }
}
