import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Validated against native Claude Code 2.1.308, including a Stop hook which
/// blocks the first answer and makes the same prompt continue to a new answer.
public struct ClaudeWorkflowTranscript: AgentWorkflowTranscriptParser {
    private let conversationID: String
    private let nativeTurnID: String
    private let prompt: String
    private let candidate: String
    private var ancestors: Set<String> = []
    private var messageID: String?
    private var answer: [String] = []
    private var isEndTurn = false

    public init(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) {
        self.conversationID = conversationID
        self.nativeTurnID = nativeTurnID
        self.prompt = prompt
        self.candidate = candidate
    }

    public mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        guard
            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            record["sessionId"] as? String == conversationID,
            record["isSidechain"] as? Bool == false,
            let id = record["uuid"] as? String,
            let type = record["type"] as? String else { return nil }

        if ancestors.isEmpty {
            // Rejected submissions have no user message or promptId. Native
            // metadata and the full, invocation-specific input bind the failure.
            if
                type == "system", record["subtype"] as? String == "informational",
                record["preventContinuation"] as? Bool == true,
                let submission = record["promptSubmitEnding"] as? [String: Any],
                let ending = submission["ending"] as? [String: Any],
                ending["kind"] as? String == "blocked_by_hook",
                prompt.contains("[CtrlX workflow invocation: "),
                let content = record["content"] as? String,
                content.hasPrefix("UserPromptSubmit operation blocked by hook:\n"),
                content.hasSuffix("\nOriginal prompt: " + prompt) {
                return .failed(ending["reason"] as? String ?? "The native Claude submission was rejected by a hook.")
            }
            // Submission text was matched before accepting this native prompt ID.
            // The persisted user message may contain expanded skills or images.
            guard type == "user", record["promptId"] as? String == nativeTurnID else { return nil }
            ancestors.insert(id)
            return nil
        }
        guard
            let parent = record["parentUuid"] as? String, ancestors.contains(parent),
            ancestors.insert(id).inserted else { return nil }
        guard ancestors.count <= 100_000 else {
            throw AgentWorkflowError("The native turn is too large to verify automatically.")
        }

        if type == "user" {
            // Stop-hook feedback belongs to this prompt, but a new human prompt
            // must never complete the workflow invocation that preceded it.
            guard record["promptId"] as? String == nativeTurnID else {
                return .failed("A different user prompt interrupted this workflow turn.")
            }
            messageID = nil
            answer = []
            isEndTurn = false
        } else if type == "assistant", let message = record["message"] as? [String: Any] {
            guard let nextMessageID = message["id"] as? String else { return nil }
            if nextMessageID != messageID {
                messageID = nextMessageID
                answer = []
            }
            isEndTurn = message["stop_reason"] as? String == "end_turn"
                && record["isApiErrorMessage"] as? Bool != true
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
                if let text = block["text"] as? String {
                    answer.append(text)
                }
            }
        } else if type == "system", record["subtype"] as? String == "stop_hook_summary" {
            guard
                isEndTurn, !candidate.isEmpty, answer.joined(separator: "\n") == candidate,
                let errors = record["hookErrors"] as? [Any], errors.isEmpty,
                let context = record["hookAdditionalContext"] as? [Any], context.isEmpty,
                record["preventedContinuation"] as? Bool == false,
                record["stopReason"] as? String == "" else { return nil }
            return .succeeded(candidate)
        }
        return nil
    }
}
