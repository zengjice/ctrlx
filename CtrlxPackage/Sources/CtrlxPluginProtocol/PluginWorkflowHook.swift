import CtrlxNetworking
import Foundation

/// Shared hook envelope; each plugin chooses its native correlation key.
/// Missing native IDs deliberately disable automatic handoff on older CLIs.
public enum PluginWorkflowHook {
    public static let bridgeVersion = 1

    public static func addingEvidence(to event: PluginEvent, from frame: IngressFrame, nativeTurnKey: String) -> PluginEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
            object["agent_id"] == nil || object["agent_id"] is NSNull else { return event }
        var result = event
        let version = Int(frame.context["CTRLX_WORKFLOW_VERSION"] ?? "") ?? 0
        result.workflowBridgeVersion = frame.context["CTRLX_INGRESS_ACK"] == "1" ? max(0, version) : 0
        if let turn = nativeTurn(in: object, key: nativeTurnKey), let name = object["hook_event_name"] as? String {
            result.workflow = self.event(in: object, name: name, turn: turn)
            let reply = object["last_assistant_message"]
            if name == "Stop", reply is NSNull || reply as? String == "" {
                result.emptyStopTurn = turn
            }
        }
        return result
    }

    public static func event(payload: Data, nativeTurnKey: String) -> PluginWorkflowEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            object["agent_id"] == nil || object["agent_id"] is NSNull,
            let turn = nativeTurn(in: object, key: nativeTurnKey),
            let name = object["hook_event_name"] as? String
        else { return nil }
        return event(in: object, name: name, turn: turn)
    }

    private static func nativeTurn(in object: [String: Any], key: String) -> PluginWorkflowTurn? {
        guard
            let turnID = object[key] as? String, !turnID.isEmpty,
            let transcript = object["transcript_path"] as? String, transcript.hasPrefix("/")
        else { return nil }
        return .init(nativeTurnID: turnID, transcriptPath: transcript)
    }

    private static func event(in object: [String: Any], name: String, turn: PluginWorkflowTurn) -> PluginWorkflowEvent? {
        switch name {
        case "UserPromptSubmit":
            guard let prompt = object["prompt"] as? String else { return nil }
            return .init(kind: .submitted, nativeTurnID: turn.nativeTurnID, transcriptPath: turn.transcriptPath, text: prompt)
        case "Stop":
            guard let answer = object["last_assistant_message"] as? String, !answer.isEmpty else { return nil }
            // Do not reuse the UI's heuristic finality classifier for dispatch.
            // Conservatively retain a candidate while any native background work
            // remains; a later Stop/transcript event can establish completion.
            let pending = ["background_tasks", "session_crons"].contains { key in
                guard let value = object[key], !(value is NSNull) else { return false }
                guard let entries = value as? [Any] else { return true }
                return !entries.isEmpty
            }
            return .init(kind: .stopCandidate, nativeTurnID: turn.nativeTurnID, transcriptPath: turn.transcriptPath, text: answer, hasPendingWork: pending)
        case "StopFailure":
            let reason = (object["error_details"] as? String)
                ?? (object["error"] as? String)
                ?? (object["error_type"] as? String)
                ?? "The Agent failed before completing this turn."
            return .init(kind: .failed, nativeTurnID: turn.nativeTurnID, transcriptPath: turn.transcriptPath, text: reason)
        default:
            return nil
        }
    }
}
