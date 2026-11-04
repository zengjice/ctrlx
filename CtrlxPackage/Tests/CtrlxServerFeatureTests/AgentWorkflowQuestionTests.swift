import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowQuestionTests {
    private struct Fixture {
        let root: URL
        let store: AgentWorkflowStore
        let runner: AgentWorkflowRunner
        let router: AgentWorkflowEventRouter
        let run: AgentWorkflowRun
        let invocation: AgentWorkflowInvocation
        let instances: [AgentWorkflowInstance]
        let next: AgentWorkflowNode
        let parallel: AgentWorkflowNode
        let peer: PluginIngressPeer
    }

    private func fixture(plugin: String = "codex") async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-question-\(UUID())")
        let hostID = UUID(), store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let instances = try await store.reconcile((0..<2).map { index in
            .init(
                pluginID: plugin,
                processID: Int32(10 + index),
                processRuntimeID: "501:\(10 + index):100:0",
                workspacePane: .init(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)",
                conversationID: "conversation-\(index)",
                displayName: "Agent \(index)",
                workingDirectory: root.path,
                capabilities: .init(maximumInputBytes: 100_000),
                readiness: .ready
            )
        })
        let entry = AgentWorkflowNode(name: "Start", content: .init(text: "Task"))
        let asking = AgentWorkflowNode(name: "Asking", agentInstanceID: instances[0].id)
        let parallel = AgentWorkflowNode(name: "Parallel", agentInstanceID: instances[1].id)
        let next = AgentWorkflowNode(name: "Next", agentInstanceID: instances[0].id)
        let definition = try await store.saveDefinition(.init(
            name: "Question fixture", hostID: hostID, nodes: [entry, asking, parallel, next],
            edges: [.init(source: entry.id, target: asking.id), .init(source: entry.id, target: parallel.id), .init(source: asking.id, target: next.id)],
            entryNodeID: entry.id
        ), expectedRevision: nil)
        let started = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        let run = try await store.update(runID: started.id) {
            _ = try $0.prepareInvocation(nodeID: entry.id, now: Date())
            let invocation = try $0.prepareInvocation(nodeID: asking.id, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: instances[0], now: Date())
            try $0.didWrite(invocationID: invocation.id)
            try $0.accept(invocationID: invocation.id, instance: instances[0], nativeTurnID: "turn", transcriptPath: "/private/native.jsonl")
        }
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("This fixture advances tasks explicitly.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 })
        let peer = try #require(PluginIngressPeer.capture(peerPID: 10, userID: 501) { pid in
            pid == 10 ? .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0) : nil
        })
        return try .init(
            root: root,
            store: store,
            runner: runner,
            router: router,
            run: run,
            invocation: #require(run.invocations.first { $0.nodeID == asking.id }),
            instances: instances,
            next: next,
            parallel: parallel,
            peer: peer
        )
    }

    private func question(_ variant: String) async throws -> PluginEvent {
        let claude = variant == "claude-code"
        let asyncQuestion = variant == "codex-async"
        let payload: [String: Any] = [
            "hook_event_name": claude ? "PermissionRequest" : "PreToolUse", "session_id": "conversation-0",
            "tool_name": claude ? "AskUserQuestion" : (asyncQuestion ? "request_user_input_async" : "request_user_input"),
            "tool_use_id": "question-call", "cwd": "/private/fixture",
            "tool_input": ["questions": [[
                asyncQuestion ? "title" : "question": "Which approach?", "header": "Approach", "multiSelect": false,
                "options": [["label": "Simple", "description": "Use the existing path"], ["label": "New", "description": "Start again"]],
            ]]],
        ]
        let frame = try IngressFrame(pluginID: claude ? "claude-code" : "codex", context: [
            "TMUX_PANE": "%0", "CTRLX_WORKFLOW_VERSION": "1", "CTRLX_INGRESS_ACK": "1",
        ], payload: JSONSerialization.data(withJSONObject: payload))
        if claude {
            return try #require(await ClaudeCodePluginCore().handleIngress(frame))
        }
        return try #require(await CodexPluginCore().handleIngress(frame))
    }

    @Test(arguments: ["claude-code", "codex", "codex-async"])
    func nativeQuestionOpensOnlyItsTaskWithoutPausing(variant: String) async throws {
        let f = try await fixture(plugin: variant == "claude-code" ? variant : "codex")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.agentWorkflowStore = f.store
            let notifications = LockIsolated<[NotificationSpec]>([])
            let dispatcher = PluginEventDispatcher(onState: { _, _, state, pane, _, _ in
                await coordinator.handleAgentWorkflowState(state, paneID: pane)
            }, onNotification: { _, _, notice, _ in
                notifications.withValue { $0.append(notice) }
            }, onWorkflow: { event, peer in
                do { _ = try await f.router.receive(event, peer: peer) }
                catch { Issue.record(error) }
            })
            let gate = AgentWorkflowInputGate { try await f.store.authorizeHumanInput(paneID: $0) }
            await #expect(throws: AgentWorkflowInputReadOnlyError.self) {
                try await gate.human(paneID: "%0") { _ in Issue.record("Input was opened before a question.") }
            }
            let event = try await question(variant)
            await dispatcher.dispatch(event, ingressPeer: f.peer)
            #expect(try notifications.value == [#require(event.notification)])
            #expect(try await f.store.snapshot().runs[0].status == .running)
            let permit = try await gate.human(paneID: "%0") { try #require($0) }
            await #expect(throws: AgentWorkflowInputReadOnlyError.self) { try await f.store.authorizeHumanInput(paneID: "%1") }

            // Working does not mean an asynchronous question has been answered.
            await dispatcher.dispatch(.init(pluginID: event.pluginID, sessionID: event.sessionID, state: .working, tmuxPane: "%0"))
            for readiness in [AgentWorkflowReadiness.awaitingHuman, .draft, .busy, .ready] {
                var observations = f.instances.map(AgentWorkflowObservation.init)
                observations[0].readiness = readiness
                let scan = observations
                let monitor = AgentWorkflowService(store: f.store, scan: { _ in scan }, schedule: { _ in Issue.record("Monitoring must not submit input.") })
                try await monitor.checkActiveRuns(completionGrace: 0)
                #expect(try await f.store.snapshot().runs[0].status == .running)
                try permit.validate()
            }
            let answer = PluginEvent(pluginID: event.pluginID, sessionID: event.sessionID, tmuxPane: "%0", workflow: .init(
                kind: .submitted, nativeTurnID: "turn", transcriptPath: "/private/native.jsonl", text: "Use the simple approach."
            ))
            _ = try await f.router.receive(answer, peer: f.peer)
            let afterAnswer = try await f.store.snapshot().runs[0]
            #expect(afterAnswer.status == .running)
            #expect(afterAnswer.invocations.first { $0.id == f.invocation.id }?.delivery == f.invocation.delivery)

            // Other branches can still start while the question's task runs.
            try await f.store.update(runID: f.run.id) {
                let parallel = try $0.prepareInvocation(nodeID: f.parallel.id, now: Date())
                try $0.beginWriting(invocationID: parallel.id, instance: f.instances[1], now: Date())
            }
            try permit.validate()
            try await f.store.update(runID: f.run.id) {
                try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn", text: "Done", completedAt: Date()), instance: f.instances[0], now: Date())
            }
            #expect(throws: AgentWorkflowInputReadOnlyError.self) { try permit.validate() }
            await #expect(throws: AgentWorkflowInputReadOnlyError.self) { try await f.store.authorizeHumanInput(paneID: "%0") }
            let next = try await f.store.update(runID: f.run.id) {
                let call = try $0.prepareInvocation(nodeID: f.next.id, now: Date())
                try $0.beginWriting(invocationID: call.id, instance: f.instances[0], now: Date())
            }
            #expect(next.status == .running)
            #expect(next.invocations.last?.allowsQuestionInput == nil)
            #expect(notifications.value.count == 1)
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["no-question", "wrong-session", "wrong-peer", "wrong-pane", "wrong-plugin"])
    func unrelatedEventsCannotOpenInput(scenario: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let event = PluginEvent(
            pluginID: scenario == "wrong-plugin" ? "claude-code" : "codex",
            sessionID: scenario == "wrong-session" ? "another" : "conversation-0",
            notification: .init(title: "Notice", body: "Notice", isQuestion: scenario != "no-question"),
            tmuxPane: scenario == "wrong-pane" ? "%1" : "%0"
        )
        let wrongPeer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0) : nil
        })
        _ = try await f.router.receive(event, peer: scenario == "wrong-peer" ? wrongPeer : f.peer)
        #expect(try await f.store.snapshot().runs[0] == f.run)
        await #expect(throws: AgentWorkflowInputReadOnlyError.self) { try await f.store.authorizeHumanInput(paneID: "%0") }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func approvalsStillPauseAndNewNativeTurnsDoNotReplaceTheTask() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.router.receive(question("codex-async"), peer: f.peer)
        let unrelated = PluginEvent(pluginID: "codex", sessionID: "conversation-0", tmuxPane: "%0", workflow: .init(
            kind: .submitted, nativeTurnID: "another-turn", transcriptPath: "/private/native.jsonl", text: "Another task"
        ))
        _ = try await f.router.receive(unrelated, peer: f.peer)
        #expect(try await f.store.snapshot().runs[0].status == .paused)
        #expect(try await f.store.snapshot().runs[0].invocations == f.run.invocations.map { call in
            var call = call
            if call.id == f.invocation.id {
                call.allowsQuestionInput = true
            }
            return call
        })
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.agentWorkflowStore = f.store
            try await f.store.update(runID: f.run.id) { try $0.resume(instances: f.instances, now: Date()) }
            await coordinator.handleAgentWorkflowState(.awaitingPermission(.init(title: "Permission", description: "Confirm"), requestID: "permission"), paneID: "%0")
            #expect(try await f.store.snapshot().runs[0].status == .paused)
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func endingRevokesQueuedQuestionInputAndOlderRecordsDefaultToReadOnly() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.router.receive(question("codex"), peer: f.peer)
        let permission = try await f.store.authorizeHumanInput(paneID: "%0")
        let granted = try #require(await f.store.snapshot().runs[0].invocations.first { $0.id == f.invocation.id })
        let data = try JSONEncoder().encode(granted)
        #expect(try JSONDecoder().decode(AgentWorkflowInvocation.self, from: data).allowsQuestionInput == true)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "allowsQuestionInput")
        #expect(try JSONDecoder().decode(AgentWorkflowInvocation.self, from: JSONSerialization.data(withJSONObject: legacy)).allowsQuestionInput == nil)
        try await f.store.update(runID: f.run.id) { $0.end() }
        #expect(throws: AgentWorkflowInputReadOnlyError.self) { try permission.validate() }
        // Ending releases the terminal normally, but cannot revive an old reply.
        let ordinaryInput = try await f.store.authorizeHumanInput(paneID: "%0")
        try ordinaryInput.validate()
        #expect(ordinaryInput !== permission)
        await f.router.shutdown()
        await f.runner.shutdown()
    }
}
