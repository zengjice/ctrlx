import CtrlxNetworking
import Foundation

/// Codex emits these hooks independently of whether a terminal is being viewed.
struct CodexQuestionNotification {
    let callID: String
    let notification: NotificationSpec

    init?(payload: Data) {
        guard
            let hook = try? JSONDecoder().decode(Hook.self, from: payload),
            hook.eventName == "PreToolUse", !hook.callID.isEmpty else { return nil }
        let questions: [String]
        switch hook.toolName {
        case "request_user_input",
             "functions.request_user_input":
            questions = hook.input.questions.compactMap(\.question)
        case "request_user_input_async",
             "functions.request_user_input_async":
            questions = hook.input.questions.compactMap(\.title)
        default:
            return nil
        }
        guard
            !questions.isEmpty, questions.count == hook.input.questions.count,
            questions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        self.callID = hook.callID
        let detail = questions.count == 1 ? questions[0] : "\(questions.count) questions: \(questions.joined(separator: " · "))"
        self.notification = NotificationSpec(
            title: "Codex wants answers", body: String(detail.prefix(256)), isQuestion: true,
            questionID: "\(hook.sessionID):\(hook.callID)"
        )
    }

    private struct Hook: Decodable {
        let eventName: String
        let toolName: String
        let callID: String
        let sessionID: String
        let input: Input

        enum CodingKeys: String, CodingKey {
            case eventName = "hook_event_name"
            case toolName = "tool_name"
            case callID = "tool_use_id"
            case sessionID = "session_id"
            case input = "tool_input"
        }
    }

    private struct Input: Decodable {
        let questions: [Question]
    }

    private struct Question: Decodable {
        let question: String?
        let title: String?
    }
}
