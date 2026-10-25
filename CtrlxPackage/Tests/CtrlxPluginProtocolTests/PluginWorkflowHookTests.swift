import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxPluginProtocol

struct PluginWorkflowHookTests {
    @Test
    func bridgeCapabilityComesFromAcknowledgedMainHookContext() throws {
        let base = PluginEvent(pluginID: "codex", sessionID: "session", tmuxPane: "%1")
        for (context, expected) in [
            ([:], 0),
            (["CTRLX_WORKFLOW_VERSION": "1"], 0),
            (["CTRLX_INGRESS_ACK": "1", "CTRLX_WORKFLOW_VERSION": "1"], 1),
            (["CTRLX_INGRESS_ACK": "1", "CTRLX_WORKFLOW_VERSION": "2"], 2),
            (["CTRLX_INGRESS_ACK": "1", "CTRLX_WORKFLOW_VERSION": "invalid"], 0),
        ] {
            let frame = try IngressFrame(pluginID: "codex", context: context, payload: payload([
                "hook_event_name": "SessionStart", "CTRLX_WORKFLOW_VERSION": "1",
            ]))
            let event = PluginWorkflowHook.addingEvidence(to: base, from: frame, nativeTurnKey: "turn_id")
            #expect(event.workflowBridgeVersion == expected)
            #expect(event.workflow == nil)
        }
        let child = try IngressFrame(pluginID: "codex", context: ["CTRLX_INGRESS_ACK": "1", "CTRLX_WORKFLOW_VERSION": "1"], payload: payload(["agent_id": "child", "turn_id": "native"]))
        let ignored = PluginWorkflowHook.addingEvidence(to: base, from: child, nativeTurnKey: "turn_id")
        #expect(ignored.workflow == nil && ignored.workflowBridgeVersion == nil)
    }

    private func payload(_ extra: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session_id": "session", "transcript_path": "/private/native.jsonl",
            "hook_event_name": "UserPromptSubmit", "prompt": "$review-changes\nReview the patch.",
        ].merging(extra) { _, value in value })
    }

    @Test(arguments: ["prompt_id", "turn_id"])
    func preservesNativeSubmissionAndPrompt(key: String) throws {
        let event = try #require(PluginWorkflowHook.event(payload: payload([key: "native-turn"]), nativeTurnKey: key))
        #expect(event.kind == .submitted)
        #expect(event.nativeTurnID == "native-turn")
        #expect(event.text == "$review-changes\nReview the patch.")
    }

    @Test
    func rejectsMissingIDsRelativePathsAndSubagents() throws {
        for fields: [String: Any] in [[:], ["turn_id": ""], ["turn_id": "native", "transcript_path": "relative"], ["turn_id": "native", "agent_id": "child"]] {
            #expect(try PluginWorkflowHook.event(payload: payload(fields), nativeTurnKey: "turn_id") == nil)
        }
    }

    @Test
    func stopRemainsCandidateWithPendingWork() throws {
        let event = try #require(PluginWorkflowHook.event(payload: payload([
            "turn_id": "native", "hook_event_name": "Stop", "last_assistant_message": "Waiting for tests",
            "background_tasks": [["id": "task"]],
        ]), nativeTurnKey: "turn_id"))
        #expect(event.kind == .stopCandidate && event.hasPendingWork)
    }

    @Test
    func failureDoesNotBecomeAnAnswer() throws {
        let event = try #require(PluginWorkflowHook.event(payload: payload([
            "prompt_id": "native", "hook_event_name": "StopFailure", "error": "rate_limit",
            "last_assistant_message": "Earlier partial answer",
        ]), nativeTurnKey: "prompt_id"))
        #expect(event.kind == .failed && event.text == "rate_limit")
    }

    @Test
    func legacyPluginEventsDecodeWithoutWorkflow() throws {
        let event = PluginEvent(pluginID: "codex", sessionID: "s", state: .idle)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json.removeValue(forKey: "workflow")
        json.removeValue(forKey: "workflowBridgeVersion")
        let decoded = try JSONDecoder().decode(PluginEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.workflow == nil && decoded.workflowBridgeVersion == nil)
    }
}
