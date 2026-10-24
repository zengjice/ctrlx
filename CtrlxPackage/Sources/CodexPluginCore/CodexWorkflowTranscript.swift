import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

public struct CodexWorkflowTranscript: AgentWorkflowTranscriptParser {
    private let conversationID: String
    private let nativeTurnID: String
    private var sessionMatches = false

    public init(conversationID: String, nativeTurnID: String) {
        self.conversationID = conversationID
        self.nativeTurnID = nativeTurnID
    }

    public mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        guard
            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = record["payload"] as? [String: Any] else { return nil }
        if record["type"] as? String == "session_meta" {
            sessionMatches = payload["id"] as? String == conversationID
            return nil
        }
        guard
            sessionMatches, record["type"] as? String == "event_msg",
            payload["turn_id"] as? String == nativeTurnID else { return nil }
        switch payload["type"] as? String {
        case "task_complete",
             "turn_complete":
            if let error = payload["error"], !(error is NSNull) {
                let reason = (error as? [String: Any])?["message"] as? String
                    ?? "The native Codex turn completed with an error."
                return .failed(reason)
            }
            guard let answer = payload["last_agent_message"] as? String, !answer.isEmpty else {
                return .failed("The native Codex turn has no final answer to hand off.")
            }
            return .succeeded(answer)
        case "turn_aborted":
            return .failed("The native Codex turn was interrupted.")
        default:
            return nil
        }
    }
}
