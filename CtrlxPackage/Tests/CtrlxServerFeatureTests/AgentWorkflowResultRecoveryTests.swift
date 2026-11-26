import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowResultRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_RECOVERY_LEDGER"] != nil))
    func savedLegacyLedgerRecoversInAnIsolatedCopy() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = try URL(fileURLWithPath: #require(env["CTRLX_WORKFLOW_RECOVERY_LEDGER"]))
        let runIDText = try #require(env["CTRLX_WORKFLOW_RECOVERY_RUN"])
        let runID = try #require(UUID(uuidString: runIDText))
        let data = try Data(contentsOf: source)
        let archive = try JSONDecoder().decode(AgentWorkflowArchive.self, from: data)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-legacy-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("ledger.json")
        try data.write(to: copy)
        #expect(copy != source)
        let store = AgentWorkflowStore(fileURL: copy, hostID: archive.hostID)
        let observations = archive.instances.map(AgentWorkflowObservation.init)
        _ = try await store.reconcile(observations)
        let before = try #require(await store.snapshot().runs.first { $0.id == runID })
        let original = try #require(before.invocations.last { $0.status == .uncertain && $0.nativeTurnID == nil })
        let reader = CodexProcessSessionReader()
        let recovery = AgentWorkflowResultRecovery(store: store, inspect: { instance in
            guard
                AgentSessionIdentityClient.processRuntimeID(String(instance.processID)) == instance.processRuntimeID,
                await reader.ownsSession(processID: String(instance.processID), runtimeID: instance.processRuntimeID, conversationID: instance.conversationID) else {
                throw AgentWorkflowInspectionUnavailable()
            }
            return instance
        }, provider: { _ in CodexPluginCore() }, transcriptPath: {
            await reader.transcriptPath(processID: String($0.processID), runtimeID: $0.processRuntimeID, conversationID: $0.conversationID)
        })
        let scheduled = LockIsolated(0)
        let service = AgentWorkflowService(store: store, scan: { _ in observations }, schedule: { _ in scheduled.withValue { $0 += 1 } }, resumeStep: { _, _ in
            Issue.record("An isolated recovery must not write to a terminal.")
        }, recoverResults: { try await recovery.recover($0) })
        let after = try await service.resume(runID: runID, expectedRevision: before.revision, authorizationExpiresAt: Date().addingTimeInterval(86_400))
        let recovered = try #require(after.invocations.first { $0.id == original.id })
        #expect(after.id == before.id && after.round == before.round && after.status == .running)
        #expect(after.invocations.map(\.id) == before.invocations.map(\.id))
        #expect(recovered.status == .succeeded && recovered.result != nil && recovered.nativeTurnID != nil)
        #expect(scheduled.value == 1)
        #expect(try !AgentWorkflowExecution(validating: after).readyNodeIDs.isEmpty)
        print("Isolated legacy recovery: run \(runID), invocation \(original.id), native turn \(recovered.nativeTurnID ?? ""), result characters \(recovered.result?.text.count ?? 0)")
    }

    @Test(arguments: ["same", "restarted", "first-conversation"], ["success", "explicit", "failed", "unfinished"])
    func missingReceiptUsesTheOriginalVerifiedSubmission(binding: String, outcome: String) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, explicit: outcome == "explicit", conversation: binding == "first-conversation" ? "" : "conversation")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.first)
        var observation = AgentWorkflowObservation(f.instance)
        observation.conversationID = "conversation"
        if binding != "same" {
            observation.processID = 20
            observation.processRuntimeID = "501:20:456:7"
        }
        let writer = try #require(await f.store.reconcile([observation]).first)
        let prompt = call.submissionText(pluginID: "codex")
        func input(_ turn: String, time: Date, answer: String?) -> [[String: Any]] {
            var result: [[String: Any]] = [
                ["type": "event_msg", "timestamp": time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), "payload": ["type": "task_started", "turn_id": turn]],
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]],
            ]
            if let answer {
                result.append(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": answer]])
            }
            return result
        }
        var records: [[String: Any]] = [["type": "session_meta", "payload": ["id": "conversation"]]]
        records += input("before-delivery", time: call.createdAt.addingTimeInterval(-60), answer: "Too early")
        records += input("original", time: call.createdAt.addingTimeInterval(1), answer: ["failed", "unfinished"].contains(outcome) ? nil : "Original findings")
        if outcome == "failed" {
            records.append(["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": "original"]])
        }
        if outcome != "unfinished" {
            records += input("repeated", time: call.createdAt.addingTimeInterval(10), answer: "Wrong later answer")
        }
        try records.reduce(into: Data()) { try $0.append(JSONSerialization.data(withJSONObject: $1) + Data([10])) }.write(to: f.transcript)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { value in
            #expect(value.matchesBinding(writer))
            return value
        }, provider: { _ in CodexPluginCore() }, transcriptPath: { _ in f.transcript.path })
        let before = try await f.store.snapshot().runs[0]
        let recovered = try await recovery.recover(before)
        let saved = try #require(recovered.invocations.first)
        #expect(recovered.id == before.id && recovered.round == before.round && recovered.status == .paused)
        if outcome == "unfinished" {
            #expect(saved.status == .uncertain && saved.nativeTurnID == nil)
        } else {
            #expect(saved.nativeTurnID == "original" && saved.instance?.matchesBinding(writer) == true)
            switch outcome {
            case "success": #expect(saved.status == .succeeded && saved.result?.text == "Original findings")
            case "failed": #expect(saved.status == .failed && saved.issue == "The native Codex turn was interrupted.")
            default: #expect(saved.status == .running && saved.stepTurn?.stopped == true && saved.stepTurn?.completionRequested == false && saved.result == nil)
            }
            let restarted = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: writer.hostID)
            #expect(try await restarted.snapshot().runs[0].invocations[0].nativeTurnID == "original")
        }
    }

    @Test(arguments: ["wrong-input", "wrong-conversation", "changed-writer", "changed-path", "capability"])
    func missingReceiptNeverBorrowsUnverifiedHistory(scenario: String) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.first)
        let input = scenario == "wrong-input" ? "Other task" : call.delivery.input.text
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "conversation"]],
            ["type": "event_msg", "timestamp": call.createdAt.addingTimeInterval(1).formatted(.iso8601), "payload": ["type": "task_started", "turn_id": "original"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": input]]]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "original", "last_agent_message": "Findings"]],
        ]
        try records.reduce(into: Data()) { try $0.append(JSONSerialization.data(withJSONObject: $1) + Data([10])) }.write(to: f.transcript)
        if scenario == "wrong-conversation" {
            var other = AgentWorkflowObservation(f.instance)
            other.conversationID = "other"
            _ = try await f.store.reconcile([other])
        }
        let inspected = LockIsolated(0), synchronized = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            inspected.withValue { $0 += 1 }
            var live = instance
            if scenario == "changed-writer", inspected.value > 2 {
                live.conversationID = "other"
            }
            if scenario == "capability" {
                live.capabilityIssue = "Hooks incompatible"
            }
            return live
        }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            synchronized.withValue { $0 += 1 }
        }, transcriptPath: { _ in scenario == "changed-path" && synchronized.value > 1 ? nil : f.transcript.path })
        let before = try await f.store.snapshot().runs[0]
        await #expect(throws: (any Error).self) { try await recovery.recover(before) }
        let saved = try await f.store.snapshot().runs[0].invocations[0]
        #expect(saved.status == .uncertain && saved.nativeTurnID == nil && saved.result == nil)
    }

    private struct Fixture: Sendable {
        let root: URL
        let transcript: URL
        let store: AgentWorkflowStore
        let instance: AgentWorkflowInstance
        let run: AgentWorkflowRun
        let downstream: UUID

        var input: String {
            run.invocations.last?.submissionText(pluginID: instance.pluginID) ?? ""
        }

        var recovery: AgentWorkflowResultRecovery {
            .init(store: store, inspect: { $0 }, provider: { plugin in
                if plugin == "codex" {
                    return CodexPluginCore()
                }
                return ClaudeCodePluginCore()
            })
        }

        func peer() throws -> PluginIngressPeer {
            try #require(PluginIngressPeer.capture(peerPID: instance.processID, userID: 501) { _ in
                .init(processID: instance.processID, parentProcessID: 1, userID: 501, startSeconds: 123, startMicroseconds: 4)
            })
        }

        func event(_ kind: PluginWorkflowEvent.Kind, text: String, hasPendingWork: Bool = false, turn: String = "turn") -> PluginEvent {
            .init(pluginID: instance.pluginID, sessionID: instance.conversationID, tmuxPane: instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: transcript.path, text: text, hasPendingWork: hasPendingWork
            ))
        }

        func recordReceipt(_ invocation: AgentWorkflowInvocation) async throws {
            let event = try #require(self.event(.submitted, text: invocation.delivery.input.text).workflow)
            #expect(try await store.recordPendingReceipt(.init(runID: run.id, invocation: invocation, instance: instance, candidate: event)))
        }
    }

    private func fixture(
        plugin: String, accepted: Bool = true, explicit: Bool = false, completeStep: Bool = true,
        conversation: String = "conversation", parallel: Bool = false, restart: Bool = true,
        onCompleted: @escaping @Sendable (AgentWorkflowRun) -> Void = { _ in }
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-recovery-\(UUID())")
        let transcript = root.appendingPathComponent("native.jsonl")
        let hostID = UUID(), fileURL = root.appendingPathComponent("ledger.json")
        let store = AgentWorkflowStore(fileURL: fileURL, hostID: hostID, onCompleted: onCompleted)
        let observation = AgentWorkflowObservation(
            pluginID: plugin, processID: 10, processRuntimeID: "501:10:123:4",
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: conversation, displayName: "Review", workingDirectory: root.path,
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )
        var observations = [observation]
        if parallel {
            var second = observation
            second.processID = 11
            second.processRuntimeID = "501:11:123:4"
            second.paneID = "%2"
            second.workspacePane.paneID = UUID()
            second.conversationID = "parallel"
            observations.append(second)
        }
        let instances = try await store.reconcile(observations)
        let instance = try #require(instances.first)
        let other = try #require(instances.last)
        let node = AgentWorkflowNode(name: "Review", agentInstanceID: instance.id, completion: explicit ? .explicit : .replyEnded)
        let next = AgentWorkflowNode(name: "Judge", agentInstanceID: instance.id)
        let entry = AgentWorkflowNode(name: "Start", content: .init(text: "Review these changes"))
        let sibling = AgentWorkflowNode(name: "Parallel review", agentInstanceID: other.id, allowsFinish: true, completion: explicit ? .explicit : .replyEnded)
        let nodes = parallel ? [entry, node, sibling, next] : [node, next]
        let edges: [AgentWorkflowEdge] = parallel
            ? [.init(source: entry.id, target: node.id), .init(source: entry.id, target: sibling.id), .init(source: node.id, target: next.id)]
            : [.init(source: node.id, target: next.id)]
        let definition = try await store.saveDefinition(.init(
            name: "Recovery", hostID: hostID, nodes: nodes, edges: edges,
            entryNodeID: parallel ? entry.id : node.id, initialInput: .init(text: "Review the changes")
        ), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        let written = try await store.update(runID: run.id) {
            if parallel {
                _ = try $0.prepareInvocation(nodeID: entry.id, now: Date())
                let call = try $0.prepareInvocation(nodeID: sibling.id, now: Date())
                try $0.beginWriting(invocationID: call.id, instance: other, now: Date())
                try $0.accept(invocationID: call.id, instance: other, nativeTurnID: "parallel-turn", transcriptPath: explicit ? transcript.path : nil)
            }
            let call = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: call.id, instance: instance, now: Date())
            if accepted {
                try $0.accept(invocationID: call.id, instance: instance, nativeTurnID: "turn", transcriptPath: transcript.path)
                if explicit, completeStep {
                    try $0.requestStepCompletion(invocationID: call.id, instance: instance, turnID: "turn", now: Date())
                }
            } else {
                try $0.didWrite(invocationID: call.id)
            }
        }
        if !restart {
            return .init(root: root, transcript: transcript, store: store, instance: instance, run: written, downstream: next.id)
        }
        let restarted = AgentWorkflowStore(fileURL: fileURL, hostID: hostID)
        let restored = try #require(await restarted.snapshot().runs.first)
        _ = try await restarted.reconcile(observations)
        return .init(root: root, transcript: transcript, store: restarted, instance: instance, run: restored, downstream: next.id)
    }

    private func records(plugin: String, input: String? = nil, conversation: String = "conversation", turn: String = "turn", finished: Bool = true) throws -> Data {
        var records: [[String: Any]]
        if plugin == "codex" {
            records = [
                ["type": "session_meta", "payload": ["id": conversation]],
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
            ]
            if let input {
                records.append(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": input]]]])
            }
            if finished {
                records.append(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": "Three findings"]])
            }
        } else {
            records = [
                ["type": "user", "uuid": "user", "promptId": turn],
                ["type": "assistant", "uuid": "answer", "parentUuid": "user", "message": ["id": "message", "stop_reason": "end_turn", "content": [["type": "text", "text": "Three findings"]]]],
            ]
            if finished {
                records.append([
                    "type": "system", "subtype": "stop_hook_summary", "uuid": "stop", "parentUuid": "answer",
                    "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": "",
                ])
            }
            if let input {
                records[0]["message"] = ["content": input]
            }
            records = records.map { $0.merging(["sessionId": conversation, "isSidechain": false]) { _, value in value } }
        }
        var data = Data()
        for record in records {
            try data.append(JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        return data
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func continueRecoversLostStopAndSchedulesOnlyDownstream(plugin: String, explicit: Bool) async throws {
        let f = try await fixture(plugin: plugin, explicit: explicit)
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.run.status == .paused && f.run.invocations[0].status == .uncertain)
        try records(plugin: plugin, input: f.input).write(to: f.transcript)
        let scheduled = LockIsolated<[UUID]>([])
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] },
            schedule: { id in scheduled.withValue { $0.append(id) } },
            resumeStep: { _, _ in Issue.record("Accepted work must not be resent.") },
            recoverResults: { try await f.recovery.recover($0) }
        )
        let run = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        #expect(run.status == .running)
        #expect(run.invocations.count == 1 && run.invocations[0].id == f.run.invocations[0].id)
        #expect(run.invocations[0].status == .succeeded)
        #expect(run.invocations[0].result?.text == "Three findings")
        #expect(run.invocations[0].result?.nativeTurnID == "turn")
        #expect(try AgentWorkflowExecution(validating: run).readyNodeIDs == [f.downstream])
        #expect(scheduled.value == [run.id])
        // Persistence keeps the result; another restart cannot recreate the original delivery.
        let restored = try AgentWorkflowExecution(restoring: run)
        #expect(restored.run.invocations[0].status == .succeeded)
    }

    @Test(arguments: [false, true], [false, true])
    func recoveryWaitsForItsOwnDeliveryBeforeReadingAReusedTurn(aborted: Bool, accepted: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.recordReceipt(f.run.invocations[0])
        if accepted {
            try await f.store.update(runID: f.run.id) {
                try $0.accept(invocationID: f.run.invocations[0].id, instance: f.instance, nativeTurnID: "turn", transcriptPath: f.transcript.path)
            }
        }
        var old = try records(plugin: "codex", input: "Previous task")
        if aborted {
            old.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
        }
        try old.write(to: f.transcript)
        let restarted = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("ledger.json"), hostID: f.run.definition.hostID)
        _ = try await restarted.reconcile([.init(f.instance)])
        let recovery = AgentWorkflowResultRecovery(store: restarted, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        let before = try #require(await restarted.snapshot().runs.first)
        let waiting = try await recovery.recover(before)
        #expect(waiting.invocations[0].status == .uncertain && waiting.invocations[0].result == nil)
        let writer = try FileHandle(forWritingTo: f.transcript)
        try writer.seekToEnd()
        try writer.write(contentsOf: records(plugin: "codex", input: f.input))
        try writer.close()
        let recovered = try await recovery.recover(waiting)
        #expect(recovered.invocations[0].status == .succeeded)
        #expect(recovered.invocations[0].result?.text == "Three findings")
    }

    @Test(arguments: ["codex", "claude-code"], ["conversation", "turn", "unfinished", "partial", "unaccepted", "proposal"])
    func incompleteOrUnrelatedEvidenceDoesNotRecover(plugin: String, change: String) async throws {
        let f = try await fixture(plugin: plugin, accepted: change != "unaccepted", explicit: change == "proposal", completeStep: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: plugin, input: f.input, conversation: change == "conversation" ? "other" : "conversation", turn: change == "turn" ? "other" : "turn", finished: change != "unfinished")
        if change == "partial" {
            bytes.removeLast()
        }
        try bytes.write(to: f.transcript)
        if change == "unaccepted" {
            await #expect(throws: AgentWorkflowError.self) { try await f.recovery.recover(f.run) }
        } else {
            #expect(try await f.recovery.recover(f.run) == f.run)
        }
        #expect(try await f.store.snapshot().runs[0] == f.run)
        #expect(try AgentWorkflowExecution(validating: f.run).readyNodeIDs.isEmpty)
        if change != "proposal" {
            let service = AgentWorkflowService(
                store: f.store, scan: { _ in [.init(f.instance)] },
                schedule: { _ in Issue.record("Unverified work cannot be handed downstream.") },
                recoverResults: { try await f.recovery.recover($0) }
            )
            await #expect(throws: AgentWorkflowError.self) {
                try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
            }
        }
    }

    @Test
    func continuingAnAcknowledgedLiveTaskDoesNotNeedItsTranscript() async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try #require(f.run.invocations.first?.id)
        let paused = try await f.store.update(runID: f.run.id) {
            try $0.accept(invocationID: id, instance: f.instance, nativeTurnID: "turn", transcriptPath: f.transcript.path)
        }
        #expect(paused.status == .paused && paused.invocations[0].status == .running)
        #expect(try await f.recovery.recover(paused) == paused)
    }

    @Test(arguments: ["same-host", "restart", "wrong-turn", "wrong-peer", "wrong-prompt"])
    func continueRechecksAuthenticatedPendingReceipt(evidence: String) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, conversation: "")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let conversation = UUID().uuidString
        let invocation = try #require(f.run.invocations.first)
        let writes = LockIsolated<[UUID]>([])
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { call, _ in writes.withValue { $0.append(call.id) } }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { instance in
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return instance
        }, provider: { _ in CodexPluginCore() })
        let pid = evidence == "wrong-peer" ? f.instance.processID + 1 : f.instance.processID
        let peer = try #require(PluginIngressPeer.capture(peerPID: pid, userID: 501) { _ in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 123, startMicroseconds: 4)
        })
        let submission = PluginEvent(pluginID: "codex", sessionID: conversation, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "turn", transcriptPath: f.transcript.path,
            text: evidence == "wrong-prompt" ? "Different input" : invocation.delivery.input.text
        ))
        try await router.receiveUnconfirmedSubmission(submission, peer: peer)
        let durable = evidence != "wrong-peer" && evidence != "wrong-prompt"
        #expect(try (await f.store.snapshot().pendingReceipts?[invocation.id] != nil) == durable)
        let store: AgentWorkflowStore
        let activeRouter: AgentWorkflowEventRouter
        if evidence == "same-host" {
            store = f.store
            activeRouter = router
            available.setValue(true)
        } else {
            await router.shutdown()
            store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
            let restoredRunner = AgentWorkflowRunner(store: store, transport: .init(
                inspect: { $0 }, prepare: { _, _ in }, write: { call, _ in writes.withValue { $0.append(call.id) } }
            ), onFailure: { Issue.record(Comment(rawValue: $0)) })
            activeRouter = AgentWorkflowEventRouter(store: store, runner: restoredRunner, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        }
        let paused = try #require(await store.snapshot().runs.first)
        #expect(paused.status == .paused && paused.invocations[0].nativeTurnID == nil)
        try records(plugin: "codex", input: f.input, conversation: conversation, turn: evidence == "wrong-turn" ? "different-turn" : "turn").write(to: f.transcript)
        let recovery = AgentWorkflowResultRecovery(store: store, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        let scheduled = LockIsolated<[UUID]>([])
        let service = AgentWorkflowService(
            store: store, scan: { _ in [.init(f.instance)] },
            schedule: { id in scheduled.withValue { $0.append(id) } },
            resumeStep: { _, _ in Issue.record("The original input must not be sent again.") },
            recoverResults: { try await recovery.recover($0) }
        )
        if durable, evidence != "wrong-turn" {
            let run = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
            #expect(run.invocations.map(\.id) == [invocation.id])
            #expect(run.invocations[0].result?.text == "Three findings")
            #expect(run.invocations[0].nativeTurnID == "turn")
            #expect(try AgentWorkflowExecution(validating: run).readyNodeIDs == [f.downstream])
            #expect(scheduled.value == [run.id])
            let archive = try await store.snapshot()
            #expect(archive.instances[0].conversationID == conversation)
            #expect(archive.pendingReceipts == nil)
        } else {
            await #expect(throws: AgentWorkflowError.self) {
                try await service.resume(runID: paused.id, expectedRevision: paused.revision)
            }
            #expect(try await store.snapshot().runs[0] == paused)
            #expect(scheduled.value.isEmpty)
            #expect(try (await store.snapshot().pendingReceipts?[invocation.id] != nil) == durable)
        }
        #expect(writes.value.isEmpty)
        await activeRouter.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: ["end", "process", "same-completion", "readiness"])
    func concurrentChangesDuringRecovery(change: String) async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        if change == "same-completion" {
            let invocation = try #require(f.run.invocations.first)
            let stop = try #require(f.event(.stopCandidate, text: "Three findings").workflow)
            try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: stop))
        }
        let inspections = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            let count = inspections.withValue { $0 += 1
                return $0
            }
            guard count == 2 else { return instance }
            switch change {
            case "end":
                _ = try await f.store.update(runID: f.run.id) { $0.end() }
            case "same-completion":
                let id = f.run.invocations[0].id, now = Date()
                try await f.store.update(runID: f.run.id) {
                    try $0.succeed(.init(invocationID: id, nativeTurnID: "turn", text: "Three findings", completedAt: now), instance: instance, now: now)
                }
            case "readiness":
                _ = try await f.store.update(runID: f.run.id) {
                    $0.waitForAgent(instance, reason: "Process inspection is temporarily unavailable.")
                }
            default:
                var changed = AgentWorkflowObservation(instance)
                changed.processRuntimeID = "replacement"
                return changed.instance(hostID: instance.hostID, id: instance.id)
            }
            return instance
        }, provider: { _ in CodexPluginCore() })
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] },
            schedule: { _ in
                #expect(change == "same-completion" || change == "readiness")
            },
            recoverResults: { try await recovery.recover($0) }
        )
        if change == "same-completion" || change == "readiness" {
            let run = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
            #expect(run.invocations[0].result?.text == "Three findings")
            #expect(try AgentWorkflowExecution(validating: run).readyNodeIDs == [f.downstream])
            return
        }
        await #expect(throws: AgentWorkflowError.self) {
            try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.invocations[0].result == nil)
        #expect(run.status == (change == "end" ? .ended : .paused))
    }

    @Test(arguments: ["before-restart", "during-verification"])
    func pendingWorkBlocksRecoveryUntilFinalStop(timing: String) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("A pending delivery cannot be resent.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { _ in
            throw AgentWorkflowInspectionUnavailable()
        })
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        let blocked = f.event(.stopCandidate, text: "Three findings", hasPendingWork: true)
        let store: AgentWorkflowStore
        let inspections = LockIsolated(0)
        if timing == "before-restart" {
            #expect(try await router.bufferPendingCompletion(blocked, peer: peer))
            await router.shutdown()
            store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        } else {
            store = f.store
        }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let recovery = AgentWorkflowResultRecovery(store: store, inspect: { instance in
            let count = inspections.withValue { $0 += 1
                return $0
            }
            if timing == "during-verification", count == 2 {
                let buffered = try await router.bufferPendingCompletion(blocked, peer: peer)
                #expect(buffered)
            }
            return instance
        }, provider: { _ in CodexPluginCore() })
        let scheduled = LockIsolated<[UUID]>([])
        let service = AgentWorkflowService(
            store: store, scan: { _ in [.init(f.instance)] }, schedule: { id in scheduled.withValue { $0.append(id) } },
            recoverResults: { try await recovery.recover($0) }
        )
        let paused = try #require(await store.snapshot().runs.first)
        await #expect(throws: AgentWorkflowError.self) {
            try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        }
        let held = try #require(await store.snapshot().runs.first)
        #expect(held.status == .paused && held.invocations[0].result == nil)
        #expect(scheduled.value.isEmpty)
        if timing == "before-restart" {
            let finalRunner = AgentWorkflowRunner(store: store, transport: .init(
                inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Unexpected write.") }
            ), onFailure: { Issue.record(Comment(rawValue: $0)) })
            let finalRouter = AgentWorkflowEventRouter(store: store, runner: finalRunner, inspect: { $0 })
            #expect(try await finalRouter.receive(f.event(.stopCandidate, text: "Three findings"), peer: peer)?.candidate.hasPendingWork == false)
            let acknowledged = try #require(await store.snapshot().runs.first)
            let resumed = try await service.resume(runID: held.id, expectedRevision: acknowledged.revision)
            #expect(resumed.invocations[0].result?.text == "Three findings")
            await finalRouter.shutdown()
            await finalRunner.shutdown()
        }
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [1, 2])
    func recoveryToleratesTheSameReceiptBeingConfirmedDuringIngress(pass: Int) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.first)
        try await f.recordReceipt(call)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let drains = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let count = drains.withValue { $0 += 1
                return $0
            }
            if count == pass {
                try await f.store.accept(
                    runID: f.run.id, invocationID: call.id, instance: f.instance, nativeTurnID: "turn",
                    transcriptPath: f.transcript.path, bindFirstConversation: false
                )
            }
        })
        let run = try await recovery.recover(f.run)
        #expect(run.invocations.first?.result?.text == "Three findings")
        #expect(run.status == .paused)
    }

    @Test
    func anUnchangedWaitStateDoesNotInvalidateRecovery() async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let waiting = try await f.store.update(runID: f.run.id) {
            $0.waitForAgent(f.instance, reason: "Native identity temporarily unavailable")
        }
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let unchanged = try await f.store.update(runID: f.run.id) {
                $0.waitForAgent(f.instance, reason: "Native identity temporarily unavailable")
            }
            #expect(unchanged == waiting)
        })
        let recovered = try await recovery.recover(waiting)
        #expect(recovered.invocations.first?.result?.text == "Three findings")
    }

    @Test
    func savedParallelFailurePreventsFinishFromPublishingCompletion() async throws {
        let notifications = LockIsolated(0)
        let f = try await fixture(plugin: "codex", accepted: false, parallel: true, restart: false, onCompleted: { _ in
            notifications.withValue { $0 += 1 }
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let finishingCall = try #require(f.run.invocations.first { $0.nativeTurnID == "parallel-turn" })
        let failingCall = try #require(f.run.invocations.last)
        let writer = try #require(f.run.instance(for: finishingCall))
        let finishing = try await f.store.update(runID: f.run.id) {
            try $0.requestFinish(invocationID: finishingCall.id, instance: writer, reason: "Work complete", now: .now)
        }
        #expect(finishing.status == .finishing)
        try await f.recordReceipt(failingCall)
        let failure = try #require(f.event(.failed, text: "Parallel failure").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: failingCall, instance: f.instance, candidate: failure))
        try await f.store.recordVerifiedAnswer(
            runID: f.run.id,
            result: .init(invocationID: finishingCall.id, nativeTurnID: "parallel-turn", text: "Finished", completedAt: .now),
            instance: writer, nativeEnd: nil, now: .now
        )
        let pending = try #require(await f.store.snapshot().runs.first)
        #expect(pending.status == .paused && pending.issue == failure.text)
        #expect(pending.invocations.first { $0.id == finishingCall.id }?.result?.text == "Finished")
        #expect(notifications.value == 0)
        try await f.store.accept(
            runID: f.run.id, invocationID: failingCall.id, instance: f.instance, nativeTurnID: "turn",
            transcriptPath: f.transcript.path, bindFirstConversation: false
        )
        let settled = try await f.store.update(runID: f.run.id) {
            try $0.fail(invocationID: failingCall.id, instance: f.instance, nativeTurnID: "turn", reason: failure.text)
        }
        #expect(settled.status == .paused && settled.invocations.last?.status == .failed)
        #expect(notifications.value == 0)
    }

    @Test(arguments: [false, true])
    func continueConfirmsEveryParallelBranchBeforeWritingAnyReminder(storedOnly: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: true, completeStep: false, parallel: true, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.last)
        let failure = try #require(f.event(.failed, text: "Buffered failure").workflow)
        let paused = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator paused") }
        let instances = try await f.store.snapshot().instances
        let writes = LockIsolated(0)
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in instances.map(AgentWorkflowObservation.init) },
            schedule: { _ in Issue.record("A newly failed branch needs another Continue.") },
            synchronizeEvents: { id in
                if id == call.id {
                    if storedOnly {
                        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: call, instance: f.instance, candidate: failure))
                    } else {
                        try await f.store.update(runID: f.run.id) {
                            try $0.fail(invocationID: id, instance: f.instance, nativeTurnID: "turn", reason: failure.text)
                        }
                    }
                }
            },
            resumeStep: { invocation, instance in
                let permit = try #require(await f.store.authorizeContinuation(invocation, instance: instance))
                try permit.perform { writes.withValue { $0 += 1 } }
            }
        )
        let current = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(current.status == .paused && current.issue == failure.text)
        #expect(current.invocations.last?.status == (storedOnly ? .running : .failed))
        #expect(writes.value == 0)
    }

    @Test
    func concurrentParallelFailureCannotAuthorizeAnotherWrite() async throws {
        let f = try await fixture(plugin: "codex", accepted: false, parallel: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.last)
        let sibling = try #require(f.run.invocations.first { $0.nativeTurnID == "parallel-turn" })
        let other = try #require(f.run.instance(for: sibling))
        try await f.recordReceipt(call)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            try await f.store.update(runID: f.run.id) {
                try $0.fail(invocationID: sibling.id, instance: other, nativeTurnID: "parallel-turn", reason: "Failed after Continue")
            }
            return instance
        }, provider: { _ in CodexPluginCore() })
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance), .init(other)] },
            schedule: { _ in Issue.record("The failure needs a new Continue action.") },
            recoverResults: { try await recovery.recover($0) }
        )
        let paused = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        #expect(paused.status == .paused)
        #expect(paused.invocations.filter { $0.nodeID == sibling.nodeID }.map(\.status) == [.failed])
    }

    @Test(arguments: [false, true])
    func continueUsesContinuationConfirmedWhileDrainingIngress(failed: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: true, completeStep: false, parallel: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sibling = try #require(f.run.invocations.first { $0.nativeTurnID == "parallel-turn" })
        let writer = try #require(f.run.instance(for: sibling))
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let continuation = AgentWorkflowStepTurn(id: "followup", transcriptPath: f.transcript.path, prompt: "Check again")
            _ = try await f.store.observeStepTurn(runID: f.run.id, invocationID: sibling.id, instance: writer, turn: continuation)
            let stop = PluginWorkflowEvent(
                kind: failed ? .failed : .stopCandidate, nativeTurnID: continuation.id,
                transcriptPath: continuation.transcriptPath, text: failed ? "Follow-up failed" : "Follow-up proposal"
            )
            try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: sibling, instance: writer, candidate: stop))
            if failed {
                _ = try await f.store.update(runID: f.run.id) {
                    try $0.fail(invocationID: sibling.id, instance: writer, nativeTurnID: continuation.id, reason: stop.text)
                }
            }
        })
        let resumedTurns = LockIsolated<[String]>([])
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance), .init(writer)] },
            schedule: { _ in #expect(!failed) },
            resumeStep: { call, _ in
                if let turn = call.stepTurn {
                    resumedTurns.withValue { $0.append(turn.id) }
                }
            },
            recoverResults: { try await recovery.recover($0) }
        )
        let run = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        let call = try #require(run.invocations.first { $0.id == sibling.id })
        #expect(run.status == (failed ? .paused : .running))
        #expect(call.status == (failed ? .failed : .running))
        #expect(call.resultTurnID == "followup")
        if failed {
            #expect(resumedTurns.value.isEmpty)
        } else {
            #expect(call.stepTurn?.stopped == true)
            #expect(resumedTurns.value.contains("followup"))
        }
    }

    @Test(arguments: [false, true])
    func recoveryCanRetryAfterAnInspectionFailure(alreadyAccepted: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        try await f.recordReceipt(invocation)
        if alreadyAccepted {
            try await f.store.accept(
                runID: f.run.id,
                invocationID: invocation.id,
                instance: f.instance,
                nativeTurnID: "turn",
                transcriptPath: f.transcript.path,
                bindFirstConversation: false
            )
        }
        let paused = try #require(await f.store.snapshot().runs.first)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let inspections = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            let count = inspections.withValue { $0 += 1
                return $0
            }
            if count == 2 {
                throw AgentWorkflowInspectionUnavailable()
            }
            return instance
        }, provider: { _ in CodexPluginCore() })
        await #expect(throws: AgentWorkflowInspectionUnavailable.self) {
            try await recovery.recover(paused)
        }
        let untouched = try #require(await f.store.snapshot().runs.first)
        #expect(untouched == paused)
        let recovered = try await recovery.recover(untouched)
        #expect(recovered.invocations[0].result?.text == "Three findings")
    }

    @Test(arguments: ["codex", "claude-code"])
    func nativeOutcomeDoesNotRequireTheOriginalToBeTheCurrentTurn(plugin: String) async throws {
        let f = try await fixture(plugin: plugin, accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        try await f.recordReceipt(invocation)
        if plugin == "codex" {
            var bytes = try records(plugin: plugin, input: f.input)
            bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"later\"}}\n".utf8))
            try bytes.write(to: f.transcript)
        } else {
            let rejection: [String: Any] = [
                "type": "system", "subtype": "informational", "uuid": "rejection", "sessionId": f.instance.conversationID,
                "timestamp": Date().formatted(.iso8601),
                "isSidechain": false, "preventContinuation": true,
                "content": "UserPromptSubmit operation blocked by hook:\n[fixture]: Rejected.\n\nOriginal prompt: " + invocation.delivery.input.text,
                "promptSubmitEnding": ["ending": ["kind": "blocked_by_hook", "reason": "Rejected."]],
            ]
            var bytes = try JSONSerialization.data(withJSONObject: rejection)
            bytes.append(10)
            try bytes.write(to: f.transcript)
        }
        let scheduled = LockIsolated<[UUID]>([])
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { id in scheduled.withValue { $0.append(id) } },
            recoverResults: { try await f.recovery.recover($0) }
        )
        let run = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        if plugin == "codex" {
            #expect(run.invocations[0].result?.text == "Three findings")
            #expect(scheduled.value == [run.id])
        } else {
            #expect(run.status == .paused)
            #expect(run.invocations[0].status == .failed && run.invocations[0].issue == "Rejected.")
            #expect(scheduled.value.isEmpty)
        }
    }

    @Test(arguments: ["stop-after-restart", "receipt-after-restart", "receipt-after-end", "unconfirmed-after-end"])
    func lateEvidenceStillArchivesTheOriginalResult(scenario: String) async throws {
        let ended = scenario.hasSuffix("-after-end")
        let f = try await fixture(plugin: "codex", accepted: false, restart: !ended)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let store: AgentWorkflowStore
        if ended {
            #expect(invocation.status == .awaitingAcceptance)
            try await f.store.update(runID: f.run.id) { $0.end() }
            store = f.store
        } else {
            try await f.recordReceipt(invocation)
            store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
            let paused = try #require(await store.snapshot().runs.first)
            let recovery = AgentWorkflowResultRecovery(store: store, inspect: { $0 }, provider: { _ in CodexPluginCore() })
            #expect(try await recovery.recover(paused) == paused)
        }
        let runner = AgentWorkflowRunner(store: store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Late events cannot start another task.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let monitor = AgentWorkflowCompletionMonitor(store: store, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, onVerified: {
            await monitor.verify($0, provider: CodexPluginCore())
        })
        let peer = try f.peer()
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        if scenario == "unconfirmed-after-end" {
            try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        } else if scenario != "stop-after-restart" {
            _ = try await router.receive(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        }
        if let stop = try await router.receive(f.event(.stopCandidate, text: "Three findings"), peer: peer) {
            await monitor.verify(stop, provider: CodexPluginCore())
        }
        for _ in 0..<100 {
            if try await store.snapshot().runs[0].invocations[0].status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(await store.snapshot().runs.first)
        #expect(run.status == (ended ? .ended : .paused))
        #expect(run.invocations.map(\.id) == [invocation.id])
        #expect(run.invocations[0].result?.text == "Three findings")
        await monitor.shutdown()
        await router.shutdown()
        await runner.shutdown()
    }

    @Test
    func nativeFailureIsArchivedWithoutInventingAnAnswer() async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: "codex", input: f.input, finished: false)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
        try bytes.write(to: f.transcript)
        let run = try await f.recovery.recover(f.run)
        #expect(run.status == .paused)
        #expect(run.invocations[0].status == .failed && run.invocations[0].result == nil)
        #expect(run.invocations[0].issue == "The native Codex turn was interrupted.")
    }

    @Test(arguments: [false, true])
    func lostStopRecoveryUsesTheLastNativeOutcome(aborted: Bool) async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: "codex", input: f.input)
        let event: [String: String] = aborted ? ["type": "turn_aborted", "turn_id": "turn"] : [
            "type": "task_complete", "turn_id": "turn", "last_agent_message": "Updated answer",
        ]
        try bytes.append(JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": event]))
        bytes.append(10)
        try bytes.write(to: f.transcript)
        let run = try await f.recovery.recover(f.run)
        #expect(run.invocations[0].status == (aborted ? .failed : .succeeded))
        #expect(run.invocations[0].result?.text == (aborted ? nil : "Updated answer"))
    }

    @Test
    func sameTurnFollowupNeedsItsOwnCompletion() async throws {
        let f = try await fixture(plugin: "codex", explicit: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: "codex", input: f.input)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn\"}}\n".utf8))
        try bytes.write(to: f.transcript)
        let pending = try await f.recovery.recover(f.run)
        #expect(pending.invocations[0].status == .uncertain && pending.invocations[0].result == nil)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn\",\"last_agent_message\":\"Follow-up answer\"}}\n".utf8))
        try bytes.write(to: f.transcript)
        let completed = try await f.recovery.recover(pending)
        #expect(completed.invocations[0].result?.text == "Follow-up answer")
    }

    @Test
    func aProvisionalNativeFailureCannotTurnASubmissionIntoASuccessfulStop() async throws {
        let f = try await fixture(plugin: "codex", accepted: false, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        var bytes = try records(plugin: "codex", input: f.input, finished: false)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
        try bytes.append(records(plugin: "codex", input: f.input))
        try bytes.write(to: f.transcript)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("A submission cannot hand off.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 })
        let submitted = try #require(await router.receive(f.event(.submitted, text: invocation.delivery.input.text), peer: f.peer()))
        let inspections = LockIsolated(0)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: runner, inspect: { instance in
            inspections.withValue { $0 += 1 }
            return instance
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(submitted, provider: CodexPluginCore())
        for _ in 0..<100 {
            if inspections.value >= 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(inspections.value >= 1)
        try await Task.sleep(for: .milliseconds(50))
        await monitor.shutdown()
        let current = try #require(await f.store.snapshot().runs.first)
        #expect(current.invocations.count == 1 && current.invocations[0].status == .running)
        #expect(current.invocations[0].result == nil)
        await router.shutdown()
        await runner.shutdown()
    }

    @Test
    func replacedNativeFailureIsNotCommitted() async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: "codex", input: f.input, finished: false)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
        try bytes.write(to: f.transcript)
        let replacement = try records(plugin: "codex", input: f.input)
        let drains = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let pass = drains.withValue { $0 += 1
                return $0
            }
            if pass == 2 {
                try replacement.write(to: f.transcript, options: .atomic)
            }
        })
        await #expect(throws: AgentWorkflowError.self) { try await recovery.recover(f.run) }
        #expect(try await f.store.snapshot().runs.first == f.run)
        let corrected = try await f.recovery.recover(f.run)
        #expect(corrected.invocations[0].result?.text == "Three findings")
    }

    @Test(arguments: ["native-abort", "abort-during-ingress", "identity-change"])
    func liveStopChecksNativeOutcomeAndWriterBeforeHandoff(change: String) async throws {
        let f = try await fixture(plugin: "codex", restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let abort = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8)
        var initial = try records(plugin: "codex", input: f.input)
        if change == "native-abort" {
            initial.append(abort)
        }
        try initial.write(to: f.transcript)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("An invalidated turn cannot hand off.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 })
        let context = try #require(await router.receive(f.event(.stopCandidate, text: "Three findings"), peer: f.peer()))
        let drained = LockIsolated(false)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: runner, inspect: { instance in
            if change == "identity-change", drained.value {
                var live = AgentWorkflowObservation(instance)
                live.processID += 1
                live.processRuntimeID = "replacement"
                live.conversationID = "different-conversation"
                return live.instance(hostID: instance.hostID, id: instance.id)
            }
            return instance
        }, synchronizeIngress: {
            if change == "abort-during-ingress", !drained.value {
                let handle = try FileHandle(forWritingTo: f.transcript)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: abort)
            }
            drained.setValue(true)
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(context, provider: CodexPluginCore())
        for _ in 0..<150 {
            if try await f.store.snapshot().runs.first?.status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(await f.store.snapshot().runs.first)
        #expect(current.invocations.map(\.id) == [invocation.id])
        #expect(current.status == .paused && current.invocations[0].result == nil)
        #expect(current.invocations[0].status == (change == "identity-change" ? .running : .failed))
        await monitor.shutdown()
        await router.shutdown()
        await runner.shutdown()
    }

    @Test
    func completingAnUnrelatedPartialLineRechecksTheMatchedStop() async throws {
        let f = try await fixture(plugin: "codex", restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator paused") }
        var bytes = try records(plugin: "codex", input: f.input)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"".utf8))
        try bytes.write(to: f.transcript)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Paused runs cannot hand off.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 })
        let context = try #require(await router.receive(f.event(.stopCandidate, text: "Three findings"), peer: f.peer()))
        let inspecting = LockIsolated(false)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: runner, inspect: { instance in
            inspecting.setValue(true)
            return instance
        }, verificationTimeout: .seconds(2), onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(context, provider: CodexPluginCore())
        for _ in 0..<100 {
            if inspecting.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(inspecting.value)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        let handle = try FileHandle(forWritingTo: f.transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}}\n".utf8))
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].invocations[0].status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(await f.store.snapshot().runs.first)
        #expect(current.status == .paused && current.invocations[0].result?.text == "Three findings")
        await monitor.shutdown()
        await router.shutdown()
        await runner.shutdown()
    }

    @Test
    func abortAppendedDuringIngressDrainInvalidatesAnEarlierReply() async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let drains = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let pass = drains.withValue { $0 += 1
                return $0
            }
            if pass == 2 {
                let file = try FileHandle(forWritingTo: f.transcript)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
            }
        })
        await #expect(throws: AgentWorkflowError.self) { try await recovery.recover(f.run) }
        #expect(try await f.store.snapshot().runs.first == f.run)
        let corrected = try await f.recovery.recover(f.run)
        #expect(corrected.invocations[0].status == .failed && corrected.invocations[0].result == nil)
    }

    @Test(arguments: [false, true])
    func savedFailureRecoversAnAcceptedTurnWithoutCompletionPermission(explicit: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: explicit, completeStep: false, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let failure = try #require(f.event(.failed, text: "The Agent failed").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: failure))
        let store: AgentWorkflowStore
        if explicit {
            store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        } else {
            store = f.store
            try await store.update(runID: f.run.id) { $0.pause(reason: "Agent inspection was interrupted") }
        }
        let paused = try #require(await store.snapshot().runs.first)
        #expect(paused.invocations[0].status == .running)
        let recovery = AgentWorkflowResultRecovery(store: store, inspect: { $0 }, provider: { _ in nil })
        let service = AgentWorkflowService(
            store: store, scan: { _ in [.init(f.instance)] },
            schedule: { _ in Issue.record("The newly confirmed failure requires another Continue.") },
            resumeStep: { _, _ in Issue.record("The failed turn cannot receive a reminder.") },
            recoverResults: { try await recovery.recover($0) }
        )
        let run = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(run.status == .paused && run.invocations[0].status == .failed)
        #expect(run.invocations[0].issue == "The Agent failed")
    }

    @Test
    func firstReceiptCannotOverwriteAConversationChangedDuringIngressDrain() async throws {
        let f = try await fixture(plugin: "codex", accepted: false, conversation: "")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let recordedConversation = UUID().uuidString, newerConversation = UUID().uuidString
        var writer = f.instance
        writer.conversationID = recordedConversation
        let receipt = PluginWorkflowEvent(kind: .submitted, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: invocation.delivery.input.text)
        let context = AgentWorkflowTurnContext(runID: f.run.id, invocation: invocation, instance: writer, candidate: receipt)
        #expect(try await f.store.recordPendingReceipt(context))
        try records(plugin: "codex", input: f.input, conversation: recordedConversation).write(to: f.transcript)
        let drains = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: {
            let pass = drains.withValue { $0 += 1
                return $0
            }
            if pass == 2 {
                var observation = AgentWorkflowObservation(f.instance)
                observation.conversationID = newerConversation
                _ = try await f.store.reconcile([observation])
            }
        })
        await #expect(throws: AgentWorkflowError.self) { try await recovery.recover(f.run) }
        let saved = try await f.store.snapshot()
        #expect(saved.runs.first?.invocations[0].nativeTurnID == nil)
        #expect(saved.instances.first?.conversationID == newerConversation)
    }

    @Test(arguments: [false, true])
    func bufferedContinuationIsProcessedBeforeAnyReminder(failed: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, explicit: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Unexpected runner write.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        func followup(_ kind: PluginWorkflowEvent.Kind, text: String) -> PluginEvent {
            .init(pluginID: "codex", sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: "followup", transcriptPath: f.transcript.path, text: text
            ))
        }
        _ = try await router.receive(followup(.submitted, text: "Follow-up request"), peer: peer)
        #expect(try await router.bufferPendingCompletion(
            followup(failed ? .failed : .stopCandidate, text: failed ? "Follow-up failed" : "Follow-up answer"),
            peer: peer
        ))
        let followupStart = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"followup\"}}\n".utf8)
        try (records(plugin: "codex", input: f.input) + followupStart).write(to: f.transcript)
        let writes = LockIsolated(0)
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in },
            synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            resumeStep: { invocation, instance in
                #expect(invocation.stepTurn?.id == "followup" && invocation.stepTurn?.stopped == true)
                let permit = try #require(await f.store.authorizeContinuation(invocation, instance: instance))
                try permit.perform { writes.withValue { $0 += 1 } }
                try await f.store.finishContinuation(invocation, authorization: permit, written: true)
            },
            recoverResults: {
                let run = try await f.recovery.recover($0)
                await router.discardRecoveredSubmissions(in: run)
                return run
            }
        )
        let run = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        #expect(run.invocations[0].stepTurn?.id == "followup")
        if failed {
            #expect(writes.value == 0)
            #expect(run.status == .paused && run.invocations[0].status == .failed)
            #expect(run.invocations[0].issue == "Follow-up failed")
        } else {
            #expect(writes.value == 1)
            #expect(run.status == .running && run.invocations[0].continuationTurnID == "followup")
        }
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [PluginWorkflowEvent.Kind.stopCandidate, .failed])
    func recoveryHonorsBufferedCompletion(kind: PluginWorkflowEvent.Kind) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Unexpected runner write.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { _ in
            throw AgentWorkflowInspectionUnavailable()
        })
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        let text = kind == .failed ? "Native failure" : "Updated final answer"
        #expect(try await router.bufferPendingCompletion(f.event(kind, text: text), peer: peer))
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let recovered = try await f.recovery.recover(f.run)
        if kind == .failed {
            #expect(recovered.invocations[0].status == .failed)
            #expect(recovered.invocations[0].issue == text)
            #expect(recovered.invocations[0].result == nil)
        } else {
            #expect(recovered == f.run)
            let log = try FileHandle(forWritingTo: f.transcript)
            try log.seekToEnd()
            try log.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn\",\"last_agent_message\":\"Updated final answer\"}}\n".utf8))
            try log.close()
            let updated = try await f.recovery.recover(f.run)
            #expect(updated.invocations[0].result?.text == text)
        }
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func settledReceiptCannotPauseRunOrHijackNextSubmission(explicit: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, explicit: explicit)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Unexpected runner write.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(
            store: f.store, runner: runner, inspect: { $0 }, verificationTimeout: .milliseconds(50),
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        if explicit {
            #expect(try await router.bufferPendingCompletion(f.event(.failed, text: "Native failure"), peer: peer))
        }
        let recovered = try await f.recovery.recover(f.run)
        let resumed = try await f.store.update(runID: f.run.id, expectedRevision: recovered.revision) {
            try $0.resume(instances: [f.instance], now: Date())
        }
        if explicit {
            let run = try await f.store.update(runID: resumed.id) {
                let next = try $0.prepareInvocation(nodeID: invocation.nodeID, now: Date())
                try $0.beginWriting(invocationID: next.id, instance: f.instance, now: Date())
                try $0.didWrite(invocationID: next.id)
            }
            let next = try #require(run.invocations.last)
            let submitted = PluginEvent(pluginID: "codex", sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
                kind: .submitted, nativeTurnID: "retry-turn", transcriptPath: f.transcript.path, text: next.delivery.input.text
            ))
            _ = try await router.receive(submitted, peer: peer)
            let latest = try #require(await f.store.snapshot().runs.first?.invocations.last)
            #expect(latest.id == next.id && latest.nativeTurnID == "retry-turn")
        } else {
            // Exercise the timeout even when no caller cleared the router proactively.
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await f.store.snapshot().runs.first?.status == .running)
        }
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [1, 2])
    func incompatibleHookCannotAcceptRecoveredReceipt(unsupportedInspection: Int) async throws {
        let f = try await fixture(plugin: "codex", accepted: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        try await f.recordReceipt(invocation)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let reads = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            let count = reads.withValue { $0 += 1
                return $0
            }
            var verified = instance
            if count == unsupportedInspection {
                verified.capabilityIssue = "Unsupported hook"
            }
            return verified
        }, provider: { _ in CodexPluginCore() })
        await #expect(throws: AgentWorkflowError.self) {
            try await recovery.recover(f.run)
        }
        #expect(try await f.store.snapshot().runs.first == f.run)
    }

    @Test(arguments: [false, true])
    func recoveredExplicitDeliveryContinuesWithoutCompletingStep(savedStop: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, explicit: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        try await f.recordReceipt(invocation)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        if savedStop {
            let stop = try #require(f.event(.stopCandidate, text: "Three findings").workflow)
            try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: stop))
        }
        let reminders = LockIsolated<[UUID]>([])
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in },
            resumeStep: { invocation, _ in reminders.withValue { $0.append(invocation.id) } },
            recoverResults: { try await f.recovery.recover($0) }
        )
        let resumed = try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        #expect(resumed.invocations[0].stepTurn?.id == "turn")
        #expect(resumed.invocations[0].stepTurn?.stopped == true)
        #expect(resumed.invocations[0].stepTurn?.completionRequested == false)
        #expect(resumed.invocations[0].result == nil)
        #expect(reminders.value == [invocation.id])
        #expect(try AgentWorkflowExecution(validating: resumed).readyNodeIDs.isEmpty)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.store.update(runID: resumed.id) {
                try $0.requestStepCompletion(invocationID: invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
        }
        let fileURL = await f.store.fileURL
        let saved = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fileURL))
        #expect(try saved.pendingReceipts?[invocation.id]?.stopBoundary?.size == UInt64(records(plugin: "codex", input: f.input).count))
        let handle = try FileHandle(forWritingTo: f.transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn\"}}\n".utf8))
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("The turn has no final Stop yet.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        _ = try await router.receive(f.event(.submitted, text: "Proceed with the review"), peer: f.peer())
        let completed = try await f.store.update(runID: f.run.id) {
            try $0.requestStepCompletion(invocationID: invocation.id, instance: f.instance, turnID: "turn", now: Date())
        }
        #expect(completed.invocations[0].stepTurn?.completionRequested == true)
        let receipt = try await f.store.snapshot().pendingReceipts?[invocation.id]
        #expect(receipt?.completion == nil && receipt?.stopBoundary == saved.pendingReceipts?[invocation.id]?.stopBoundary)
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func savingStopClosesTheExplicitTurnAcrossRestart(legacySplitWrite: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: true, completeStep: false, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let stop = try #require(f.event(.stopCandidate, text: "Proposal").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: stop))
        let fileURL = await f.store.fileURL
        var saved = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fileURL))
        #expect(saved.pendingReceipts?[invocation.id]?.completion == stop)
        #expect(saved.runs[0].invocations[0].stepTurn?.stopped == true)
        if legacySplitWrite {
            saved.runs[0].invocations[0].stepTurn?.stopped = false
            try JSONEncoder().encode(saved).write(to: fileURL)
        }
        let restarted = AgentWorkflowStore(fileURL: fileURL, hostID: f.instance.hostID)
        #expect(try await restarted.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
        await #expect(throws: AgentWorkflowError.self) {
            try await restarted.update(runID: f.run.id) {
                try $0.requestStepCompletion(invocationID: invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
        }
    }

    @Test
    func acceptedReceiptReplayPreservesExplicitCompletionRequest() async throws {
        let f = try await fixture(plugin: "codex", explicit: true, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let paused = try await f.store.update(runID: f.run.id) {
            $0.waitForResult(invocationID: invocation.id, turnID: "turn", reason: "Waiting for Stop")
        }
        #expect(paused.invocations[0].status == .uncertain && paused.invocations[0].stepTurn?.completionRequested == true)
        try await f.store.accept(
            runID: paused.id, invocationID: invocation.id, instance: f.instance, nativeTurnID: "turn",
            transcriptPath: f.transcript.path, bindFirstConversation: false
        )
        let restored = try #require(await f.store.snapshot().runs.first)
        #expect(restored.invocations[0].status == .running)
        #expect(restored.invocations[0].stepTurn?.completionRequested == true)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let recovered = try await f.recovery.recover(restored)
        #expect(recovered.invocations[0].result?.text == "Three findings")
    }

    @Test(arguments: [false, true])
    func verifiedReceiptRebindsAnUncertainResultToTheResumedProcess(followup: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: true, completeStep: false, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let turn = followup ? "followup" : "turn"
        let prompt = followup ? "Implement the proposal" : invocation.delivery.input.text
        if followup {
            try await f.store.observeStepTurn(
                runID: f.run.id, invocationID: invocation.id, instance: f.instance, turn: .init(id: turn, transcriptPath: f.transcript.path, prompt: prompt)
            )
        }
        try await f.store.update(runID: f.run.id) {
            try $0.requestStepCompletion(invocationID: invocation.id, instance: f.instance, turnID: turn, now: Date())
        }
        let store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        var observation = AgentWorkflowObservation(f.instance)
        observation.processID = 11
        observation.processRuntimeID = "501:11:123:5"
        let resumed = try #require(await store.reconcile([observation]).first)
        let peer = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { _ in
            .init(processID: 11, parentProcessID: 1, userID: 501, startSeconds: 123, startMicroseconds: 5)
        })
        let runner = AgentWorkflowRunner(store: store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("A failed turn cannot hand off.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 })
        try records(plugin: "codex", input: f.input, turn: turn).write(to: f.transcript)
        _ = try await router.receive(f.event(.submitted, text: prompt, turn: turn), peer: peer)
        let accepted = try #require(await store.snapshot().runs.first)
        #expect(accepted.invocations[0].status == .running)
        #expect(accepted.instance(for: accepted.invocations[0])?.matchesBinding(resumed) == true)
        #expect(accepted.invocations[0].stepTurn?.completionRequested == true)
        #expect(accepted.invocations[0].nativeTurnID == "turn" && accepted.invocations[0].resultTurnID == turn)
        _ = try await router.receive(f.event(.failed, text: "Resumed process failed", turn: turn), peer: peer)
        let failed = try #require(await store.snapshot().runs.first)
        #expect(failed.invocations[0].status == .failed && failed.invocations[0].result == nil)
        #expect(failed.invocations[0].issue == "Resumed process failed")
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"])
    func savedFailureTakesPrecedenceOverAContinuation(plugin: String) async throws {
        let f = try await fixture(plugin: plugin, explicit: true, completeStep: false, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.first)
        let provider = try #require(await f.recovery.provider(plugin))
        let available = LockIsolated(false)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("A failed invocation cannot hand off.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in provider })
        await #expect(throws: AgentWorkflowInspectionUnavailable.self) {
            _ = try await router.receive(f.event(.failed, text: "Original failure"), peer: f.peer())
        }
        let pending = try await f.store.snapshot()
        #expect(pending.runs[0].invocations[0].status == .running)
        #expect(pending.pendingFailure(for: call)?.text == "Original failure")
        let bytes = try records(plugin: plugin, input: f.input, finished: false) + records(plugin: plugin, input: f.input, turn: "later")
        try bytes.write(to: f.transcript)
        available.setValue(true)
        _ = try await router.receive(f.event(.submitted, text: "New question", turn: "later"), peer: f.peer())
        #expect(try await router.receive(f.event(.stopCandidate, text: "Three findings", turn: "later"), peer: f.peer()) == nil)
        let run = try #require(await f.store.snapshot().runs.first)
        #expect(run.status == .paused && run.invocations[0].status == .failed)
        #expect(run.invocations[0].stepTurn?.id == "turn" && run.invocations[0].result == nil)
        #expect(run.invocations[0].issue == "Original failure")
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func persistedFailureRevokesAnUnusedContinuationPermit(parallel: Bool) async throws {
        let f = try await fixture(plugin: "codex", explicit: true, completeStep: false, parallel: parallel, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.last)
        let waiting = try #require(f.run.invocations.first { $0.stepTurn != nil })
        let writer = try #require(f.run.instance(for: waiting))
        let permit = try #require(await f.store.authorizeContinuation(waiting, instance: writer))
        let failure = try #require(f.event(.failed, text: "Agent failed before paste").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: failure))
        let saved = try await f.store.snapshot()
        #expect(saved.runs.first?.invocations.last?.status == .running)
        #expect(saved.pendingReceipts?[invocation.id]?.completion(for: .init(nativeTurnID: "turn", transcriptPath: f.transcript.path)) == failure)
        #expect(throws: AgentWorkflowError.self) {
            try permit.perform { Issue.record("A failed turn cannot launch its queued input.") }
        }
        try await f.store.finishContinuation(waiting, authorization: permit, written: false)
        await #expect(throws: AgentWorkflowError.self) {
            _ = try await f.store.authorizeContinuation(waiting, instance: writer)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func replayAfterRestartArchivesThePreviouslySavedFailure(accepted: Bool, ended: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: accepted, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        if !accepted {
            try await f.recordReceipt(invocation)
        }
        let failure = try #require(f.event(.failed, text: "Native failure").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: invocation, instance: f.instance, candidate: failure))
        if ended {
            try await f.store.update(runID: f.run.id) { $0.end() }
        }
        let store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        let runner = AgentWorkflowRunner(store: store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Historical recovery cannot write tasks.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let ready = LockIsolated(!accepted)
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: {
            guard ready.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        })
        let replay = f.event(.submitted, text: invocation.delivery.input.text)
        if accepted {
            try await router.receiveUnconfirmedSubmission(replay, peer: f.peer())
            if !ended {
                #expect(try await store.snapshot().runs[0].invocations[0].status == .uncertain)
                _ = try await store.reconcile([.init(f.instance)])
                ready.setValue(true)
                try await router.requireVerifiedSubmission(invocation.id)
            }
        } else {
            _ = try await store.reconcile([.init(f.instance)])
            _ = try await router.receive(replay, peer: f.peer())
        }
        let run = try #require(await store.snapshot().runs.first)
        #expect(run.status == (ended ? .ended : .paused))
        #expect(run.invocations[0].status == .failed)
        #expect(run.invocations[0].issue == "Native failure")
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func replayAfterRestartVerifiesASavedStop(ended: Bool) async throws {
        let f = try await fixture(plugin: "codex", restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let call = try #require(f.run.invocations.first)
        let stop = try #require(f.event(.stopCandidate, text: "Three findings").workflow)
        try await f.store.recordCompletionEvidence(.init(runID: f.run.id, invocation: call, instance: f.instance, candidate: stop))
        if ended {
            try await f.store.update(runID: f.run.id) { $0.end() }
        }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let store = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        _ = try await store.reconcile([.init(f.instance)])
        let runner = AgentWorkflowRunner(store: store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Historical recovery cannot write tasks.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let monitor = AgentWorkflowCompletionMonitor(store: store, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, onVerified: {
            await monitor.verify($0, provider: CodexPluginCore())
        })
        if let context = try await router.receive(f.event(.submitted, text: call.delivery.input.text), peer: f.peer()) {
            await monitor.verify(context, provider: CodexPluginCore())
        }
        for _ in 0..<100 {
            if try await store.snapshot().runs.first?.invocations.first?.status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(await store.snapshot().runs.first)
        #expect(current.status == (ended ? .ended : .paused) && current.invocations.count == 1)
        #expect(current.invocations[0].result?.text == "Three findings")
        await monitor.shutdown()
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func recoveringExplicitReceiptRetiresOnlyItsOriginalRetry(queuedContinuation: Bool) async throws {
        let f = try await fixture(plugin: "codex", accepted: false, explicit: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.first)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Unexpected runner write.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(
            store: f.store, runner: runner, inspect: { $0 },
            verificationTimeout: queuedContinuation ? .seconds(2) : .milliseconds(50),
            provider: { _ in CodexPluginCore() },
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        if queuedContinuation {
            let followup = PluginEvent(pluginID: "codex", sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
                kind: .submitted, nativeTurnID: "followup", transcriptPath: f.transcript.path, text: "Continue the review"
            ))
            _ = try await router.receive(followup, peer: peer)
        }
        var transcript = try records(plugin: "codex", input: f.input)
        if queuedContinuation {
            transcript.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"followup\"}}\n".utf8))
        }
        try transcript.write(to: f.transcript)
        let recovered = try await f.recovery.recover(f.run)
        await router.discardRecoveredSubmissions(in: recovered)
        try await router.requireVerifiedSubmission(invocation.id)
        let verified = try #require(await f.store.snapshot().runs.first)
        try await f.store.update(runID: f.run.id, expectedRevision: verified.revision) {
            try $0.resume(instances: [f.instance], now: Date())
        }
        if queuedContinuation {
            for _ in 0..<100 {
                if try await f.store.snapshot().runs.first?.invocations[0].stepTurn?.id == "followup" {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } else {
            try await Task.sleep(for: .milliseconds(300))
        }
        let run = try #require(await f.store.snapshot().runs.first)
        #expect(run.status == .running)
        #expect(run.invocations[0].stepTurn?.id == (queuedContinuation ? "followup" : "turn"))
        #expect(run.invocations[0].result == nil)
        await router.shutdown()
        await runner.shutdown()
    }

    @Test
    func idlePauseMakesAcceptedTurnEligibleForRecovery() async throws {
        let f = try await fixture(plugin: "codex", restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in },
            recoverResults: { try await f.recovery.recover($0) }
        )
        try await service.checkActiveRuns(completionGrace: 0)
        let paused = try #require(await f.store.snapshot().runs.first)
        #expect(paused.status == .paused && paused.invocations[0].status == .uncertain)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.invocations[0].result?.text == "Three findings")
    }

    @Test
    func completedRunStillAcceptsAndArchivesAnotherWrittenStep() async throws {
        let f = try await fixture(plugin: "codex", accepted: false, parallel: true, restart: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invocation = try #require(f.run.invocations.last)
        let finish = try #require(f.run.invocations.first { $0.nativeTurnID == "parallel-turn" })
        let writer = try #require(f.run.instance(for: finish))
        let completed = try await f.store.update(runID: f.run.id) {
            try $0.requestFinish(invocationID: finish.id, instance: writer, reason: "Done", now: Date())
            try $0.succeed(.init(invocationID: finish.id, nativeTurnID: "parallel-turn", text: "Done", completedAt: Date()), instance: writer, now: Date())
        }
        #expect(completed.status == .completed)
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in Issue.record("Completion cannot write new work.") }
        ), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 }, onVerified: {
            await monitor.verify($0, provider: CodexPluginCore())
        })
        let peer = try f.peer()
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: invocation.delivery.input.text), peer: peer)
        try records(plugin: "codex", input: f.input).write(to: f.transcript)
        _ = try await router.receive(f.event(.stopCandidate, text: "Three findings"), peer: peer)
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].invocations.last?.status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(await f.store.snapshot().runs.first)
        #expect(run.status == .completed)
        #expect(run.invocations.last?.result?.text == "Three findings")
        await monitor.shutdown()
        await router.shutdown()
        await runner.shutdown()
    }
}
