import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentMessageRecoveryTests {
    private struct Fixture {
        let support: AgentInteractionTestSupport
        let message: AgentMessage
        let transcript: URL
        let peer: PluginIngressPeer

        func event(_ kind: PluginWorkflowEvent.Kind, pending: Bool = false) -> PluginEvent {
            .init(
                pluginID: message.instance.pluginID, sessionID: message.instance.conversationID,
                tmuxPane: message.instance.paneID,
                workflow: .init(
                    kind: kind,
                    nativeTurnID: "turn",
                    transcriptPath: transcript.path,
                    text: kind == .submitted ? message.prompt : "Full reply",
                    hasPendingWork: pending
                )
            )
        }
    }

    private func fixture(
        _ plugin: String, accepted: Bool = true, beforeProviding: @escaping @Sendable () async -> Void = { },
        onFailure: @escaping @Sendable (String) -> Void = { Issue.record(Comment(rawValue: $0)) }
    ) async throws -> Fixture {
        let f = try await AgentInteractionTestSupport()
        f.replyProvider = { plugin in
            await beforeProviding()
            if plugin == "codex" {
                return CodexPluginCore()
            }
            return ClaudeCodePluginCore()
        }
        try await f.restartInteraction(onFailure: onFailure)
        let main = await f.orbie()
        try await main.create(pluginID: plugin, providerID: nil)
        main.draft = "Does it rain this weekend?"
        await main.send()
        let message = try #require(main.messages.last)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let transcript = f.root.appendingPathComponent("native.jsonl")
        try records(plugin, conversation: message.instance.conversationID, finished: false).write(to: transcript)
        let result = Fixture(support: f, message: message, transcript: transcript, peer: peer)
        if accepted {
            try await f.interaction.receive(result.event(.submitted), peer: peer)
            try await wait(.running, result)
        }
        return result
    }

    private func records(_ plugin: String, conversation: String, turn: String = "turn", finished: Bool = true, completionOnly: Bool = false) throws -> Data {
        var rows: [[String: Any]] = []
        if plugin == "codex" {
            if !completionOnly {
                rows = [
                    ["type": "session_meta", "payload": ["id": conversation]],
                    ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
                ]
            }
            if finished {
                rows.append(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": "Full reply"]])
            }
        } else {
            if !completionOnly {
                rows = [["type": "user", "uuid": "user", "promptId": turn]]
            }
            if finished {
                rows += [
                    ["type": "assistant", "uuid": "answer", "parentUuid": "user", "message": ["id": "message", "stop_reason": "end_turn", "content": [["type": "text", "text": "Full reply"]]]],
                    ["type": "system", "subtype": "stop_hook_summary", "uuid": "stop", "parentUuid": "answer", "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": ""],
                ]
            }
            rows = rows.map { $0.merging(["sessionId": conversation, "isSidechain": false]) { _, value in value } }
        }
        return try rows.reduce(into: Data()) { data, row in
            try data.append(JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
    }

    private func appendCompletion(_ fixture: Fixture) throws {
        let file = try FileHandle(forWritingTo: fixture.transcript)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: records(fixture.message.instance.pluginID, conversation: fixture.message.instance.conversationID, completionOnly: true))
    }

    private func claudeToolRecord(
        _ name: String, parent: String, in fixture: Fixture, at timestamp: Date? = nil,
        toolID: String? = nil, messageID: String? = nil
    ) throws -> Data {
        var event: [String: Any] = [
            "type": "assistant", "uuid": name, "parentUuid": parent,
            "sessionId": fixture.message.instance.conversationID, "isSidechain": false,
            "message": ["id": messageID ?? name, "stop_reason": "tool_use", "content": [["type": "tool_use", "id": toolID ?? name, "name": name]]],
        ]
        event["timestamp"] = timestamp.map { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format($0) }
        return try JSONSerialization.data(withJSONObject: event) + Data([10])
    }

    private func appendClaudeTool(_ name: String, parent: String, to fixture: Fixture, at timestamp: Date? = nil) throws {
        let file = try FileHandle(forWritingTo: fixture.transcript)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: claudeToolRecord(name, parent: parent, in: fixture, at: timestamp))
    }

    private func wait(_ status: AgentWorkflowInvocationStatus, _ fixture: Fixture) async throws {
        for _ in 0..<500 {
            let counts = await fixture.support.interaction.observationCounts()
            if
                try await fixture.support.interaction.store.message(fixture.message.id)?.status == status,
                counts.receipts == 0, status == .running || counts.transcripts == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Message did not reach \(status)")
    }

    private func waitForActivity(_ expected: [String], in fixture: Fixture) async throws {
        let store = await fixture.support.interaction.store
        for _ in 0..<300 {
            if try await store.message(fixture.message.id)?.activity?.map(\.text) == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Message did not save \(expected)")
    }

    @Test(arguments: ["codex", "claude-code"])
    func publishesActivityBeforeTheReplyAndRetainsItAfterCompletion(plugin: String) async throws {
        let f = try await fixture(plugin)
        let conversationID = f.message.instance.conversationID
        let event: [String: Any]
        if plugin == "codex" {
            event = ["type": "event_msg", "payload": [
                "type": "item_completed", "turn_id": "turn", "thread_id": conversationID,
                "item": ["id": "read", "type": "CommandExecution", "status": "completed", "parsed_cmd": [["type": "read", "name": "notes.md"]]],
            ]]
        } else {
            event = [
                "type": "assistant",
                "uuid": "tool",
                "parentUuid": "user",
                "sessionId": conversationID,
                "isSidechain": false,
                "message": ["id": "tool-message", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": "read", "name": "Read"]]],
            ]
        }
        let file = try FileHandle(forWritingTo: f.transcript)
        try file.seekToEnd()
        try file.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
        try file.close()

        let store = await f.support.interaction.store
        for _ in 0..<300 {
            if try await store.message(f.message.id)?.activity?.isEmpty == false {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try #require(try await store.message(f.message.id))
        #expect(pending.status == .running)
        #expect(pending.answer == nil)
        #expect(pending.activity?.map(\.text) == [plugin == "codex" ? "Read notes.md" : "Called Read"])
        try appendCompletion(f)
        try await wait(.succeeded, f)
        let finished = try #require(try await store.message(f.message.id))
        #expect(finished.answer == "Full reply")
        #expect(finished.activity == pending.activity)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["live", "receipt-only", "settled"])
    func stopFailureSavesRemainingActivity(recovery: String) async throws {
        let f = try await fixture("claude-code")
        let store = await f.support.interaction.store
        try appendClaudeTool("Read", parent: "user", to: f)
        try await waitForActivity(["Called Read"], in: f)
        let failure = f.event(.failed)
        let receipt = try #require(failure.workflow)
        if recovery != "live" {
            await f.support.interaction.shutdown()
            try await store.update(f.message.id) {
                if recovery == "settled" {
                    $0.recordNativeFailure(receipt)
                } else {
                    $0.nativeEvent = receipt
                }
            }
        }
        try appendClaudeTool("Grep", parent: "Read", to: f)
        if recovery == "live" {
            try await f.support.interaction.receive(failure, peer: f.peer)
        } else {
            try await f.support.restartInteraction()
        }
        try await wait(.failed, f)
        let saved = try #require(try await store.message(f.message.id))
        #expect(saved.issue == receipt.text && saved.answer == nil && saved.needsFailureActivity == nil)
        #expect(saved.activity?.map(\.text) == ["Called Read", "Called Grep"])
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func stopFailureReadsRewrittenTranscript(atomically: Bool) async throws {
        let f = try await fixture("claude-code")
        try appendClaudeTool("Read", parent: "user", to: f)
        let prefix = try Data(contentsOf: f.transcript)
        try appendClaudeTool("Glob", parent: "Read", to: f)
        try await waitForActivity(["Called Read", "Called Glob"], in: f)
        let replacement = try claudeToolRecord("Grep", parent: "Read", in: f)
        #expect(try Data(contentsOf: f.transcript).count == prefix.count + replacement.count)
        if atomically {
            try (prefix + replacement).write(to: f.transcript, options: .atomic)
        } else {
            let file = try FileHandle(forWritingTo: f.transcript)
            try file.seek(toOffset: UInt64(prefix.count))
            try file.write(contentsOf: replacement)
            try file.close()
        }

        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        try await wait(.failed, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == ["Called Read", "Called Glob", "Called Grep"])
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [
        "archived", "reopened", "permission-denied", "restart-after-permission-denied",
        "bounded-permission-denied", "bounded-restart-after-permission-denied",
    ])
    func stopFailureSavesLiveActivityAfterTranscriptIsArchived(scenario: String) async throws {
        let reopened = scenario != "archived"
        let restart = scenario.contains("restart")
        let permissionDenied = scenario.hasSuffix("permission-denied")
        let bounded = scenario.hasPrefix("bounded-")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let later = bounded ? (1...17).map { "Later-\($0)" } : []
        let failures = LockIsolated<[String]>([])
        let hold = LockIsolated(false)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let f = try await fixture("claude-code", beforeProviding: {
            if hold.value {
                for await _ in release {
                    break
                }
            }
        }, onFailure: { reason in failures.withValue { $0.append(reason) } })
        try appendClaudeTool("Read", parent: "user", to: f, at: bounded ? base : nil)
        let prefix = try Data(contentsOf: f.transcript)
        try await waitForActivity(["Called Read"], in: f)

        let store = await f.support.interaction.store
        let path = await store.directory.path
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        try appendClaudeTool("Grep", parent: "Read", to: f, at: bounded ? base.addingTimeInterval(2) : nil)
        for _ in 0..<300 {
            if !failures.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(failures.value.first?.hasPrefix("Could not save Agent activity:") == true)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        if reopened {
            var replacement = try prefix + claudeToolRecord("Bash", parent: "Read", in: f, at: bounded ? base.addingTimeInterval(1) : nil)
            var parent = "Bash"
            for (index, id) in later.enumerated() {
                try replacement.append(claudeToolRecord(id, parent: parent, in: f, at: base.addingTimeInterval(Double(index + 3))))
                parent = id
            }
            try replacement.write(to: f.transcript)
        }
        if permissionDenied {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.transcript.path)
        }
        defer {
            if permissionDenied {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.transcript.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)

        hold.setValue(true)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        for _ in 0..<300 {
            if try await store.message(f.message.id)?.status == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await store.message(f.message.id)?.needsFailureActivity == true)
        try await Task.sleep(for: .milliseconds(250))
        continuation.finish()
        try await wait(.failed, f)
        if permissionDenied {
            #expect(failures.value.contains { $0.hasPrefix("Could not recover Agent activity:") })
            #expect(try await store.message(f.message.id)?.needsFailureActivity == true)
            #expect(try await store.message(f.message.id)?.activity?.map(\.text) == ["Called Read", "Called Grep"])
            if restart {
                await f.support.interaction.shutdown()
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.transcript.path)
            if restart {
                try await f.support.restartInteraction()
            } else {
                try await f.support.interaction.resumePendingReplies()
            }
        }
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        let expected = bounded ? ["Grep"] + later : ["Read", "Grep"] + (reopened ? ["Bash"] : [])
        #expect(saved.activity?.map(\.id) == expected)
        #expect(saved.needsFailureActivity == nil)
        #expect(saved.activitySource == nil)
        try await f.support.cleanup()
    }

    @Test
    func rotatedFailureKeepsNewestActivityWhenSavingBoundedHistory() async throws {
        let f = try await fixture("claude-code")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try appendClaudeTool("Read 1", parent: "user", to: f, at: base)
        let prefix = try Data(contentsOf: f.transcript)
        for index in 2...36 {
            try appendClaudeTool("Read \(index)", parent: "Read \(index - 1)", to: f, at: base.addingTimeInterval(Double(index - 1)))
        }
        try await waitForActivity((19...36).map { "Called Read \($0)" }, in: f)

        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        try (prefix + claudeToolRecord("Bash", parent: "Read 1", in: f, at: base.addingTimeInterval(36))).write(to: f.transcript)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        try await wait(.failed, f)

        let expected = (20...36).map { "Called Read \($0)" } + ["Called Bash"]
        #expect(try await f.support.interaction.store.message(f.message.id)?.activity?.map(\.text) == expected)
        try await f.support.restartInteraction()
        let recovered = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(recovered.activity?.map(\.text) == expected)
        #expect(recovered.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true], [false, true])
    func recheckReadsRemainingBytesFromArchivedTranscript(reopened: Bool, clockMovesBack: Bool) async throws {
        let f = try await fixture("claude-code")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try appendClaudeTool("Read", parent: "user", to: f, at: clockMovesBack ? base : nil)
        let prefix = try Data(contentsOf: f.transcript)
        try await waitForActivity(["Called Read"], in: f)

        let grep = try claudeToolRecord("Grep", parent: clockMovesBack ? "read-result" : "Read", in: f, at: clockMovesBack ? base.addingTimeInterval(-0.2) : nil)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        if clockMovesBack {
            let result: [String: Any] = [
                "type": "user", "uuid": "read-result", "parentUuid": "Read", "promptId": "turn",
                "sessionId": f.message.instance.conversationID, "isSidechain": false,
                "message": ["content": [["type": "tool_result", "tool_use_id": "Read", "content": "done"]]],
            ]
            try writer.write(contentsOf: JSONSerialization.data(withJSONObject: result) + Data([10]))
        }
        try writer.write(contentsOf: grep.dropLast(8))
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        if reopened {
            let bash = try claudeToolRecord("Bash", parent: "Read", in: f, at: clockMovesBack ? base.addingTimeInterval(1) : nil)
            try (prefix + bash).write(to: f.transcript)
        }

        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        try await wait(.failed, f)
        let store = await f.support.interaction.store
        let expected = reopened ? ["Called Read", "Called Bash"] : ["Called Read"]
        #expect(try await store.message(f.message.id)?.activity?.map(\.text) == expected)
        #expect(try await store.message(f.message.id)?.needsFailureActivity == true)
        try await f.support.interaction.resumePendingReplies()
        #expect(try await store.message(f.message.id)?.needsFailureActivity == true)

        try writer.write(contentsOf: grep.suffix(8))
        try await f.support.interaction.resumePendingReplies()
        try await f.support.restartInteraction()
        let saved = try #require(try await store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == ["Called Read", "Called Grep"] + expected.dropFirst())
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true], ["17-calls", "18-calls", "replacement-archived", "same-time"])
    func archivedActivityKeepsNewerReplacementHistory(delayed: Bool, scenario: String) async throws {
        let f = try await fixture("claude-code")
        let prefix = try Data(contentsOf: f.transcript)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let bashCount = scenario == "17-calls" ? 17 : 18
        let sameTime = scenario == "same-time"
        try appendClaudeTool("Read", parent: "user", to: f, at: base)
        try await waitForActivity(["Called Read"], in: f)

        let grep = try claudeToolRecord("Grep", parent: "Read", in: f, at: base.addingTimeInterval(1))
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: delayed ? Data(grep.dropLast(8)) : grep)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))

        var replacement = prefix
        var parent = "user"
        if sameTime {
            // Both Grep and Bash-1 have local sequence 2 and the same timestamp.
            try replacement.append(claudeToolRecord("New-start", parent: parent, in: f, at: base))
            parent = "New-start"
        }
        for index in 1...bashCount {
            let name = "Bash-\(index)"
            let timestamp = base.addingTimeInterval(Double(sameTime ? index : index + 1))
            try replacement.append(claudeToolRecord(name, parent: parent, in: f, at: timestamp))
            parent = name
        }
        try replacement.write(to: f.transcript)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        try await wait(.failed, f)

        let bash = (1...bashCount).map { "Called Bash-\($0)" }
        if delayed {
            let pending = try #require(try await f.support.interaction.store.message(f.message.id))
            #expect(pending.needsFailureActivity == true)
            #expect(pending.activity?.map(\.text) == Array((["Called Read"] + bash).suffix(18)))
            if scenario == "replacement-archived" {
                try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("replacement-archive"))
            }
            try writer.write(contentsOf: grep.suffix(8))
            try await f.support.interaction.resumePendingReplies()
        }

        let expected = ["Called Grep"] + (sameTime ? Array(bash.dropFirst()) : bash)
        let recent = Array(expected.suffix(18))
        #expect(try await f.support.interaction.store.message(f.message.id)?.activity?.map(\.text) == recent)
        try await f.support.restartInteraction()
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == recent)
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func sameTimeToolCallsKeepTheirOrderAcrossArchivedWrites(delayed: Bool) async throws {
        let f = try await fixture("claude-code")
        let header = try Data(contentsOf: f.transcript)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let time = base.addingTimeInterval(1)
        try appendClaudeTool("Read", parent: "user", to: f, at: base)
        try await waitForActivity(["Called Read"], in: f)

        let grep = try claudeToolRecord("Grep", parent: "Read", in: f, at: time)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: delayed ? Data(grep.dropLast(8)) : grep)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))

        let tools: [String: Any] = [
            "type": "assistant", "uuid": "tools", "parentUuid": "user",
            "sessionId": f.message.instance.conversationID, "isSidechain": false,
            "timestamp": time.ISO8601Format(),
            "message": ["id": "tools", "stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "Z-bash", "name": "Bash"],
                ["type": "tool_use", "id": "A-edit", "name": "Edit"],
            ]],
        ]
        var replacement = try header + JSONSerialization.data(withJSONObject: tools) + Data([10])
        let later = (1...16).map { "Later-\($0)" }
        var parent = "tools"
        for (index, id) in later.enumerated() {
            try replacement.append(claudeToolRecord(id, parent: parent, in: f, at: base.addingTimeInterval(Double(index + 2))))
            parent = id
        }
        try replacement.write(to: f.transcript)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        try await wait(.failed, f)

        if delayed {
            let pending = try #require(try await f.support.interaction.store.message(f.message.id))
            #expect(pending.needsFailureActivity == true)
            #expect(pending.activity?.map(\.id) == ["Z-bash", "A-edit"] + later)
            try writer.write(contentsOf: grep.suffix(8))
            try await f.support.interaction.resumePendingReplies()
        }

        let expected = ["A-edit", "Grep"] + later
        #expect(try await f.support.interaction.store.message(f.message.id)?.activity?.map(\.id) == expected)
        try await f.support.restartInteraction()
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.id) == expected)
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true], [false, true])
    func failureSaveKeepsLaterCallFromSplitClaudeMessage(delayed: Bool, sameTime: Bool) async throws {
        let hold = LockIsolated(false)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let f = try await fixture("claude-code", beforeProviding: {
            if hold.value {
                for await _ in release {
                    break
                }
            }
        })
        let header = try Data(contentsOf: f.transcript)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: claudeToolRecord("Bash", parent: "user", in: f, at: time, toolID: "Z-bash", messageID: "split"))
        try await waitForActivity(["Called Bash"], in: f)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))

        let grepTime = time.addingTimeInterval(sameTime ? 0 : 0.5)
        var replacement = try header + claudeToolRecord("Grep", parent: "user", in: f, at: grepTime)
        let later = (1...16).map { "Later-\($0)" }
        var parent = "Grep"
        for (index, id) in later.enumerated() {
            try replacement.append(claudeToolRecord(id, parent: parent, in: f, at: time.addingTimeInterval(Double(index + 1))))
            parent = id
        }
        try replacement.write(to: f.transcript)
        hold.setValue(true)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        let store = await f.support.interaction.store
        for _ in 0..<300 {
            if try await store.message(f.message.id)?.needsFailureActivity == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await store.message(f.message.id)?.needsFailureActivity == true)
        #expect(try await store.message(f.message.id)?.activity?.map(\.id) == ["Z-bash"])

        // The live publisher is settled. Only failure recovery can see Edit.
        let edit = try claudeToolRecord("Edit", parent: "Bash", in: f, at: time, toolID: "A-edit", messageID: "split")
        try writer.write(contentsOf: delayed ? Data(edit.dropLast(8)) : edit)
        continuation.finish()
        try await wait(.failed, f)
        if delayed {
            let pending = try #require(try await store.message(f.message.id))
            #expect(pending.needsFailureActivity == true)
            let provisional = sameTime ? ["Grep", "Z-bash"] : ["Z-bash", "Grep"]
            #expect(pending.activity?.map(\.id) == provisional + later)
            try writer.write(contentsOf: edit.suffix(8))
            try await f.support.interaction.resumePendingReplies()
        }
        let expected = ["A-edit", "Grep"] + later
        #expect(try await store.message(f.message.id)?.activity?.map(\.id) == expected)
        try await f.support.restartInteraction()
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.id) == expected)
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func failureWriteBackDoesNotReviveEvictedActivityFromOlderPrefix(bashPublished: Bool) async throws {
        let hold = LockIsolated(false)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let f = try await fixture("claude-code", beforeProviding: {
            if hold.value {
                for await _ in release {
                    break
                }
            }
        })
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let bash = try claudeToolRecord("Bash", parent: bashPublished ? "user" : "Read", in: f, at: time, toolID: "Z-bash", messageID: "split")
        if bashPublished {
            try writer.write(contentsOf: bash)
        } else {
            try writer.write(contentsOf: claudeToolRecord("Read", parent: "user", in: f, at: time.addingTimeInterval(-1)))
        }
        try await waitForActivity([bashPublished ? "Called Bash" : "Called Read"], in: f)
        let prefix = try Data(contentsOf: f.transcript)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        try (bashPublished ? prefix : prefix + bash).write(to: f.transcript)

        hold.setValue(true)
        try await f.support.interaction.receive(f.event(.failed), peer: f.peer)
        let store = await f.support.interaction.store
        for _ in 0..<300 {
            if try await store.message(f.message.id)?.needsFailureActivity == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await store.message(f.message.id)?.needsFailureActivity == true)
        #expect(try await store.message(f.message.id)?.activity?.map(\.id) == [bashPublished ? "Z-bash" : "Read"])

        var tail = bashPublished ? Data() : bash
        try tail.append(claudeToolRecord("Edit", parent: "Bash", in: f, at: time, toolID: "A-edit", messageID: "split"))
        let later = (1...17).map { "Later-\($0)" }
        var parent = "Edit"
        for (index, id) in later.enumerated() {
            try tail.append(claudeToolRecord(id, parent: parent, in: f, at: time.addingTimeInterval(Double(index + 1))))
            parent = id
        }
        try writer.write(contentsOf: tail)
        continuation.finish()
        try await wait(.failed, f)
        let expected = ["A-edit"] + later
        #expect(try await store.message(f.message.id)?.activity?.map(\.id) == expected)
        try await f.support.restartInteraction()
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.id) == expected)
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: ["partial-tool", "partial-result", "previous-turn"])
    func incompleteTranscriptKeepsFailureActivityPending(initialTranscript: String) async throws {
        let f = try await fixture("claude-code")
        try appendClaudeTool("Read", parent: "user", to: f)
        try await waitForActivity(["Called Read"], in: f)
        await f.support.interaction.shutdown()
        try appendClaudeTool("Grep", parent: "Read", to: f)
        var complete = try Data(contentsOf: f.transcript)
        if initialTranscript == "partial-result" {
            let result: [String: Any] = [
                "type": "user", "uuid": "grep-result", "parentUuid": "Grep", "promptId": "turn",
                "sessionId": f.message.instance.conversationID, "isSidechain": false,
                "message": ["content": [["type": "tool_result", "tool_use_id": "Grep", "content": "Search completed"]]],
            ]
            try complete.append(JSONSerialization.data(withJSONObject: result))
            complete.append(10)
        }
        let incomplete = if initialTranscript != "previous-turn" {
            Data(complete.dropLast(8))
        } else {
            try records("claude-code", conversation: f.message.instance.conversationID, turn: "earlier", finished: false)
        }
        try incomplete.write(to: f.transcript)

        let store = await f.support.interaction.store
        let receipt = try #require(f.event(.failed).workflow)
        try await store.update(f.message.id) { $0.recordNativeFailure(receipt) }
        try await f.support.restartInteraction()
        let waiting = try #require(try await store.message(f.message.id))
        #expect(waiting.needsFailureActivity == true)
        let parsed = initialTranscript == "partial-result" ? ["Called Read", "Called Grep"] : ["Called Read"]
        #expect(waiting.activity?.map(\.text) == parsed)
        try await f.support.interaction.resumePendingReplies()
        #expect(try await store.message(f.message.id)?.activity?.map(\.text) == parsed)
        #expect(try await store.message(f.message.id)?.needsFailureActivity == true)

        try complete.write(to: f.transcript)
        if initialTranscript == "previous-turn" {
            try await f.support.restartInteraction()
        } else {
            try await f.support.interaction.resumePendingReplies()
        }
        let saved = try #require(try await store.message(f.message.id))
        #expect(saved.status == .failed && saved.issue == receipt.text)
        #expect(saved.needsFailureActivity == nil)
        #expect(saved.activity?.map(\.text) == ["Called Read", "Called Grep"])
        try await f.support.cleanup()
    }

    @Test
    func verifiedFailureSettlesBeforeReadingActivityAndSurvivesStopWaiting() async throws {
        let hold = LockIsolated(false)
        let entered = LockIsolated(false)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let f = try await fixture("claude-code", beforeProviding: {
            if hold.value {
                entered.setValue(true)
                for await _ in release {
                    break
                }
            }
        })
        try appendClaudeTool("Read", parent: "user", to: f)
        try await waitForActivity(["Called Read"], in: f)
        hold.setValue(true)
        try appendClaudeTool("Grep", parent: "Read", to: f)
        let failure = f.event(.failed)
        try await f.support.interaction.receive(failure, peer: f.peer)
        for _ in 0..<300 {
            if entered.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(entered.value)
        try await f.support.interaction.stopWaiting(f.message.id)
        let store = await f.support.interaction.store
        let saved = try #require(try await store.message(f.message.id))
        #expect(saved.status == .failed && saved.issue == failure.workflow?.text && saved.completedAt != nil)
        #expect(saved.needsFailureActivity == true)
        #expect(try await f.support.interaction.availability(saved.agentID) == nil)
        let rechecked = LockIsolated(false)
        let recheck = Task {
            try await f.support.interaction.resumePendingReplies()
            rechecked.setValue(true)
        }
        for _ in 0..<100 {
            if rechecked.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rechecked.value, "Recheck should skip a recovery already in progress")
        continuation.finish()
        try await recheck.value
        try await wait(.failed, f)
        try await waitForActivity(["Called Read", "Called Grep"], in: f)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func shorterTranscriptDoesNotRemoveSavedActivity(fails: Bool) async throws {
        let f = try await fixture("claude-code")
        try appendClaudeTool("Read", parent: "user", to: f)
        let prefix = try Data(contentsOf: f.transcript)
        try appendClaudeTool("Grep", parent: "Read", to: f)
        let expected = ["Called Read", "Called Grep"]
        try await waitForActivity(expected, in: f)
        await f.support.interaction.shutdown()
        try prefix.write(to: f.transcript)
        if fails {
            let receipt = try #require(f.event(.failed).workflow)
            try await f.support.interaction.store.update(f.message.id) { $0.recordNativeFailure(receipt) }
        } else {
            try appendCompletion(f)
        }
        try await f.support.restartInteraction()
        try await wait(fails ? .failed : .succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == expected)
        #expect(saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true], ["replace", "rewrite", "append"])
    func restartMergesLiveActivityUsingSavedTranscriptTail(fails: Bool, change: String) async throws {
        let f = try await fixture("claude-code")
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        try appendClaudeTool("Read", parent: "user", to: f, at: time)
        let prefix = try Data(contentsOf: f.transcript)
        try appendClaudeTool("Grep", parent: "Read", to: f, at: time.addingTimeInterval(2))
        try await waitForActivity(["Called Read", "Called Grep"], in: f)
        let store = await f.support.interaction.store
        let source = try #require(try await store.message(f.message.id)?.activitySource)
        await f.support.interaction.shutdown()

        var tail = try claudeToolRecord("Bash", parent: change == "append" ? "Grep" : "Read", in: f, at: time.addingTimeInterval(1))
        let later = (1...17).map { "Later-\($0)" }
        var parent = "Bash"
        for (index, id) in later.enumerated() {
            try tail.append(claudeToolRecord(id, parent: parent, in: f, at: time.addingTimeInterval(Double(index + 3))))
            parent = id
        }
        if change == "replace" {
            try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
            try (prefix + tail).write(to: f.transcript)
        } else {
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            if change == "rewrite" {
                try file.truncate(atOffset: UInt64(prefix.count))
            }
            try file.seekToEnd()
            try file.write(contentsOf: tail)
        }
        if fails {
            let receipt = try #require(f.event(.failed).workflow)
            try await store.update(f.message.id) { $0.recordNativeFailure(receipt) }
        }
        let expected = [change == "append" ? "Bash" : "Grep"] + later
        try await f.support.restartInteraction()
        if !fails {
            try await waitForActivity(expected.map { "Called \($0)" }, in: f)
            let active = try #require(try await f.support.interaction.store.message(f.message.id))
            #expect(active.activitySource == (change == "append" ? source : .rotated))
            try appendCompletion(f)
        }
        try await wait(fails ? .failed : .succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.id) == expected)
        #expect(saved.activitySource == nil && saved.needsFailureActivity == nil)
        try await f.support.cleanup()
    }

    @Test
    func restartedSuccessDoesNotRestoreEvictedCallFromTranscriptPrefix() async throws {
        let f = try await fixture("claude-code")
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: claudeToolRecord("Bash", parent: "user", in: f, at: time, toolID: "Z-bash"))
        try await waitForActivity(["Called Bash"], in: f)
        await f.support.interaction.shutdown()
        var replacement = try Data(contentsOf: f.transcript)
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        try replacement.append(claudeToolRecord("Edit", parent: "Bash", in: f, at: time, toolID: "A-edit"))
        let later = (1...17).map { "Later-\($0)" }
        var parent = "Edit"
        for (index, id) in later.enumerated() {
            try replacement.append(claudeToolRecord(id, parent: parent, in: f, at: time.addingTimeInterval(Double(index + 1))))
            parent = id
        }
        try replacement.write(to: f.transcript)
        try appendCompletion(f)
        try await f.support.restartInteraction()
        try await wait(.succeeded, f)
        try await f.support.restartInteraction()
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.id) == ["A-edit"] + later)
        try await f.support.cleanup()
    }

    @Test
    func stopBeforeNextPollKeepsNativeActivityWindow() async throws {
        let f = try await fixture("claude-code")
        await f.support.interaction.shutdown()
        let store = await f.support.interaction.store
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = try FileHandle(forWritingTo: f.transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: claudeToolRecord("Bash", parent: "user", in: f, at: time, toolID: "Z-bash"))

        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let snapshot = LockIsolated<AgentActivitySnapshot?>(nil)
        let monitor = AgentReplyMonitor(
            state: { context in .init(isPending: true, instance: context.instance) },
            completed: { context, _, outcome, activity in
                guard case let .succeeded(answer) = outcome else {
                    Issue.record("Expected successful completion")
                    return
                }
                try await store.update(context.id) {
                    $0.mergeActivity(activity, finalizing: true)
                    $0.status = .succeeded
                    $0.answer = answer
                }
            }, waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) }, inspect: { $0 },
            activityChanged: { context, activity in
                let saved = try await store.updateActivity(activity, for: context)
                if activity.entries.map(\.id) == ["Z-bash"] {
                    // Deliver Stop after the write and before the next poll.
                    for await _ in resume {
                        break
                    }
                } else {
                    snapshot.setValue(activity)
                }
                return saved
            }, onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let provider = ClaudeCodePluginCore()
        let submitted = try #require(f.event(.submitted).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: submitted), provider: provider)
        try await waitForActivity(["Called Bash"], in: f)
        let saved = try #require(try await store.message(f.message.id))

        try writer.write(contentsOf: claudeToolRecord("Edit", parent: "Bash", in: f, at: time, toolID: "A-edit"))
        let later = (1...17).map { "Later-\($0)" }
        var parent = "Edit"
        for (index, id) in later.enumerated() {
            try writer.write(contentsOf: claudeToolRecord(id, parent: parent, in: f, at: time.addingTimeInterval(Double(index + 1))))
            parent = id
        }
        try appendCompletion(f)
        let stop = try #require(f.event(.stopCandidate).workflow)
        try await store.update(f.message.id) { $0.nativeEvent = stop }
        await monitor.verify(.init(
            id: saved.id, instance: saved.instance, prompt: saved.prompt, candidate: stop,
            savedActivity: saved.activity ?? [], savedActivitySource: saved.activitySource
        ), provider: provider)
        continuation.finish()

        try await wait(.succeeded, f)
        await monitor.shutdown()
        #expect(snapshot.value?.evictedActivityIDs == ["Z-bash"])
        #expect(snapshot.value?.source == saved.activitySource)
        try await f.support.restartInteraction()
        let restored = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(restored.activity?.map(\.id) == ["A-edit"] + later)
        try await f.support.cleanup()
    }

    @Test(arguments: [0, 1, 18])
    func activityAppendedWhileReplayingAShorterTranscriptIsKept(offlineCount: Int) async throws {
        let f = try await fixture("claude-code")
        let limit = AgentTurnActivityLog.maximumEntries
        try appendClaudeTool("Step 1", parent: "user", to: f)
        let prefix = try Data(contentsOf: f.transcript)
        for index in 2...(2 * limit) {
            try appendClaudeTool("Step \(index)", parent: "Step \(index - 1)", to: f)
        }
        let expected = ((limit + 1)...(2 * limit)).map { "Called Step \($0)" }
        try await waitForActivity(expected, in: f)
        await f.support.interaction.shutdown()
        try prefix.write(to: f.transcript)

        let opened = LockIsolated(false)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        f.support.inspectReply = { instance in
            opened.setValue(true)
            for await _ in release {
                break
            }
            return instance
        }
        try await f.support.restartInteraction()
        for _ in 0..<300 {
            if opened.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(opened.value)
        try appendClaudeTool("Grep", parent: "Step 1", to: f)
        continuation.finish()
        var expectedWithAppend = Array(expected.dropFirst()) + ["Called Grep"]
        try await waitForActivity(expectedWithAppend, in: f)
        if offlineCount > 0 {
            await f.support.interaction.shutdown()
            var parent = "Grep"
            for index in 1...offlineCount {
                let name = "Bash \(index)"
                try appendClaudeTool(name, parent: parent, to: f)
                parent = name
                expectedWithAppend.append("Called \(name)")
            }
            expectedWithAppend = Array(expectedWithAppend.suffix(limit))
        }
        try appendCompletion(f)
        if offlineCount > 0 {
            try await f.support.restartInteraction()
            try await waitForActivity(expectedWithAppend, in: f)
        }
        try await wait(.succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == expectedWithAppend)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func nativeTimeRecoversOfflineActivityWithoutSharedIDs(clockMovesBack: Bool) async throws {
        let f = try await fixture("claude-code")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try appendClaudeTool("Step 1", parent: "user", to: f, at: base)
        let prefix = try Data(contentsOf: f.transcript)
        for step in 2...36 {
            try appendClaudeTool("Step \(step)", parent: "Step \(step - 1)", to: f, at: base.addingTimeInterval(Double(step - 1)))
        }
        try await waitForActivity((19...36).map { "Called Step \($0)" }, in: f)
        await f.support.interaction.shutdown()
        try prefix.write(to: f.transcript)
        var parent = "Step 1"
        let timestamps = (1...18).map { index in
            base.addingTimeInterval(clockMovesBack && index == 17 ? 36.8 : Double(36 + index))
        }
        for (index, timestamp) in timestamps.enumerated() {
            let name = "Offline \(index + 1)"
            try appendClaudeTool(name, parent: parent, to: f, at: timestamp)
            parent = name
        }
        try appendCompletion(f)
        try await f.support.restartInteraction()
        try await wait(.succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        let activity = try #require(saved.activity)
        #expect(activity.map(\.text) == (1...18).map { "Called Offline \($0)" })
        let savedTimestamps = activity.compactMap(\.timestamp)
        #expect(savedTimestamps.count == timestamps.count)
        #expect(zip(savedTimestamps, timestamps).allSatisfy { abs($0.timeIntervalSince($1)) < 0.002 })
        try await f.support.cleanup()
    }

    @Test(arguments: [1, AgentTurnActivityLog.maximumEntries])
    func liveActivityUsesTranscriptOrderWhenClockMovesBack(count: Int) async throws {
        let f = try await fixture("claude-code")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var parent = "user"
        let reads = (1...AgentTurnActivityLog.maximumEntries).map { "Read \($0)" }
        for name in reads {
            try appendClaudeTool(name, parent: parent, to: f, at: base)
            parent = name
        }
        try await waitForActivity(reads.map { "Called \($0)" }, in: f)

        let greps = (1...count).map { "Grep \($0)" }
        var records = Data()
        for name in greps {
            try records.append(claudeToolRecord(name, parent: parent, in: f, at: base.addingTimeInterval(-0.2)))
            parent = name
        }
        let file = try FileHandle(forWritingTo: f.transcript)
        try file.seekToEnd()
        try file.write(contentsOf: records)
        try file.close()
        let expected = (reads.dropFirst(count) + greps).map { "Called \($0)" }
        try await waitForActivity(expected, in: f)
        try appendCompletion(f)
        try await wait(.succeeded, f)
        #expect(try await f.support.interaction.store.message(f.message.id)?.activity?.map(\.text) == expected)
        try await f.support.cleanup()
    }

    @Test
    func firstReplayUsesTranscriptOrderWhenClockMovesBack() async throws {
        let f = try await fixture("claude-code")
        await f.support.interaction.shutdown()
        #expect(try await f.support.interaction.store.message(f.message.id)?.activity == nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var parent = "user"
        let tools = (1...18).map { $0 == 17 ? "Grep" : "Read \($0)" }
        for name in tools {
            try appendClaudeTool(name, parent: parent, to: f, at: name == "Grep" ? base.addingTimeInterval(-0.2) : base)
            parent = name
        }
        try await f.support.restartInteraction()
        try await waitForActivity(tools.map { "Called \($0)" }, in: f)
        try await f.support.cleanup()
    }

    @Test(arguments: ["read", "write", "replace", "replace-and-append", "archive"])
    func failureActivityCanRetryAfterTemporaryIOError(operation: String) async throws {
        let f = try await fixture("claude-code")
        try appendClaudeTool("Read", parent: "user", to: f)
        let prefix = try Data(contentsOf: f.transcript)
        try await waitForActivity(["Called Read"], in: f)
        await f.support.interaction.shutdown()
        try appendClaudeTool("Grep", parent: "Read", to: f)
        let store = await f.support.interaction.store
        let receipt = try #require(f.event(.failed).workflow)
        try await store.update(f.message.id) { $0.recordNativeFailure(receipt) }
        let isReadError = operation == "read"
        let path = isReadError ? f.transcript.path : await store.directory.path
        let restoreMode = isReadError ? 0o600 : 0o700
        defer { try? FileManager.default.setAttributes([.posixPermissions: restoreMode], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: isReadError ? 0o000 : 0o500], ofItemAtPath: path)

        let failures = LockIsolated<[String]>([])
        try await f.support.restartInteraction(onFailure: { reason in failures.withValue { $0.append(reason) } })
        let pendingRecovery = try #require(try await store.message(f.message.id))
        #expect(pendingRecovery.status == .failed && pendingRecovery.issue == receipt.text)
        #expect(pendingRecovery.activity?.map(\.text) == ["Called Read"])
        #expect(pendingRecovery.needsFailureActivity == true)
        let orbie = isReadError ? nil : await f.support.orbie()
        try await f.support.interaction.resumePendingReplies()
        #expect(failures.value.count == 1)

        var expected = ["Called Read", "Called Grep"]
        if operation == "archive" {
            try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("archived"))
        } else if operation.hasPrefix("replace") {
            try prefix.write(to: f.transcript, options: .atomic)
            if operation == "replace-and-append" {
                try appendClaudeTool("Bash", parent: "Read", to: f)
                expected.append("Called Bash")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: restoreMode], ofItemAtPath: path)
        if let orbie {
            await orbie.refresh()
            #expect(orbie.messages.last?.activity?.map(\.text) == expected)
        } else {
            try await f.support.restartInteraction()
        }
        let saved = try #require(try await store.message(f.message.id))
        #expect(saved.activity?.map(\.text) == expected)
        #expect(saved.needsFailureActivity == nil && saved.status == .failed && saved.issue == receipt.text)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test
    func completedActivityDrainStaysCachedUntilSaved() async throws {
        let f = try await fixture("claude-code")
        await f.support.interaction.shutdown()
        try appendClaudeTool("Read", parent: "user", to: f)
        let receipt = try #require(f.event(.failed).workflow)
        let context = AgentReplyContext(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt)
        let store = await f.support.interaction.store
        try await store.update(f.message.id) { $0.recordNativeFailure(receipt) }
        let monitor = AgentReplyMonitor(
            state: { _ in .init(isPending: false, instance: nil) },
            completed: { _, _, _, _ in }, waiting: { _, _, _ in },
            inspect: { $0 }, activityChanged: { _, _ in nil },
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let first = try #require(try await monitor.finishActivity(context, provider: ClaudeCodePluginCore()))
        #expect(first.isComplete && first.entries.map(\.text) == ["Called Read"])

        // Codex cannot parse this Claude transcript. A complete result here
        // demonstrates that the unchanged file was not parsed again.
        let retry = try #require(try await monitor.finishActivity(context, provider: CodexPluginCore()))
        #expect(retry.isComplete && retry.entries == first.entries)
        try await store.saveRecoveredActivity(retry, for: context)
        await monitor.didSaveActivity(context)
        #expect(try await store.message(f.message.id)?.needsFailureActivity == nil)

        let afterSave = try #require(try await monitor.finishActivity(context, provider: CodexPluginCore()))
        #expect(!afterSave.isComplete && afterSave.entries.isEmpty)
        await monitor.shutdown()
        try await f.support.cleanup()
    }

    @Test
    func mergingDisjointActivityWindowsKeepsTheNewestEntries() async throws {
        let f = try await fixture("claude-code")
        let limit = AgentTurnActivityLog.maximumEntries
        var log = AgentTurnActivityLog()
        for index in 1...limit {
            log.record(id: String(index), kind: .tool, text: "Step \(index)")
        }
        let earlier = log.entries
        for index in (limit + 1)...(2 * limit) {
            log.record(id: String(index), kind: .tool, text: "Step \(index)")
        }
        let saved = log.entries
        var message = f.message
        message.activity = saved
        let changedByEarlier = message.mergeActivity(earlier)
        #expect(!changedByEarlier)
        #expect(message.activity == saved)

        for index in (2 * limit + 1)...(3 * limit) {
            log.record(id: String(index), kind: .tool, text: "Step \(index)")
        }
        let changedByLater = message.mergeActivity(log.entries)
        #expect(changedByLater)
        #expect(message.activity == log.entries)
        try await f.support.cleanup()
    }

    @Test
    func activitySaveRetriesAndLogsOnlyOncePerFailureEpisode() async throws {
        let f = try await fixture("claude-code")
        await f.support.interaction.shutdown()
        try appendClaudeTool("Read", parent: "user", to: f)
        let attempts = LockIsolated(0)
        let published = LockIsolated<[AgentTurnActivity]>([])
        let failures = LockIsolated<[String]>([])
        let monitor = AgentReplyMonitor(
            state: { context in .init(isPending: true, instance: context.instance) },
            completed: { _, _, _, _ in Issue.record("No completion was written") },
            waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) },
            inspect: { $0 },
            activityChanged: { _, activity in
                let attempt = attempts.withValue {
                    $0 += 1
                    return $0
                }
                if attempt <= 3 || attempt == 5 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                published.setValue(activity.entries)
                return nil
            },
            onFailure: { reason in failures.withValue { $0.append(reason) } }
        )
        let receipt = try #require(f.event(.submitted).workflow)
        await monitor.verify(
            .init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt),
            provider: ClaudeCodePluginCore()
        )
        for _ in 0..<300 {
            if !published.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(attempts.value == 4 && failures.value.count == 1)
        #expect(published.value.map(\.text) == ["Called Read"])
        try appendClaudeTool("Grep", parent: "Read", to: f)
        for _ in 0..<300 {
            if published.value.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.shutdown()
        #expect(attempts.value == 6 && failures.value.count == 2)
        #expect(published.value.map(\.text) == ["Called Read", "Called Grep"])
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"], ["before-restart", "after-restart", "live"])
    func missingStopRecoversNativeReplyWithoutResending(plugin: String, completion: String) async throws {
        let f = try await fixture(plugin)
        if completion != "live" {
            await f.support.interaction.shutdown()
        }
        if completion == "before-restart" {
            try appendCompletion(f)
        }
        if completion != "live" {
            try await f.support.restartInteraction()
        }
        if completion != "before-restart" {
            try appendCompletion(f)
        }
        try await wait(.succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.answer == "Full reply" && saved.completedAt != nil && saved.issue == nil)
        #expect(saved.nativeEvent?.kind == .submitted, "Recovery must not invent a Stop callback")
        #expect(try await f.support.interaction.availability(saved.agentID) == nil)
        let reopened = await f.support.orbie()
        #expect(reopened.messages.last?.answer == "Full reply" && reopened.availability == nil)

        try await f.support.interaction.receive(f.event(.stopCandidate), peer: f.peer)
        try await f.support.interaction.receive(f.event(.submitted), peer: f.peer)
        #expect(try await f.support.interaction.store.message(saved.id) == saved)
        try await f.support.restartInteraction()
        #expect(try await f.support.interaction.store.message(saved.id) == saved)
        #expect(await f.support.interaction.observationCounts().transcripts == 0)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"], ["conversation", "turn", "unfinished", "partial", "unaccepted", "pending-work"])
    func unrelatedOrIncompleteEvidenceCannotCompleteMessage(plugin: String, change: String) async throws {
        let f = try await fixture(plugin, accepted: change != "unaccepted")
        if change == "pending-work" {
            try await f.support.interaction.receive(f.event(.stopCandidate, pending: true), peer: f.peer)
            for _ in 0..<100 {
                if try await f.support.interaction.store.message(f.message.id)?.nativeEvent?.kind == .stopCandidate {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await f.support.interaction.shutdown()
        var bytes = try records(
            plugin,
            conversation: change == "conversation" ? "other" : f.message.instance.conversationID,
            turn: change == "turn" ? "other" : "turn",
            finished: change != "unfinished"
        )
        if change == "partial" {
            bytes.removeLast()
        }
        try bytes.write(to: f.transcript)
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(500))
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.answer == nil && saved.completedAt == nil)
        #expect(saved.status == (change == "unaccepted" ? .uncertain : .running))
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func changedConversationCannotReceiveOldReply(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        f.support.observations[0].conversationID = "different-conversation"
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(100))
        try await wait(.uncertain, f)
        #expect(try await f.support.interaction.store.message(f.message.id)?.answer == nil)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func recoverySynchronizationRetriesWithinBudget(recovers: Bool) async throws {
        let f = try await fixture("codex")
        let attempts = LockIsolated(0)
        f.support.synchronizeEvents = {
            let count = attempts.withValue { $0 += 1
                return $0
            }
            if count == 1 || !recovers {
                throw AgentWorkflowInspectionUnavailable()
            }
        }
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(450))
        try appendCompletion(f)
        try await wait(recovers ? .succeeded : .uncertain, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(attempts.value >= 2 && attempts.value <= 3)
        #expect(saved.answer == (recovers ? "Full reply" : nil))
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func workflowMonitorStillRequiresStopForAutomaticHandoff(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        let completed = LockIsolated<[AgentWorkflowTranscriptOutcome]>([])
        let monitor = AgentReplyMonitor(state: { context in .init(isPending: true, instance: context.instance) }, completed: { _, _, outcome, _ in
            completed.withValue { $0.append(outcome) }
        }, waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) }, inspect: { $0 }, verificationTimeout: .milliseconds(100), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let provider = try #require(await f.support.replyProvider(plugin))
        let receipt = try #require(f.event(.submitted).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt), provider: provider)
        try await Task.sleep(for: .milliseconds(300))
        let activeCount = await monitor.activeCount
        #expect(completed.value.isEmpty && activeCount == 1)
        let stop = try #require(f.event(.stopCandidate).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: stop), provider: provider)
        for _ in 0..<100 {
            if !completed.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == [.succeeded("Full reply")])
        await monitor.shutdown()
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func stopArrivingDuringRecoveryKeepsItsVerifier(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        let recovering = LockIsolated(false)
        let release = LockIsolated(false)
        let completed = LockIsolated<[AgentWorkflowTranscriptOutcome]>([])
        let monitor = AgentReplyMonitor(state: { context in .init(isPending: true, instance: context.instance) }, completed: { context, _, outcome, _ in
            if context.candidate.kind == .submitted {
                recovering.setValue(true)
                for _ in 0..<500 {
                    if release.value {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Stop did not arrive while recovery was saving")
            } else {
                completed.withValue { $0.append(outcome) }
            }
        }, waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) }, inspect: { $0 }, synchronizeRecovery: { _ in }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let provider = try #require(await f.support.replyProvider(plugin))
        let receipt = try #require(f.event(.submitted).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt), provider: provider)
        for _ in 0..<500 {
            if recovering.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recovering.value)
        let stop = try #require(f.event(.stopCandidate).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: stop), provider: provider)
        release.setValue(true)
        for _ in 0..<100 {
            if !completed.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == [.succeeded("Full reply")])
        await monitor.shutdown()
        try await f.support.cleanup()
    }
}
