import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexWorkflowTranscriptTests {
    @Test
    func automaticHandoffRequiresVerifiedNativeCLI() {
        let provider = CodexPluginCore()
        #expect(provider.workflowRuntimeIssue(cliVersion: "codex-cli 0.163.0") == nil)
        for version: String? in [nil, "", "codex-cli 0.162.1", "codex-cli 0.164.0", "codex-cli 0.163.0-beta", "2.1.308 (Claude Code)"] {
            #expect(provider.workflowRuntimeIssue(cliVersion: version) != nil)
        }
    }

    private func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
    }

    @Test
    func requiresMatchingSessionAndNativeTurnCompletion() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        let completion = try record("event_msg", ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Final"])
        #expect(try parser.consume(completion) == nil)
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "agent_message", "turn_id": "turn", "message": "Partial"])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "old", "last_agent_message": "Old"])) == nil)
        #expect(try parser.consume(completion) == .succeeded("Final"))
    }

    @Test
    func rejectedSubmissionHasMatchingCompletionWithoutAnAnswer() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "rejected-turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "task_started", "turn_id": "rejected-turn"])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "old", "last_agent_message": NSNull()])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "rejected-turn", "last_agent_message": NSNull()])) == .failed("The native Codex turn has no final answer to hand off."))
    }

    @Test
    func failedCompletionCannotForwardEarlierText() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Partial", "error": ["message": "Rate limited"]])) == .failed("Rate limited"))
    }

    @Test
    func abortIsFailureAndV2CompletionAliasIsAccepted() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "turn_aborted", "turn_id": "turn"])) == .failed("The native Codex turn was interrupted."))
        #expect(try parser.consume(record("event_msg", ["type": "turn_complete", "turn_id": "turn", "last_agent_message": "Final"])) == .succeeded("Final"))
    }
}
