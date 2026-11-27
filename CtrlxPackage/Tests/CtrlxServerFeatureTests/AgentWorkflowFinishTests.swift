import CodexPluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowFinishTests {
    private struct Fixture: Sendable {
        let directory: URL
        let store: AgentWorkflowStore
        let service: AgentWorkflowAgentService
        let instance: AgentWorkflowInstance
        let run: AgentWorkflowRun
        let invocation: AgentWorkflowInvocation
        let peer: PluginIngressPeer

        func request(id: UUID? = nil, reason: String = "Review passed", method: String = "workflow.finish") -> JSONRPCRequest {
            .init(id: UUID().uuidString, method: method, params: [
                "invocationId": .string((id ?? invocation.id).uuidString), "reason": .string(reason),
            ])
        }
    }

    private func fixture(
        allowsFinish: Bool = true,
        completion: AgentWorkflowNode.Completion = .replyEnded,
        loop: Bool = false,
        afterLoop: Bool = false,
        maximumRounds: Int = 5,
        notifyOnAgentCompletion: Bool? = nil,
        onCompleted: @escaping @Sendable (AgentWorkflowRun) -> Void = { _ in },
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance = { $0 }
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-finish-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID, onCompleted: onCompleted)
        let instance = try #require(await store.reconcile([.init(
            pluginID: "codex", processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "1:100", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Reviewer", workingDirectory: directory.path,
            capabilities: .init(maximumInputBytes: 10_000), readiness: .ready
        )]).first)
        let node = AgentWorkflowNode(name: "Reviewer", agentInstanceID: instance.id, allowsFinish: allowsFinish, completion: completion)
        var draft = AgentWorkflowDefinition(
            name: "Review", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id,
            loop: loop ? .init(finalNodeID: node.id, maximumRounds: maximumRounds) : nil
        )
        if afterLoop {
            let repair = AgentWorkflowNode(name: "Repair", content: .init(text: "Fix findings"))
            let summary = AgentWorkflowNode(name: "Summary", content: .init(text: "Summarize review"))
            let handoff = AgentWorkflowNode(name: "Handoff", content: .init(text: "Final handoff"))
            draft.nodes += [repair, summary, handoff]
            draft.edges = [
                .init(source: node.id, target: repair.id),
                .init(source: node.id, target: summary.id),
                .init(source: summary.id, target: handoff.id),
            ]
            draft.loop = .init(finalNodeID: repair.id, maximumRounds: maximumRounds, entryNodeID: node.id, exitNodeID: summary.id)
        }
        draft.notifyOnAgentCompletion = notifyOnAgentCompletion
        let definition = try await store.saveDefinition(draft, expectedRevision: nil)
        let transcriptPath: String
        if afterLoop {
            let transcript = directory.appendingPathComponent("native.jsonl")
            try Data("""
            {"type":"session_meta","payload":{"id":"conversation"}}
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}

            """.utf8).write(to: transcript)
            transcriptPath = transcript.path
        } else {
            transcriptPath = "/fixture/native.jsonl"
        }
        let run = try await store.start(
            definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(),
            now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600)
        )
        let active = try await store.update(runID: run.id) {
            let invocation = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            try $0.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn-1", transcriptPath: transcriptPath)
        }
        let peer = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { pid in
            switch pid {
            case 11: .init(processID: 11, parentProcessID: 10, userID: 501, startSeconds: 101, startMicroseconds: 0)
            case 10: .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
            default: nil
            }
        })
        return try .init(
            directory: directory, store: store,
            service: AgentWorkflowAgentService(store: store, inspect: inspect, synchronizeEvents: { _ in }, provider: { _ in CodexPluginCore() }),
            instance: instance, run: active, invocation: #require(active.invocations.first), peer: peer
        )
    }

    @Test(arguments: [false, true])
    func approvedLoopHandsOffVerifiedResultOnlyOnce(restart: Bool) async throws {
        let f = try await fixture(afterLoop: true, maximumRounds: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let steps = f.run.definition.nodes
        let reviewID = f.invocation.id
        let command = f.request(method: "workflow.exitLoop")
        #expect(f.invocation.delivery.input.text.contains("ctrlx workflow exit-loop"))
        let original = AgentWorkflowRunState(f.run, currentInstances: [f.instance])
        #expect(original.nodes[2].waitsForLoopExit == true)
        #expect(try AgentWorkflowExecution(validating: f.run).readyNodeIDs.isEmpty)
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        #expect(await f.service.handle(command, peer: nil).error?.code == "workflow_denied")
        let path = try #require(f.invocation.nativeTranscriptPath)
        try #require(await f.store.observeSubmission(.init(
            kind: .submitted, nativeTurnID: "turn-1", transcriptPath: path, text: f.invocation.delivery.input.text
        ), instance: f.instance) == .ready)
        if restart {
            try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator paused") }
        }
        #expect(await f.service.handle(command, peer: f.peer).error == nil)
        #expect(await f.service.handle(command, peer: f.peer).error == nil)
        let requested = try #require(try await f.store.snapshot().runs.first)
        #expect(requested.loopExitRequest?.invocationID == reviewID)
        #expect(requested.finishRequest == nil)
        #expect(try AgentWorkflowExecution(validating: requested).readyNodeIDs.isEmpty)

        let review = AgentWorkflowResult(invocationID: reviewID, nativeTurnID: "turn-1", text: "VERIFIED_REVIEW", completedAt: .now)
        try await f.store.update(runID: f.run.id) { try $0.succeed(review, instance: f.instance, now: .now) }
        let store: AgentWorkflowStore
        if restart {
            store = AgentWorkflowStore(fileURL: f.directory.appendingPathComponent("ledger.json"), hostID: f.run.definition.hostID)
            let restored = try #require(try await store.snapshot().runs.first)
            #expect(restored.status == .paused && restored.hasExitedLoop)
            #expect(try AgentWorkflowExecution(validating: restored).readyNodeIDs.isEmpty)
            try await store.update(runID: f.run.id) { try $0.resume(instances: [f.instance], now: .now) }
        } else {
            store = f.store
        }
        let result = try await store.update(runID: f.run.id) { execution in
            #expect(execution.readyNodeIDs == [steps[2].id])
            let summary = try execution.prepareInvocation(nodeID: steps[2].id, now: .now)
            #expect(try execution.prepareInvocation(nodeID: steps[2].id, now: .now).id == summary.id)
            #expect(summary.delivery.sources.map(\.resultID) == [review.id])
            #expect(summary.result?.text.contains("VERIFIED_REVIEW") == true)
            #expect(execution.run.status == .running)
            #expect(execution.readyNodeIDs == [steps[3].id])
            _ = try execution.prepareInvocation(nodeID: steps[3].id, now: .now)
        }
        #expect(result.status == .completed && result.round == 1)
        #expect(result.invocations.map(\.nodeID) == [steps[0].id, steps[2].id, steps[3].id])
        #expect(AgentWorkflowRunState(result, currentInstances: [f.instance]).nodes[1].isSkipped)
        #expect(try AgentWorkflowExecution(validating: result).readyNodeIDs.isEmpty)
    }

    @Test
    func noApprovalContinuesRepairAndStillPausesAtRoundLimit() async throws {
        let f = try await fixture(afterLoop: true, maximumRounds: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let repair = f.run.definition.nodes[1]
        let result = try await f.store.update(runID: f.run.id) { execution in
            try execution.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Changes required", completedAt: .now), instance: f.instance, now: .now)
            #expect(execution.readyNodeIDs == [repair.id])
            _ = try execution.prepareInvocation(nodeID: repair.id, now: .now)
        }
        #expect(result.status == .paused)
        #expect(result.loopExitRequest == nil)
        #expect(result.invocations.map(\.nodeID) == [f.invocation.nodeID, repair.id])
    }

    @Test("Approval pause and actionable notification are durable and deduplicated")
    func approvalNotification() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(try await f.store.notificationContext(agentID: f.instance.agentID, runtimeID: "replaced", conversationID: f.instance.conversationID) == nil)
        let context = try #require(await f.store.notificationContext(agentID: f.instance.agentID, runtimeID: f.instance.processRuntimeID, conversationID: f.instance.conversationID))
        let action = NotificationActionContext(sessionId: f.instance.paneID, pluginId: f.instance.pluginID, requestId: "approve", form: .permission(.init(alwaysSuggestionID: nil)))
        #expect(try await f.store.pauseForApproval(context: context, requestID: "approve", body: "Allow Bash?", action: action))
        let first = try #require(await f.store.snapshot().notifications?[f.run.id])
        #expect(first.eventType == "agent.approval")
        #expect(first.agentID == f.instance.agentID && first.action == action)
        #expect(first.title.contains(f.run.definition.name))
        #expect(first.body.contains(context.nodeName) && first.body.contains("Allow Bash?"))
        #expect(try await f.store.snapshot().runs.first?.status == .paused)
        #expect(try await f.store.pauseForApproval(context: context, requestID: "approve", body: "Allow Bash?", action: action))
        #expect(try await f.store.snapshot().notifications?[f.run.id]?.id == first.id)
        let fileURL = await f.store.fileURL
        let reopened = AgentWorkflowStore(fileURL: fileURL, hostID: f.instance.hostID)
        #expect(try await reopened.snapshot().notifications?[f.run.id] == first)
        let run = try #require(await reopened.snapshot().runs.first)
        let status = AgentWorkflowPaneStatus(run: run, hostID: f.instance.hostID, needsAttention: true)
        #expect(status.title == "Needs attention" && status.nodeName == context.nodeName)
        #expect(try JSONDecoder().decode(AgentWorkflowPaneStatus.self, from: JSONEncoder().encode(status)) == status)
        var firstPane = PaneState(paneId: "%1", agentSession: .init(paneId: "%1", state: .working))
        firstPane.workflow = status
        var secondPane = PaneState(paneId: "%2", agentSession: .init(paneId: "%2", state: .working))
        secondPane.workflow = status
        #expect([firstPane, secondPane].pendingAttentionPanes.count == 1)
        secondPane.agentSession?.recordQuestion("native:question")
        let pending = [firstPane, secondPane].pendingAttentionPanes
        #expect(pending.map(\.paneId) == ["%2"])
        let presentations = AgentWorkflowPaneStatus.presentations(runs: [run], hostID: f.instance.hostID, attentionRunIDs: [run.id])
        #expect(presentations[f.instance.workspacePane]?.runID == run.id)
    }

    @Test("An older approval cannot replace a newer operator pause")
    func approvalPreservesOperatorControl() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let context = try #require(await f.store.notificationContext(agentID: f.instance.agentID, runtimeID: f.instance.processRuntimeID, conversationID: f.instance.conversationID))
        _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator pause", operatorInitiated: true) }
        #expect(try await !f.store.pauseForApproval(context: context, requestID: "old", body: "Allow?", action: nil))
        #expect(try await f.store.snapshot().runs.first?.issue == "Operator pause")
        #expect(try await f.store.snapshot().notifications?[f.run.id] == nil)
    }

    @Test("Workflow alerts once and individual stop alerts are opt-in", arguments: [nil, true] as [Bool?])
    func completionNotifications(notifyOnAgentCompletion: Bool?) async throws {
        let completedRuns = LockIsolated([UUID]())
        let onCompleted: @Sendable (AgentWorkflowRun) -> Void = { run in
            completedRuns.withValue { $0.append(run.id) }
        }
        let f = try await fixture(notifyOnAgentCompletion: notifyOnAgentCompletion, onCompleted: onCompleted)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let runner = AgentWorkflowRunner(store: f.store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in }), onFailure: {
            Issue.record(Comment(rawValue: $0))
        })
        let router = AgentWorkflowEventRouter(store: f.store, runner: runner, inspect: { $0 })
        let notices = LockIsolated([String]())
        let states = LockIsolated([AgentState]())
        let dispatcher = PluginEventDispatcher(
            onState: { _, _, state, _, _, _ in states.withValue { $0.append(state) } },
            onNotification: { _, _, notice, _ in notices.withValue { $0.append(notice.title) } },
            onWorkflow: { event, _ in
                guard event.workflow?.kind == .stopCandidate, event.workflow?.nativeTurnID == "turn-1" else { return }
                do {
                    try await f.store.update(runID: f.run.id) {
                        try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Done", completedAt: .now), instance: f.instance, now: .now)
                    }
                } catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
            },
            shouldSuppressAgentCompletion: { event, peer in
                do { return try await router.suppressesAgentCompletion(event, peer: peer) }
                catch {
                    Issue.record(Comment(rawValue: error.localizedDescription))
                    return false
                }
            }
        )
        func event(_ title: String, turn: String, kind: PluginWorkflowEvent.Kind = .stopCandidate) -> PluginEvent {
            .init(
                pluginID: "codex",
                sessionID: f.instance.conversationID,
                state: .doneWorking(summary: nil),
                notification: .init(title: title, body: "Done"),
                tmuxPane: f.instance.paneID,
                workflow: .init(kind: kind, nativeTurnID: turn, transcriptPath: "/fixture/native.jsonl", text: "Done")
            )
        }
        func emptyStop(_ title: String, turn: String, path: String = "/fixture/native.jsonl", reply: String? = "") throws -> PluginEvent {
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Stop", "turn_id": turn,
                "last_assistant_message": reply.map { $0 as Any } ?? NSNull(), "transcript_path": path,
            ])
            let base = PluginEvent(
                pluginID: f.instance.pluginID, sessionID: f.instance.conversationID,
                state: .doneWorking(summary: reply), notification: .init(title: title, body: ""), tmuxPane: f.instance.paneID
            )
            return PluginWorkflowHook.addingEvidence(to: base, from: .init(pluginID: base.pluginID, context: [:], payload: payload), nativeTurnKey: "turn_id")
        }
        #expect(completedRuns.value.isEmpty)
        await dispatcher.dispatch(event("Manual turn", turn: "manual"), ingressPeer: f.peer)
        await dispatcher.dispatch(event("Turn failed", turn: "turn-1", kind: .failed), ingressPeer: f.peer)
        try await dispatcher.dispatch(emptyStop("Other tool-only turn", turn: "manual"), ingressPeer: f.peer)
        try await dispatcher.dispatch(emptyStop("Other transcript", turn: "turn-1", path: "/fixture/other.jsonl"), ingressPeer: f.peer)
        let toolOnly = try emptyStop("Workflow tool-only turn", turn: "turn-1")
        #expect(toolOnly.workflow == nil)
        await dispatcher.dispatch(toolOnly, ingressPeer: f.peer)
        let noReply = try emptyStop("Workflow turn without reply", turn: "turn-1", reply: nil)
        #expect(noReply.workflow == nil)
        await dispatcher.dispatch(noReply, ingressPeer: f.peer)
        #expect(completedRuns.value.isEmpty)
        await dispatcher.dispatch(event("Workflow turn", turn: "turn-1"), ingressPeer: f.peer)
        let unsuppressed = ["Manual turn", "Other tool-only turn", "Other transcript"]
        let workflowNotices = ["Workflow tool-only turn", "Workflow turn without reply", "Workflow turn"]
        #expect(notices.value == unsuppressed + (notifyOnAgentCompletion == true ? workflowNotices : []))
        #expect(states.value.count == 7)
        #expect(states.value[1] == .idle)
        #expect(states.value[4].needsAttention == (notifyOnAgentCompletion == true))
        #expect(completedRuns.value == [f.run.id])

        let sameRun = try await f.store.update(runID: f.run.id) { _ in }
        #expect(sameRun.status == .completed)
        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID, onCompleted: onCompleted)
        let saved = try await reopened.snapshot()
        #expect(saved.runs.first?.definition.notifyOnAgentCompletion == notifyOnAgentCompletion)
        #expect(completedRuns.value == [f.run.id])
    }

    @Test(arguments: [false, true])
    func explicitCompletionRespectsPauseAndFinishEndsTheWholeRun(finishesWorkflow: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator pause") }
        let request = finishesWorkflow ? f.request() : JSONRPCRequest(id: "step", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        try #require(await f.service.handle(request, peer: f.peer).ok)
        let completed = try await f.store.update(runID: f.run.id) {
            try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Done", completedAt: .now), instance: f.instance, now: .now)
        }
        #expect(completed.status == .paused && completed.invocations[0].status == .succeeded)
        let resumed = try await f.store.update(runID: f.run.id) { try $0.resume(instances: [f.instance], now: .now) }
        #expect(resumed.status == .completed)
        #expect((resumed.finishRequest != nil) == finishesWorkflow)
    }

    @Test(arguments: [false, true])
    func explicitCompletionRejectsExpiredEndedOrChangedTurns(ended: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let request = JSONRPCRequest(id: "step", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        let expired = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { _ in }, now: { f.run.authorizationExpiresAt })
        #expect(await expired.handle(request, peer: f.peer).error?.code == "workflow_denied")
        if ended {
            _ = try await f.store.update(runID: f.run.id) { $0.end() }
            #expect(await f.service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        } else {
            _ = try await f.store.update(runID: f.run.id) { try $0.observeStepTurn(invocationID: f.invocation.id, instance: f.instance, turn: .init(id: "next", transcriptPath: "/fixture/native.jsonl", prompt: "Continue")) }
            await #expect(throws: AgentWorkflowError.self) {
                try await f.store.update(runID: f.run.id) { try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn-1", now: .now) }
            }
        }
    }

    @Test
    func acceptedRequestIsDurableIdempotentAndWaitsForFinalAnswer() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.invocation.delivery.input.text.contains("--invocation \(f.invocation.id.uuidString)"))
        let first = await f.service.handle(f.request(), peer: f.peer)
        let repeated = await f.service.handle(f.request(reason: "Must not replace the accepted reason"), peer: f.peer)
        #expect(first.ok && repeated.ok)
        #expect(first.result?["status"] == .string("finishing"))
        let archive = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: f.directory.appendingPathComponent("ledger.json")))
        #expect(archive.runs[0].status == .finishing)
        #expect(archive.runs[0].finishRequest?.reason == "Review passed")
        #expect(archive.runs[0].invocations[0].result == nil)
        let result = AgentWorkflowResult(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Final review", completedAt: Date())
        let done = try await f.store.update(runID: f.run.id) { _ = try $0.succeed(result, instance: f.instance, now: Date()) }
        #expect(done.status == .completed)
    }

    @Test
    func missingEvidenceAndSelfReportedIdentityAreRejected() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(), peer: nil).error?.code == "workflow_denied")
        var params = f.request().params
        params["_peerPID"] = .int(10)
        params["agentId"] = .string(f.instance.id.uuidString)
        let forged = JSONRPCRequest(id: "forged", method: "workflow.finish", params: params)
        #expect(await f.service.handle(forged, peer: f.peer).error?.code == "invalid_params")
        let stranger = try #require(PluginIngressPeer.capture(peerPID: 12, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        #expect(await f.service.handle(f.request(), peer: stranger).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].finishRequest == nil)
    }

    @Test(arguments: [false, true])
    func finishAcrossPermissionPauseWaitsForOperatorWithoutAnotherRound(pauseBeforeRequest: Bool) async throws {
        let f = try await fixture(loop: true, maximumRounds: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if !pauseBeforeRequest {
            try #require(await f.service.handle(f.request(), peer: f.peer).ok)
        }
        _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Permission requires a human response") }
        let response = await f.service.handle(f.request(), peer: f.peer)
        try #require(response.ok)
        #expect(response.result?["status"] == .string("paused"))
        let completed = try await f.store.update(runID: f.run.id) {
            _ = try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Review passed", completedAt: .now), instance: f.instance, now: .now)
        }
        #expect(completed.status == .paused)
        #expect(completed.issue == "Permission requires a human response")
        #expect(completed.finishRequest?.invocationID == f.invocation.id)
        #expect(completed.invocations[0].status == .succeeded)
        #expect(try AgentWorkflowExecution(validating: completed).readyNodeIDs.isEmpty)
        let resumed = try await f.store.update(runID: f.run.id) { try $0.resume(instances: [f.instance], now: .now) }
        #expect(resumed.status == .completed)
        #expect(resumed.round == 1 && resumed.invocations.count == 1)
    }

    @Test
    func ungrantedNodeCannotRequestFinish() async throws {
        let f = try await fixture(allowsFinish: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(!f.invocation.delivery.input.text.contains("ctrlx workflow finish"))
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
    }

    @Test
    func changedConversationAndReusedProcessCannotRequestFinish() async throws {
        let f = try await fixture(inspect: { instance in
            var replacement = instance
            replacement.conversationID = "new-conversation"
            return replacement
        })
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        let reusedPID = try #require(PluginIngressPeer.capture(peerPID: 10, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0)
        })
        #expect(await f.service.handle(f.request(), peer: reusedPID).error?.code == "workflow_denied")
    }

    @Test(arguments: [false, true])
    func expiryAndEndCannotBeUndoneByFinish(paused: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if paused {
            _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Human input") }
        }
        let expired = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { _ in }, now: { f.run.authorizationExpiresAt })
        #expect(await expired.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        _ = try await f.store.update(runID: f.run.id) { $0.end() }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].status == .ended)
    }

    @Test
    func delayedCommandFromPreviousRoundCannotFinishCurrentRound() async throws {
        let f = try await fixture(loop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let next = try await f.store.update(runID: f.run.id) {
            _ = try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Continue", completedAt: Date()), instance: f.instance, now: Date())
            let second = try $0.prepareInvocation(nodeID: f.invocation.nodeID, now: Date())
            try $0.beginWriting(invocationID: second.id, instance: f.instance, now: Date())
            try $0.accept(invocationID: second.id, instance: f.instance, nativeTurnID: "turn-2")
        }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].status == .running)
        let secondID = try #require(next.invocations.last?.id)
        #expect(await f.service.handle(f.request(id: secondID), peer: f.peer).ok)
    }

    @Test(arguments: ["", " \n\t", String(repeating: "界", count: 2_731)])
    func invalidReasonsDoNotChangeRun(_ reason: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(reason: reason), peer: f.peer).error?.code == "invalid_params")
        #expect(try await f.store.snapshot().runs[0].finishRequest == nil)
    }
}
