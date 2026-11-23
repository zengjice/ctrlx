import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexWorkflowTranscriptTests {
    @Test(arguments: 160...179)
    func automaticHandoffAcceptsConfiguredCLIRange(minor: Int) {
        let provider: any AgentWorkflowProviding = CodexPluginCore()
        for patch in [0, 1, 12] {
            #expect(provider.workflowRuntimeIssue(cliVersion: "codex-cli 0.\(minor).\(patch)") == nil)
        }
    }

    @Test
    func unavailableCLIVersionDoesNotBlockAnExistingAgent() {
        let provider: any AgentWorkflowProviding = CodexPluginCore()
        #expect(provider.workflowRuntimeIssue(cliVersion: nil) == nil)
        #expect(provider.workflowRuntimeIssue(cliVersion: "") == nil)
    }

    @Test
    func automaticHandoffRejectsOutsideRangeAndUnknownCLIFormats() {
        let provider: any AgentWorkflowProviding = CodexPluginCore()
        for version in [
            "codex-cli 0.159.99", "codex-cli 0.180.0", "codex-cli 1.160.0",
            "codex-cli 0.16.0", "codex-cli 0.160", "codex-cli 0.160.0.1",
            "codex-cli 0.160.-1", "codex-cli 0.160.01", "codex-cli 0.0160.0",
            "codex-cli 0.163.0-beta", "codex-cli 0.169.0+build", "codex-cli 0.160.0\n",
            "codex-cli 0.170.0-beta", "codex-cli 0.179.0+build", "codex-cli 0.170.01", "codex-cli 0.0170.0",
            "codex-cli 0.160.x", "0.160.0", "2.1.308 (Claude Code)",
        ] {
            #expect(provider.workflowRuntimeIssue(cliVersion: version) != nil, "Unexpectedly accepted: \(version)")
        }
        let issue = provider.workflowRuntimeIssue(cliVersion: "codex-cli 0.180.0")
        #expect(issue?.contains("0.160.x–0.179.x") == true)
        #expect(issue?.contains("Verified build") == false)
    }

    private func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
    }

    @Test
    func requiresMatchingSessionAndNativeTurnCompletion() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        let completion = try record("event_msg", ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Final"])
        #expect(try parser.consume(completion) == nil)
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "agent_message", "turn_id": "turn", "message": "Partial"])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "old", "last_agent_message": "Old"])) == nil)
        #expect(try parser.consume(completion) == .succeeded("Final"))
    }

    @Test
    func activityUsesOnlyVisibleItemsFromTheAcceptedTurn() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        func item(_ item: [String: Any], turn: String = "turn", thread: String = "session") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "timestamp": "1970-01-01T00:00:01.125Z",
                "payload": ["type": "item_completed", "turn_id": turn, "thread_id": thread, "item": item],
            ])
        }
        let update = ["type": "AgentMessage", "id": "update", "phase": "commentary", "content": [["type": "Text", "text": "Checking the source"]]] as [String: Any]
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        _ = try parser.consume(item(update))
        #expect(parser.activity.isEmpty)
        parser.captureActivity()
        _ = try parser.consume(item(update, turn: "old"))
        _ = try parser.consume(item(update, thread: "different"))
        _ = try parser.consume(item(["type": "Reasoning", "id": "private", "summary_text": ["Private reasoning"]]))
        _ = try parser.consume(item(update.merging(["phase": "final_answer"]) { _, new in new }))
        #expect(parser.activity.isEmpty)
        _ = try parser.consume(item(update))
        _ = try parser.consume(item(update))
        _ = try parser.consume(item([
            "type": "CommandExecution", "id": "command", "status": "completed",
            "parsed_cmd": [["type": "unknown", "cmd": "git status --secret=hidden"]], "aggregated_output": "Hidden output",
        ]))
        _ = try parser.consume(item(["type": "McpToolCall", "id": "tool", "status": "failed", "tool": "lookup", "error": "Hidden error"]))
        #expect(parser.activity.map(\.text) == ["Checking the source", "Ran git", "lookup failed"])
        #expect(parser.activity.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: 1.125) })
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Final"])) == .succeeded("Final"))
        _ = try parser.consume(item(["type": "FileChange", "id": "late", "status": "completed"]))
        #expect(parser.activity.count == 3)
    }

    @Test
    func activityKeepsOnlyTheMostRecentBoundedEntries() {
        var activity = AgentTurnActivityLog()
        for index in 0..<30 {
            activity.record(id: String(index), kind: .update, text: String(repeating: "中", count: 500))
        }
        #expect(activity.entries.map(\.id) == (12..<30).map(String.init))
        #expect(activity.entries.last?.text.unicodeScalars.count == 360)
    }

    @Test
    func longActivityOnlyTracksEvictionsRequestedForRecovery() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        parser.captureActivity()
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        for index in 0..<50_000 {
            _ = try parser.consume(record("event_msg", [
                "type": "item_completed", "turn_id": "turn", "item": ["type": "ImageView", "id": String(index)],
            ]))
        }
        #expect(parser.activity.map(\.id) == (49_982..<50_000).map(String.init))
        #expect(parser.evictedActivityIDs.isEmpty)

        parser.trackActivityEvictions(for: ["49982", "49999"])
        _ = try parser.consume(record("event_msg", [
            "type": "item_completed", "turn_id": "turn", "item": ["type": "ImageView", "id": "50000"],
        ]))
        #expect(parser.evictedActivityIDs == ["49982"])
        parser.trackActivityEvictions(for: ["49999"])
        #expect(parser.evictedActivityIDs.isEmpty)
    }

    @Test
    func offlineActivityAfterAnOlderSharedEntryContinuesAfterSavedHistory() {
        var original = AgentTurnActivityLog()
        for index in 1...36 {
            original.record(id: "tool-\(index)", kind: .tool, text: "Tool \(index)")
        }
        var replay = AgentTurnActivityLog(aligningWith: original.entries)
        for index in 1...19 {
            replay.record(id: "tool-\(index)", kind: .tool, text: "Tool \(index)")
        }
        for index in 1...18 {
            replay.record(id: "offline-\(index)", kind: .tool, text: "Offline tool \(index)")
        }
        #expect(replay.entries.map(\.id) == (1...18).map { "offline-\($0)" })
        #expect(replay.entries.compactMap(\.sequence) == Array(37...54))
    }

    @Test
    func rejectedSubmissionHasMatchingCompletionWithoutAnAnswer() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "rejected-turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "task_started", "turn_id": "rejected-turn"])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "old", "last_agent_message": NSNull()])) == nil)
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "rejected-turn", "last_agent_message": NSNull()])) == .failed("The native Codex turn has no final answer to hand off."))
    }

    @Test
    func failedCompletionCannotForwardEarlierText() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Partial", "error": ["message": "Rate limited"]])) == .failed("Rate limited"))
    }

    @Test
    func abortIsFailureAndV2CompletionAliasIsAccepted() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        _ = try parser.consume(record("session_meta", ["id": "session"]))
        #expect(try parser.consume(record("event_msg", ["type": "turn_aborted", "turn_id": "turn"])) == .failed("The native Codex turn was interrupted."))
        #expect(try parser.consume(record("event_msg", ["type": "turn_complete", "turn_id": "turn", "last_agent_message": "Final"])) == .succeeded("Final"))
    }
}
