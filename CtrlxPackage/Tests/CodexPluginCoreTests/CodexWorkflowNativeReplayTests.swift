import Foundation
import Testing
@testable import CodexPluginCore

/// Redacted structural replay from an isolated Codex CLI 0.163.0 invocation.
struct CodexWorkflowNativeReplayTests {
    @Test
    func completionUsesDurableNativeTurn() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        let outcomes = try Self.records.split(separator: "\n").compactMap { try parser.consume(Data($0.utf8)) }
        #expect(outcomes == [.succeeded("WORKFLOW_CODEX_PROBE_OK")])
    }

    private static let records = #"""
    {"type":"session_meta","payload":{"id":"session","cli_version":"0.163.0"}}
    {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
    {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn"}}
    {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn"}}
    {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"WORKFLOW_CODEX_PROBE_OK","turn_id":"turn"}}
    """#
}
