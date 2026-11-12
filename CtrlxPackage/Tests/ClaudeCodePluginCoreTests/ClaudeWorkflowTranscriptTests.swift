import CtrlxPluginProtocol
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeWorkflowTranscriptTests {
    @Test(arguments: 300...319)
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
            "2.1.299 (Claude Code)", "2.1.320 (Claude Code)", "2.1.3000 (Claude Code)",
            "2.0.308 (Claude Code)", "2.2.308 (Claude Code)", "3.1.308 (Claude Code)",
            "2.1.0308 (Claude Code)", "2.1.-308 (Claude Code)", "2.1 (Claude Code)",
            "2.1.308-beta (Claude Code)", "2.1.308+build (Claude Code)", "2.1.308 (Claude Code)\n",
            "2.1.308", "codex-cli 0.163.0",
        ] {
            #expect(provider.workflowRuntimeIssue(cliVersion: version) != nil, "Unexpectedly accepted: \(version)")
        }
        let issue = provider.workflowRuntimeIssue(cliVersion: "2.1.320 (Claude Code)")
        #expect(issue?.contains("2.1.300–2.1.319") == true)
        #expect(issue?.contains("Verified build") == false)
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
