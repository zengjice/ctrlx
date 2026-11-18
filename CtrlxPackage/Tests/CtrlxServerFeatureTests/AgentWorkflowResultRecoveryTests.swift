import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowResultRecoveryTests {
    private struct Fixture: Sendable {
        let root: URL
        let transcript: URL
        let store: AgentWorkflowStore
        let instance: AgentWorkflowInstance
        let run: AgentWorkflowRun
        let downstream: UUID

        var recovery: AgentWorkflowResultRecovery {
            .init(store: store, inspect: { $0 }, provider: { plugin in
                if plugin == "codex" {
                    return CodexPluginCore()
                }
                return ClaudeCodePluginCore()
            })
        }
    }

    private func fixture(plugin: String, accepted: Bool = true, explicit: Bool = false, completeStep: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-recovery-\(UUID())")
        let transcript = root.appendingPathComponent("native.jsonl")
        let hostID = UUID(), fileURL = root.appendingPathComponent("ledger.json")
        let store = AgentWorkflowStore(fileURL: fileURL, hostID: hostID)
        let instance = try #require(await store.reconcile([.init(
            pluginID: plugin, processID: 10, processRuntimeID: "runtime",
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Review", workingDirectory: root.path,
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )]).first)
        let node = AgentWorkflowNode(name: "Review", agentInstanceID: instance.id, completion: explicit ? .explicit : .replyEnded)
        let next = AgentWorkflowNode(name: "Judge", agentInstanceID: instance.id)
        let definition = try await store.saveDefinition(.init(
            name: "Recovery", hostID: hostID, nodes: [node, next], edges: [.init(source: node.id, target: next.id)],
            entryNodeID: node.id, initialInput: .init(text: "Review the changes")
        ), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        _ = try await store.update(runID: run.id) {
            let call = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: call.id, instance: instance, now: Date())
            if accepted {
                try $0.accept(invocationID: call.id, instance: instance, nativeTurnID: "turn", transcriptPath: transcript.path)
                if explicit, completeStep {
                    try $0.requestStepCompletion(invocationID: call.id, instance: instance, turnID: "turn", now: Date())
                }
            }
        }
        let restarted = AgentWorkflowStore(fileURL: fileURL, hostID: hostID)
        let restored = try #require(await restarted.snapshot().runs.first)
        _ = try await restarted.reconcile([.init(instance)])
        return .init(root: root, transcript: transcript, store: restarted, instance: instance, run: restored, downstream: next.id)
    }

    private func records(plugin: String, conversation: String = "conversation", turn: String = "turn", finished: Bool = true) throws -> Data {
        var records: [[String: Any]]
        if plugin == "codex" {
            records = [
                ["type": "session_meta", "payload": ["id": conversation]],
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
            ]
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
        try records(plugin: plugin).write(to: f.transcript)
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

    @Test(arguments: ["codex", "claude-code"], ["conversation", "turn", "unfinished", "partial", "unaccepted", "proposal"])
    func incompleteOrUnrelatedEvidenceDoesNotRecover(plugin: String, change: String) async throws {
        let f = try await fixture(plugin: plugin, accepted: change != "unaccepted", explicit: change == "proposal", completeStep: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: plugin, conversation: change == "conversation" ? "other" : "conversation", turn: change == "turn" ? "other" : "turn", finished: change != "unfinished")
        if change == "partial" {
            bytes.removeLast()
        }
        try bytes.write(to: f.transcript)
        #expect(try await f.recovery.recover(f.run) == f.run)
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

    @Test(arguments: ["end", "process"])
    func changedStateDuringRecoveryCannotCommitOrResume(change: String) async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try records(plugin: "codex").write(to: f.transcript)
        let inspections = LockIsolated(0)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { instance in
            let count = inspections.withValue { $0 += 1
                return $0
            }
            if count == 2 {
                if change == "end" {
                    _ = try await f.store.update(runID: f.run.id) { $0.end() }
                } else {
                    var changed = AgentWorkflowObservation(instance)
                    changed.processRuntimeID = "replacement"
                    return changed.instance(hostID: instance.hostID, id: instance.id)
                }
            }
            return instance
        }, provider: { _ in CodexPluginCore() })
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] },
            schedule: { _ in Issue.record("Concurrent changes must prevent resume.") },
            recoverResults: { try await recovery.recover($0) }
        )
        await #expect(throws: AgentWorkflowError.self) {
            try await service.resume(runID: f.run.id, expectedRevision: f.run.revision)
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.invocations[0].result == nil)
        #expect(run.status == (change == "end" ? .ended : .paused))
    }

    @Test
    func nativeFailureIsArchivedWithoutInventingAnAnswer() async throws {
        let f = try await fixture(plugin: "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try records(plugin: "codex", finished: false)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n".utf8))
        try bytes.write(to: f.transcript)
        let run = try await f.recovery.recover(f.run)
        #expect(run.status == .paused)
        #expect(run.invocations[0].status == .failed && run.invocations[0].result == nil)
        #expect(run.invocations[0].issue == "The native Codex turn was interrupted.")
    }
}
