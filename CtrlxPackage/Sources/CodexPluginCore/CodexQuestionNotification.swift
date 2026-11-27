import CtrlxNetworking
import Foundation

/// Codex emits these hooks independently of whether a terminal is being viewed.
struct CodexQuestionNotification {
    let callID: String
    let notification: NotificationSpec

    static func resolvedIDs(payload: Data) -> [String] {
        guard let hook = try? JSONDecoder().decode(ResolutionHook.self, from: payload) else { return [] }
        if let id = hook.callID, !id.isEmpty {
            let synchronous = ["request_user_input", "functions.request_user_input", "AskUserQuestion"]
            if hook.eventName == "PostToolUseFailure" || (hook.eventName == "PostToolUse" && synchronous.contains(hook.toolName ?? "")) {
                return ["\(hook.sessionID):\(id)"]
            }
        }
        // Async tools return before the answer. Only the correlated reply closes them.
        guard
            hook.eventName == "UserPromptSubmit", let prompt = hook.prompt,
            let start = prompt.range(of: "<send_user_message_question_reply>"),
            let end = prompt.range(of: "</send_user_message_question_reply>", range: start.upperBound..<prompt.endIndex),
            let replies = try? JSONDecoder().decode([Reply].self, from: Data(prompt[start.upperBound..<end.lowerBound].utf8)) else { return [] }
        return replies.compactMap { reply in
            guard
                let item = try? JSONDecoder().decode([JSONValue].self, from: Data(reply.questionItemId.utf8)),
                item.count >= 2, case let .string(tool) = item[0],
                ["request_user_input", "functions.request_user_input", "request_user_input_async", "functions.request_user_input_async"].contains(tool),
                case let .string(callID) = item[1] else { return nil }
            return "\(hook.sessionID):\(callID)"
        }
    }

    private struct ResolutionHook: Decodable {
        let eventName: String
        let sessionID: String
        let toolName: String?
        let callID: String?
        let prompt: String?
        enum CodingKeys: String, CodingKey {
            case eventName = "hook_event_name"
            case sessionID = "session_id"
            case toolName = "tool_name"
            case callID = "tool_use_id"
            case prompt
        }
    }

    private struct Reply: Decodable { let questionItemId: String }

    init?(payload: Data, distribution: CodexDistribution = .codex) {
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
        case "AskUserQuestion" where distribution == .traex:
            questions = hook.input.questions.compactMap(\.question)
        default:
            return nil
        }
        guard
            !questions.isEmpty, questions.count == hook.input.questions.count,
            questions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        self.callID = hook.callID
        let detail = questions.count == 1 ? questions[0] : "\(questions.count) questions: \(questions.joined(separator: " · "))"
        self.notification = NotificationSpec(
            title: "\(distribution.displayName) wants answers", body: String(detail.prefix(256)), isQuestion: true,
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
