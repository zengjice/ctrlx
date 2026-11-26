import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Validated against native Claude Code 2.1.308, including a Stop hook which
/// blocks the first answer and makes the same prompt continue to a new answer.
public struct ClaudeWorkflowTranscript: AgentWorkflowTranscriptParser {
    private static let rejectionPrefix = "UserPromptSubmit operation blocked by hook:"
    private static let stopFeedbackPrefix = "Stop hook feedback:"
    private let conversationID: String
    private let nativeTurnID: String
    private let prompt: String
    private var candidate: String
    private var completedAnswer: String?
    private var failure: String?
    private var ancestors: Set<String> = []
    private var messageID: String?
    private var answer: [String] = []
    private var isEndTurn = false
    private var activityLog: AgentTurnActivityLog?

    public init(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) {
        self.conversationID = conversationID
        self.nativeTurnID = nativeTurnID
        self.prompt = prompt
        self.candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var startMarkers: [String] {
        guard
            let start = prompt.range(of: "[CtrlX workflow invocation: ", options: .backwards)
            ?? prompt.range(of: "[CtrlX message: ", options: .backwards),
            let end = prompt[start.lowerBound...].firstIndex(of: "]") else { return [nativeTurnID] }
        return [nativeTurnID, String(prompt[start.lowerBound...end])]
    }

    public var recoveredCompletion: AgentWorkflowTranscriptOutcome? {
        if let failure {
            return .failed(failure)
        }
        guard let completedAnswer, !completedAnswer.isEmpty else { return nil }
        return .succeeded(completedAnswer)
    }

    public var tracksCompletionAtEnd: Bool {
        true
    }

    public var activity: [AgentTurnActivity] {
        activityLog?.entries ?? []
    }

    public var evictedActivityIDs: Set<String> {
        activityLog?.evictedActivityIDs ?? []
    }

    public mutating func trackActivityEvictions(for ids: Set<String>) {
        activityLog?.trackedEvictionIDs = ids
    }

    public mutating func captureActivity(aligningWith saved: [AgentTurnActivity]) {
        activityLog = .init(aligningWith: saved)
    }

    public mutating func beginAppendingActivity() {
        activityLog?.beginAppending()
    }

    public func isTurnStart(_ line: Data) throws -> Bool {
        guard
            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            record["sessionId"] as? String == conversationID,
            record["isSidechain"] as? Bool == false else { return false }
        return submission(in: record) == nativeTurnID
            || (record["type"] as? String == "system"
                && (record["content"] as? String)?.hasSuffix("\nOriginal prompt: " + prompt) == true)
    }

    public func submittedTurnID(in line: Data) throws -> String? {
        guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return submission(in: record)
    }

    public func submittedInput(in line: Data) throws -> String? {
        guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any], submission(in: record) != nil else { return nil }
        let content = (record["message"] as? [String: Any])?["content"]
        if let text = content as? String {
            return text
        }
        let text = (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } ?? []
        return text.isEmpty ? nil : text.joined(separator: "\n")
    }

    private func submission(in record: [String: Any]) -> String? {
        guard
            record["type"] as? String == "user",
            record["sessionId"] as? String == conversationID,
            record["isSidechain"] as? Bool == false, record["isMeta"] as? Bool != true else { return nil }
        let content = (record["message"] as? [String: Any])?["content"]
        if let text = content as? String, text.hasPrefix(Self.stopFeedbackPrefix) {
            return nil
        }
        if
            let blocks = content as? [[String: Any]], blocks.contains(where: {
                $0["type"] as? String == "tool_result"
                    || ($0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix(Self.stopFeedbackPrefix) == true)
            }) {
            return nil
        }
        return record["promptId"] as? String
    }

    public var submissionRejectionMarker: String? {
        Self.rejectionPrefix
    }

    public func rejectsSubmission(_ line: Data, during window: Range<Date>) throws -> Bool {
        guard
            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            let timestamp = AgentTurnActivity.parseTimestamp(record["timestamp"] as? String),
            window.contains(timestamp) else { return false }
        return rejectionReason(in: record) != nil
    }

    private func rejectionReason(in record: [String: Any]) -> String? {
        guard
            !prompt.isEmpty, let id = record["uuid"] as? String, !id.isEmpty,
            record["sessionId"] as? String == conversationID, record["isSidechain"] as? Bool == false,
            record["type"] as? String == "system", record["subtype"] as? String == "informational",
            record["preventContinuation"] as? Bool == true,
            let submission = record["promptSubmitEnding"] as? [String: Any],
            let ending = submission["ending"] as? [String: Any],
            ending["kind"] as? String == "blocked_by_hook",
            let content = record["content"] as? String,
            content.hasPrefix(Self.rejectionPrefix + "\n"),
            let original = content.range(of: "\nOriginal prompt: "),
            content[original.upperBound...] == prompt else { return nil }
        return ending["reason"] as? String ?? "The native Claude submission was rejected by a hook."
    }

    public mutating func updateCandidate(_ candidate: String) -> AgentWorkflowTranscriptOutcome? {
        self.candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !self.candidate.isEmpty && completedAnswer == self.candidate ? .succeeded(self.candidate) : nil
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
                prompt.contains("[CtrlX workflow invocation: ") || prompt.contains("[CtrlX message: "),
                let reason = rejectionReason(in: record) {
                failure = reason
                return .failed(reason)
            }
            // Submission text was matched before accepting this native prompt ID.
            // The persisted user message may contain expanded skills or images.
            guard submission(in: record) == nativeTurnID else { return nil }
            failure = nil
            ancestors.insert(id)
            return nil
        }
        guard
            let parent = record["parentUuid"] as? String, ancestors.contains(parent) else { return nil }
        if let submitted = submission(in: record), submitted != nativeTurnID {
            // A later human task must not invalidate a completed turn while its
            // Stop notification is in flight, or join that turn's ancestry.
            guard completedAnswer == nil else { return nil }
            let reason = "A different user prompt interrupted this workflow turn."
            failure = reason
            return .failed(reason)
        }
        guard ancestors.insert(id).inserted else { return nil }
        guard ancestors.count <= 100_000 else {
            throw AgentWorkflowError("The native turn is too large to verify automatically.")
        }

        if type == "user" {
            failure = nil
            completedAnswer = nil
            messageID = nil
            answer = []
            isEndTurn = false
        } else if type == "assistant", let message = record["message"] as? [String: Any] {
            completedAnswer = nil
            guard let nextMessageID = message["id"] as? String else { return nil }
            if nextMessageID != messageID {
                messageID = nextMessageID
                answer = []
            }
            let stopReason = message["stop_reason"] as? String
            isEndTurn = stopReason == "end_turn"
                && record["isApiErrorMessage"] as? Bool != true
            let timestamp = activityLog == nil ? nil : AgentTurnActivity.parseTimestamp(record["timestamp"] as? String)
            let blocks = message["content"] as? [[String: Any]] ?? []
            for (index, block) in blocks.enumerated() {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String else { continue }
                    answer.append(text)
                    if stopReason == "tool_use" {
                        activityLog?.record(id: "\(id):\(index)", kind: .update, text: text, timestamp: timestamp)
                    }
                case "tool_use":
                    if activityLog != nil, let toolID = block["id"] as? String, let name = block["name"] as? String {
                        activityLog?.record(id: toolID, kind: .tool, text: "Called \(name)", timestamp: timestamp)
                    }
                default: break
                }
            }
        } else if type == "system", record["subtype"] as? String == "stop_hook_summary" {
            completedAnswer = nil
            guard
                isEndTurn,
                let errors = record["hookErrors"] as? [Any], errors.isEmpty,
                let context = record["hookAdditionalContext"] as? [Any], context.isEmpty,
                record["preventedContinuation"] as? Bool == false,
                record["stopReason"] as? String == "" else { return nil }
            // Native Stop trims the text while the transcript retains outer whitespace.
            let final = answer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            completedAnswer = final
            return !candidate.isEmpty && final == candidate ? .succeeded(final) : nil
        }
        return nil
    }
}
