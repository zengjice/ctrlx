import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

public struct CodexWorkflowTranscript: AgentWorkflowTranscriptParser {
    private let conversationID: String
    private let nativeTurnID: String
    private let agentName: String
    private var sessionMatches = false
    private var outcome: AgentWorkflowTranscriptOutcome?
    private var activityLog: AgentTurnActivityLog?

    public init(conversationID: String, nativeTurnID: String, agentName: String = "Codex") {
        self.conversationID = conversationID
        self.nativeTurnID = nativeTurnID
        self.agentName = agentName
    }

    public var startMarkers: [String] {
        [nativeTurnID]
    }

    public var readsSessionHeader: Bool {
        true
    }

    public var recoveredCompletion: AgentWorkflowTranscriptOutcome? {
        outcome
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

    public mutating func updateCandidate(_: String) -> AgentWorkflowTranscriptOutcome? {
        outcome
    }

    public func isTurnStart(_ line: Data) throws -> Bool {
        guard
            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            record["type"] as? String == "event_msg",
            let payload = record["payload"] as? [String: Any] else { return false }
        return payload["turn_id"] as? String == nativeTurnID
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
        case "item_completed":
            if
                outcome == nil, activityLog != nil,
                (payload["thread_id"] as? String).map({ $0 == conversationID }) ?? true,
                let item = payload["item"] as? [String: Any] {
                recordActivity(item, timestamp: AgentTurnActivity.parseTimestamp(record["timestamp"] as? String))
            }
            return nil
        case "task_complete",
             "turn_complete":
            if let error = payload["error"], !(error is NSNull) {
                let reason = (error as? [String: Any])?["message"] as? String
                    ?? "The native \(agentName) turn completed with an error."
                outcome = .failed(reason)
                return outcome
            }
            guard let answer = payload["last_agent_message"] as? String, !answer.isEmpty else {
                outcome = .failed("The native \(agentName) turn has no final answer to hand off.")
                return outcome
            }
            outcome = .succeeded(answer)
            return outcome
        case "turn_aborted":
            outcome = .failed("The native \(agentName) turn was interrupted.")
            return outcome
        default:
            return nil
        }
    }

    private mutating func recordActivity(_ item: [String: Any], timestamp: Date?) {
        guard let id = item["id"] as? String else { return }
        switch item["type"] as? String {
        case "AgentMessage" where item["phase"] as? String == "commentary":
            let blocks = item["content"] as? [[String: Any]] ?? []
            if let text = blocks.lazy.compactMap({ $0["text"] as? String }).first {
                activityLog?.record(id: id, kind: .update, text: text, timestamp: timestamp)
            }
        case "CommandExecution":
            let parsed = (item["parsed_cmd"] as? [[String: Any]])?.first
            switch item["status"] as? String {
            case "completed":
                switch parsed?["type"] as? String {
                case "read":
                    let name = (parsed?["name"] as? String).map { ($0 as NSString).lastPathComponent }
                    activityLog?.record(id: id, kind: .file, text: name.map { "Read \($0)" } ?? "Read a file", timestamp: timestamp)
                case "search":
                    activityLog?.record(id: id, kind: .search, text: "Searched files", timestamp: timestamp)
                case "list_files":
                    activityLog?.record(id: id, kind: .file, text: "Listed files", timestamp: timestamp)
                default:
                    let name = Self.commandName(parsed?["cmd"] as? String)
                    activityLog?.record(id: id, kind: .command, text: name.map { "Ran \($0)" } ?? "Ran a command", timestamp: timestamp)
                }
            case "failed":
                activityLog?.record(id: id, kind: .command, text: "Command failed", timestamp: timestamp)
            default: break
            }
        case "FileChange":
            switch item["status"] as? String {
            case "completed": activityLog?.record(id: id, kind: .file, text: "Edited files", timestamp: timestamp)
            case "failed": activityLog?.record(id: id, kind: .file, text: "File edit failed", timestamp: timestamp)
            default: break
            }
        case "McpToolCall":
            let tool = item["tool"] as? String
            switch item["status"] as? String {
            case "completed": activityLog?.record(id: id, kind: .tool, text: tool.map { "Called \($0)" } ?? "Called a tool", timestamp: timestamp)
            case "failed": activityLog?.record(id: id, kind: .tool, text: tool.map { "\($0) failed" } ?? "Tool call failed", timestamp: timestamp)
            default: break
            }
        case "ImageView":
            activityLog?.record(id: id, kind: .file, text: "Viewed an image", timestamp: timestamp)
        case "Extension" where item["kind"] as? String == "web.search":
            activityLog?.record(id: id, kind: .search, text: "Searched the web", timestamp: timestamp)
        default: break
        }
    }

    private static func commandName(_ command: String?) -> String? {
        guard let word = command?.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else { return nil }
        let name = (String(word) as NSString).lastPathComponent
        guard name.utf8.count <= 64, name.range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return name
    }
}
