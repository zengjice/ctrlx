import Foundation
import Testing
@testable import ClaudeCodePluginCore

/// Redacted structural replay from an isolated Claude Code 2.1.308 session.
/// A real Stop hook blocked the first answer; both Stops have the same prompt_id.
/// UUIDs, paths, prompt content, telemetry and thinking were removed or replaced.
struct ClaudeWorkflowNativeReplayTests {
    @Test
    func nativeBlockedStopDoesNotReleaseFirstAnswer() throws {
        for candidate in ["WORKFLOW_FIRST_CANDIDATE", "WORKFLOW_SECOND_FINAL"] {
            var parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "turn", prompt: "__task__", candidate: candidate)
            let outcomes = try Self.records.split(separator: "\n").compactMap { try parser.consume(Data($0.utf8)) }
            if candidate == "WORKFLOW_FIRST_CANDIDATE" {
                #expect(outcomes.isEmpty)
            } else {
                #expect(outcomes == [.succeeded("WORKFLOW_SECOND_FINAL")])
            }
        }
    }

    private static let records = #"""
    {"type":"user","isSidechain":false,"uuid":"record-0","parentUuid":null,"sessionId":"session","promptId":"turn","message":{"role":"user","content":"__task__"}}
    {"type":"attachment","isSidechain":false,"uuid":"record-1","parentUuid":"record-0","sessionId":"session"}
    {"type":"attachment","isSidechain":false,"uuid":"record-2","parentUuid":"record-1","sessionId":"session"}
    {"type":"attachment","isSidechain":false,"uuid":"record-3","parentUuid":"record-2","sessionId":"session"}
    {"type":"attachment","isSidechain":false,"uuid":"record-4","parentUuid":"record-3","sessionId":"session"}
    {"type":"attachment","isSidechain":false,"uuid":"record-5","parentUuid":"record-4","sessionId":"session"}
    {"type":"assistant","isSidechain":false,"uuid":"record-6","parentUuid":"record-5","sessionId":"session","message":{"role":"assistant","stop_reason":"end_turn","id":"message-0","content":[]}}
    {"type":"assistant","isSidechain":false,"uuid":"record-7","parentUuid":"record-6","sessionId":"session","message":{"role":"assistant","stop_reason":"end_turn","id":"message-0","content":[{"type":"text","text":"WORKFLOW_FIRST_CANDIDATE"}]}}
    {"type":"attachment","isSidechain":false,"uuid":"record-8","parentUuid":"record-7","sessionId":"session"}
    {"type":"user","isSidechain":false,"uuid":"record-9","parentUuid":"record-8","sessionId":"session","promptId":"turn","message":{"role":"user","content":"Stop hook feedback: Continue test"}}
    {"type":"attachment","isSidechain":false,"uuid":"record-10","parentUuid":"record-9","sessionId":"session"}
    {"type":"system","isSidechain":false,"subtype":"stop_hook_summary","preventedContinuation":false,"stopReason":"","hasOutput":true,"uuid":"record-11","parentUuid":"record-10","sessionId":"session","hookErrors":["Continue test"],"hookAdditionalContext":[]}
    {"type":"assistant","isSidechain":false,"uuid":"record-12","parentUuid":"record-11","sessionId":"session","message":{"role":"assistant","stop_reason":"end_turn","id":"message-1","content":[]}}
    {"type":"assistant","isSidechain":false,"uuid":"record-13","parentUuid":"record-12","sessionId":"session","message":{"role":"assistant","stop_reason":"end_turn","id":"message-1","content":[{"type":"text","text":"WORKFLOW_SECOND_FINAL"}]}}
    {"type":"system","isSidechain":false,"subtype":"stop_hook_summary","preventedContinuation":false,"stopReason":"","hasOutput":false,"uuid":"record-14","parentUuid":"record-13","sessionId":"session","hookErrors":[],"hookAdditionalContext":[]}
    """#
}
