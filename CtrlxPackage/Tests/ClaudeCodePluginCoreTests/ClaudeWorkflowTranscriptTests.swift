import CtrlxPluginProtocol
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeWorkflowTranscriptTests {
    @Test
    func automaticHandoffRequiresVerifiedNativeCLI() {
        let provider = ClaudeCodePluginCore()
        #expect(provider.workflowRuntimeIssue(cliVersion: "2.1.308 (Claude Code)") == nil)
        for version: String? in [nil, "", "2.1.276 (Claude Code)", "2.1.309 (Claude Code)", "2.1.308-beta (Claude Code)", "codex-cli 0.163.0"] {
            #expect(provider.workflowRuntimeIssue(cliVersion: version) != nil)
        }
    }

    private func record(_ id: String, parent: String?, _ extra: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "session", "isSidechain": false, "uuid": id, "parentUuid": parent as Any? ?? NSNull(),
        ].merging(extra) { _, value in value })
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

    @Test
    func rejectedSubmissionRequiresNativeMetadataAndTheCompleteInvocationInput() throws {
        let prompt = "$review-changes\nReview this task.\n[CtrlX workflow invocation: 6E81E042-A0E6-4C94-B718-41A79C17F1D8]"
        let fields: [String: Any] = [
            "type": "system", "subtype": "informational", "preventContinuation": true,
            "content": "UserPromptSubmit operation blocked by hook:\n[fixture]: Not allowed.\n\n\nOriginal prompt: " + prompt,
            "promptSubmitEnding": ["ending": ["kind": "blocked_by_hook", "reason": "Not allowed."], "promptKept": false],
        ]
        for extra: [String: Any] in [
            ["sessionId": "other"], ["isSidechain": true], ["type": "assistant"],
            ["preventContinuation": false], ["promptSubmitEnding": ["ending": ["kind": "accepted"]]],
            ["content": "UserPromptSubmit operation blocked by hook:\n[fixture]\nOriginal prompt: " + prompt + "\nChanged input"],
        ] {
            var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: prompt, candidate: "")
            #expect(try parser.consume(record("rejected", parent: "previous", fields.merging(extra) { _, value in value })) == nil)
        }
        var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "prompt", prompt: prompt, candidate: "")
        #expect(try parser.consume(record("rejected", parent: "previous", fields)) == .failed("Not allowed."))
    }

    @Test
    func onlyDurableUnblockedSummaryCompletes() throws {
        var parser = try started()
        #expect(try parser.consume(answer("answer", parent: "user")) == nil)
        #expect(try parser.consume(summary("stop", parent: "answer")) == .succeeded("Final answer"))
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
