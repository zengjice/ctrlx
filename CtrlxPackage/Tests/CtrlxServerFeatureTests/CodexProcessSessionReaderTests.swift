import CtrlxNetworking
import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

/// FD probes inspect every rollout writer in this test process.
@Suite(.serialized)
struct CodexProcessSessionReaderTests {
    private let childID = "01a12863-79a4-7ef0-a50a-2493f7262468"
    private let parentID = "01a10b9d-5efd-72e1-850f-6b6374f064bd"

    @Test("Native cancellation clears only its question without a success/failure hook", arguments: [
        "request_user_input was cancelled before receiving a response",
        "aborted by user after 0.1s",
        "aborted by user after 12.3s",
    ])
    func nativeQuestionCancellation(message: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-question-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-\(childID).jsonl")
        func record(_ type: String, id: String, output: String? = nil) throws -> Data {
            var payload = ["type": type, "call_id": id]
            if let output {
                payload["output"] = output
            } else {
                payload["name"] = "request_user_input"
                payload["arguments"] = #"{"questions":[{"id":"q","header":"Choice","question":"Continue?","options":[{"label":"Yes","description":"Continue"},{"label":"No","description":"Stop"}]}]}"#
            }
            return try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload]) + Data("\n".utf8)
        }
        try (header(childID) + Data("\n".utf8) + record("function_call", id: "sync") + record("function_call", id: "async") + record("function_call_output", id: "async", output: "Question queued")).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let reader = CodexProcessSessionReader()
        let ids = ["\(childID):sync", "\(childID):async"]
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids).isEmpty)
        // Editing/dismissing a notes field produces no abort output. Ordinary
        // tool output containing similar text must also leave questions open.
        try writer.write(contentsOf: record("function_call_output", id: "async", output: #"{"answers":{"q":"aborted by user after 12.3s"}}"#))
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids).isEmpty)
        // Both RespondToModel and turn interruption omit a PostToolUse hook.
        let cancelled = try record("function_call_output", id: "sync", output: message)
        try writer.write(contentsOf: cancelled.dropLast(8))
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids).isEmpty)
        try writer.write(contentsOf: cancelled.suffix(8))
        try writer.write(contentsOf: record("function_call_output", id: "other", output: String(repeating: "x", count: CodexProcessSessionReader.completionLimit * 2)))
        let resolved = await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids)
        #expect(resolved == [ids[0]])
        var pane = PaneState(paneId: "%1", agentSession: .init(paneId: "%1", state: .idle))
        pane.agentSession?.recordQuestion(ids[0])
        #expect(pane.displayedState == .waiting && [pane].pendingSessionCount == 1)
        for id in resolved {
            pane.agentSession?.resolveQuestion(id)
        }
        #expect(pane.displayedState == .idle && [pane].pendingSessionCount == 0)
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids) == [ids[0]])
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: "reused", conversationID: childID, questionIDs: ids).isEmpty)
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: parentID, questionIDs: ids).isEmpty)
        let replay = CodexProcessSessionReader()
        #expect(await replay.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: ids) == [ids[0]])
        try writer.write(contentsOf: record("function_call", id: "next"))
        try writer.write(contentsOf: record("function_call_output", id: "next", output: message))
        #expect(await reader.cancelledQuestionIDs(processID: pid, runtimeID: runtime, conversationID: childID, questionIDs: [ids[1], "\(childID):next"]) == ["\(childID):next"])
    }

    private func header(_ id: String, source: String = "cli", type: String = "session_meta") -> Data {
        Data("{\"type\":\"\(type)\",\"payload\":{\"id\":\"\(id)\",\"forked_from_id\":\"\(parentID)\",\"source\":\"\(source)\"}}".utf8)
    }

    private func event(_ type: String, turn: String? = "01a12863-79a4-7ef0-a50a-2493f7262468", recordType: String = "event_msg") -> Data {
        let id = turn.map { "\"\($0)\"" } ?? "null"
        return Data("{\"type\":\"\(recordType)\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\(id)}}\n".utf8)
    }

    private func failedCompletion(
        _ type: String = "task_complete",
        error: String = #"{"message":"The model is not supported when using Codex with a ChatGPT account.","codex_error_info":"other"}"#
    ) -> Data {
        Data("""
        {"type":"event_msg","payload":{"type":"\(type)","turn_id":"\(childID)","last_agent_message":null,"error":\(error)}}

        """.utf8)
    }

    @Test("Only the latest complete native turn can override cached Working", arguments: ["complete", "turn-complete", "aborted", "active", "new-task", "late-old-completion", "new-context", "unknown-event", "partial", "malformed", "no-turn", "no-start", "truncated-prefix", "token-count"])
    func nativeCompletion(_ scenario: String) throws {
        var data = event("task_started") + event("task_complete")
        switch scenario {
        case "turn-complete": data = event("turn_started") + event("turn_complete")
        case "aborted": data = event("task_started") + event("turn_aborted")
        case "active": data = event("task_started")
        case "new-task": data += event("task_started", turn: parentID)
        case "late-old-completion": data += event("task_started", turn: parentID) + event("task_complete")
        case "new-context": data += event("context", turn: parentID, recordType: "turn_context")
        case "unknown-event": data += event("future-turn-event", turn: parentID)
        case "partial": data += Data("{\"type\":\"event_msg\"".utf8)
        case "malformed": data += Data("{invalid}\n".utf8)
        case "no-turn": data = event("task_started") + event("task_complete", turn: nil)
        case "no-start": data = event("task_complete")
        case "truncated-prefix": data = Data("old truncated record\n".utf8) + data
        case "token-count": data += event("token_count", turn: nil)
        default: break
        }
        #expect(CodexProcessSessionReader.lastTurnCompleted(data, startsAtBeginning: scenario != "truncated-prefix") == ["complete", "turn-complete", "aborted", "truncated-prefix", "token-count"].contains(scenario))
        let turn = try #require(UUID(uuidString: childID))
        #expect(CodexProcessSessionReader.lastTurnCompleted(data, startsAtBeginning: scenario != "truncated-prefix", abortedOrFailedTurnID: turn) == (scenario == "aborted"))
    }

    @Test(
        "A matched turn must record a terminal error before it can clear Working",
        arguments: ["task-complete", "turn-complete", "settings", "new-task", "unknown-event", "transient-error", "null-error", "missing-message"]
    )
    func nativeFailure(_ scenario: String) throws {
        let start = event("task_started")
        var data = start + failedCompletion()
        switch scenario {
        case "turn-complete": data = start + failedCompletion("turn_complete")
        case "settings": data += event("thread_settings_applied", turn: nil)
        case "new-task": data += event("thread_settings_applied", turn: nil) + event("task_started", turn: parentID)
        case "unknown-event": data += event("future-turn-event", turn: nil)
        case "transient-error": data = start + event("error")
        case "null-error": data = start + failedCompletion(error: "null")
        case "missing-message": data = start + failedCompletion(error: "{}")
        default: break
        }
        let turn = try #require(UUID(uuidString: childID))
        #expect(CodexProcessSessionReader.lastTurnCompleted(data, abortedOrFailedTurnID: turn) == ["task-complete", "turn-complete", "settings"].contains(scenario))
    }

    @Test("Completion must come from this process's current unique writable conversation")
    func nativeCompletionWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-idle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-2026-11-06-\(childID).jsonl")
        try (header(childID) + Data("\n".utf8) + event("task_started") + event("task_complete")).write(to: file)
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let reader = CodexProcessSessionReader()
        let interruptedTurn = try #require(UUID(uuidString: parentID))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        #expect(await reader.turnCompleted(processID: pid, runtimeID: runtime))
        let transcript = try #require(await reader.transcriptPath(processID: pid, runtimeID: runtime, conversationID: childID))
        #expect(URL(fileURLWithPath: transcript).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(await reader.transcriptPath(processID: pid, runtimeID: "reused-pid", conversationID: childID) == nil)
        #expect(await reader.transcriptPath(processID: pid, runtimeID: runtime, conversationID: parentID) == nil)
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: "reused-pid"))
        try writer.seekToEnd()
        try writer.write(contentsOf: event("task_started", turn: parentID))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        try writer.write(contentsOf: event("turn_aborted", turn: parentID))
        #expect(await reader.turnCompleted(processID: pid, runtimeID: runtime))
        #expect(await reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: interruptedTurn))
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: parentID, turnID: interruptedTurn))
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: UUID()))
        try writer.write(contentsOf: Data("{partial".utf8))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        try writer.write(contentsOf: Data("}\n".utf8))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        let other = root.appendingPathComponent("rollout-2026-11-06-\(parentID).jsonl")
        try (header(parentID) + Data("\n".utf8) + event("task_started") + event("task_complete")).write(to: other)
        let otherWriter = try FileHandle(forWritingTo: other)
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        try otherWriter.close()
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: header(parentID) + Data("\n".utf8) + event("task_started") + event("task_complete"))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
    }

    @Test("Abort or failure verification selects the named writer while a previous conversation is still open", arguments: [false, true])
    func completionWithPreviousWriterOpen(failed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-abort-writers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("rollout-\(parentID).jsonl")
        let current = root.appendingPathComponent("rollout-\(childID).jsonl")
        try (header(parentID) + Data("\n".utf8) + event("task_started") + event("task_complete")).write(to: previous)
        let completion = failed ? failedCompletion() + event("thread_settings_applied", turn: nil) : event("turn_aborted")
        try (header(childID) + Data("\n".utf8) + event("task_started") + completion).write(to: current)
        let previousWriter = try FileHandle(forWritingTo: previous)
        defer { try? previousWriter.close() }
        let currentWriter = try FileHandle(forWritingTo: current)
        defer { try? currentWriter.close() }
        let reader = CodexProcessSessionReader()
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let interruptedTurn = try #require(UUID(uuidString: childID))
        #expect(await reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: interruptedTurn))
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: parentID, turnID: interruptedTurn))
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: "reused-pid", conversationID: childID, turnID: interruptedTurn))
        #expect(await !reader.turnCompleted(processID: pid, runtimeID: runtime))
        try currentWriter.close()
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: interruptedTurn))
    }

    @Test("Abort verification reads across large image or text records", arguments: [false, true])
    func abortAfterLargeRecord(isText: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-abort-large-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-\(childID).jsonl")
        let start = header(childID) + Data("\n".utf8) + event("task_started")
        let prefix = isText
            ? #"{"type":"event_msg","payload":{"type":"user_message","message":""#
            : #"{"type":"response_item","payload":{"type":"message","content":[{"type":"input_image","image_url":"data:image/png;base64,"#
        let chunkSize = CodexProcessSessionReader.completionLimit
        var body = Data(prefix.utf8) + Data(repeating: 65, count: chunkSize - prefix.utf8.count - 1)
        if isText {
            body.append(contentsOf: "中".utf8)
        }
        body.append(Data(repeating: 65, count: chunkSize + chunkSize / 3))
        let end = Data((isText ? "\",\"turn_id\":\"\(childID)\"}}\n" : "\"}]}}\n").utf8)
        let abort = event("turn_aborted")
        try (start + body + end + abort).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let turn = try #require(UUID(uuidString: childID))
        let reader = CodexProcessSessionReader()

        #expect(await reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("{partial".utf8))
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
        try writer.truncate(atOffset: UInt64(start.count + body.count))
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(#"\q"#.utf8) + end + abort)
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
        if isText {
            try writer.truncate(atOffset: UInt64(start.count + body.count))
            try writer.seekToEnd()
            try writer.write(contentsOf: Data([0xE0, 0x80, 0x80]) + end + abort)
            #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
            try writer.truncate(atOffset: UInt64(start.count + body.count))
            try writer.seekToEnd()
            try writer.write(contentsOf: Data("\",\"turn_id\":\"\(parentID)\"}}\n".utf8) + abort)
            #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
        }
        try writer.truncate(atOffset: UInt64(start.count))
        try writer.seekToEnd()
        try writer.write(contentsOf: event("task_started", turn: parentID) + body + end + abort)
        #expect(await !reader.turnAbortedOrFailed(processID: pid, runtimeID: runtime, conversationID: childID, turnID: turn))
    }

    @Test(
        "Only matching CLI session metadata identifies a rollout; forked_from_id is never the active ID",
        arguments: ["child", "resumed", "resumed-mismatch", "invalid-rollout-id", "parent-mismatch", "subagent", "event", "incomplete", "oversized", "wrong-name"]
    )
    func metadata(scenario: String) {
        var data = header(childID)
        var path = "/custom-codex/sessions/rollout-2026-10-11T08-36-10-\(childID).jsonl"
        switch scenario {
        case "resumed",
             "resumed-mismatch":
            path = "/custom-codex/sessions/rollout-2026-10-11T08-36-10-\(childID)_\(parentID).jsonl"
            if scenario == "resumed-mismatch" {
                data = header(parentID)
            }
        case "invalid-rollout-id":
            path = "/custom-codex/sessions/rollout-2026-10-11T08-36-10-\(childID)_invalid.jsonl"
        case "parent-mismatch": data = header(parentID)
        case "subagent": data = header(childID, source: "exec")
        case "event": data = header(childID, type: "event_msg")
        case "incomplete": data = Data("{\"type\":\"session_meta\"".utf8)
        case "oversized": data.append(Data(repeating: 32, count: CodexProcessSessionReader.headerLimit))
        case "wrong-name": path = "/tmp/\(childID).jsonl"
        default: break
        }
        #expect(CodexProcessSessionReader.sessionID(header: data, path: path) == (["child", "resumed"].contains(scenario) ? childID : nil))
    }

    @Test("The active writer changes independently of Codex process identity")
    func currentWriterChangesWithoutReplacingItsProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-writer-switch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = UUID().uuidString, newID = UUID().uuidString
        func rollout(_ id: String) throws -> URL {
            let file = root.appendingPathComponent("rollout-2026-11-03-\(id).jsonl")
            let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "source": "cli"]])
            try (header + Data("\n".utf8)).write(to: file)
            return file
        }
        let oldFile = try rollout(oldID), newFile = try rollout(newID)
        var writer: FileHandle? = try FileHandle(forWritingTo: oldFile)
        defer { try? writer?.close() }
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let reader = CodexProcessSessionReader()
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == oldID)
        try writer?.close()
        writer = nil
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        writer = try FileHandle(forWritingTo: newFile)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == newID)
        #expect(AgentSessionIdentityClient.processRuntimeID(pid) == runtime)
    }

    @Test("Native FD recovery ignores read-only parent history, rejects ambiguous writers and verifies process lifetime", arguments: [false, true])
    func openWriter(resumed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-codex-writer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = resumed ? "\(childID)_\(UUID().uuidString)" : childID
        let child = directory.appendingPathComponent("rollout-2026-10-11T08-36-10-\(suffix).jsonl")
        let parent = directory.appendingPathComponent("rollout-2026-10-10T08-36-10-\(parentID).jsonl")
        try (header(childID) + Data("\nignored transcript".utf8)).write(to: child)
        try (header(parentID) + Data("\n".utf8)).write(to: parent)
        let parentReader = try FileHandle(forReadingFrom: parent)
        defer { try? parentReader.close() }
        let writer = try FileHandle(forWritingTo: child)
        defer { try? writer.close() }
        let reader = CodexProcessSessionReader()
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: "reused-pid", conversationID: childID))
        #expect(await reader.sessionID(processID: pid, runtimeID: "reused-pid") == nil)
        #expect(await reader.sessionID(processID: "-1", runtimeID: runtime) == nil)

        let duplicate = try FileHandle(forWritingTo: child)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        try duplicate.close()
        let otherWriter = try FileHandle(forWritingTo: parent)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))
        try otherWriter.close()
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))

        // No newline means the writer has not finished its metadata record.
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: header(childID))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        try writer.write(contentsOf: Data("\n".utf8))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: header(childID, source: "exec") + Data("\n".utf8))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data(repeating: 32, count: CodexProcessSessionReader.headerLimit + 1) + Data("\n".utf8))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
    }
}
