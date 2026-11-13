import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowTargetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private actor Writes {
        var values: [AgentWorkflowInvocation] = []
        func record(_ invocation: AgentWorkflowInvocation) {
            values.append(invocation)
        }
    }

    private func fixture() throws -> AgentWorkflowExecution {
        let host = UUID()
        let agents = ["Developer", "Reviewer"].enumerated().map { index, name in
            AgentWorkflowInstance(
                hostID: host, pluginID: "codex", processID: Int32(100 + index), processRuntimeID: "start-\(index)",
                workspacePane: .init(serverID: "old-server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)", conversationID: UUID().uuidString, displayName: name, workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
            )
        }
        let nodes = agents.map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let definition = AgentWorkflowDefinition(
            name: "Review",
            hostID: host,
            nodes: nodes,
            edges: [.init(source: nodes[0].id, target: nodes[1].id)],
            entryNodeID: nodes[0].id
        )
        return try .init(definition: definition, instances: agents, now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
    }

    private func restarted(_ old: AgentWorkflowInstance) -> AgentWorkflowInstance {
        var pane = old.workspacePane
        pane.serverID = "new-server"
        return .init(
            hostID: old.hostID,
            pluginID: old.pluginID,
            processID: old.processID + 200,
            processRuntimeID: "new-\(old.processID)",
            workspacePane: pane,
            paneID: "%\(old.processID)",
            conversationID: UUID().uuidString,
            displayName: old.displayName,
            workingDirectory: old.workingDirectory,
            capabilities: old.capabilities,
            readiness: .ready
        )
    }

    private func accept(_ index: Int, execution: inout AgentWorkflowExecution) throws -> AgentWorkflowInvocation {
        let invocation = try execution.prepareInvocation(nodeID: execution.run.definition.nodes[index].id, now: now)
        let agent = try #require(invocation.instance)
        try execution.beginWriting(invocationID: invocation.id, instance: agent, now: now)
        try execution.didWrite(invocationID: invocation.id)
        try execution.accept(invocationID: invocation.id, instance: agent, nativeTurnID: invocation.id.uuidString, transcriptPath: "/fixture/turn.jsonl")
        return invocation
    }

    @Test(arguments: ["codex", "claude-code"])
    func restartThenRetryPreservesResultsAndRejectsOldTurns(pluginID: String) throws {
        var base = try fixture().run
        base.instances = base.instances.map { old in
            .init(
                id: old.id,
                hostID: old.hostID,
                pluginID: pluginID,
                processID: old.processID,
                processRuntimeID: old.processRuntimeID,
                workspacePane: old.workspacePane,
                paneID: old.paneID,
                conversationID: old.conversationID,
                displayName: old.displayName,
                workingDirectory: old.workingDirectory,
                capabilities: old.capabilities,
                readiness: .ready
            )
        }
        var execution = try AgentWorkflowExecution(validating: base)
        let development = try accept(0, execution: &execution)
        try execution.succeed(
            .init(invocationID: development.id, nativeTurnID: development.id.uuidString, text: "Implemented", completedAt: now),
            instance: #require(development.instance),
            now: now
        )
        let review = try accept(1, execution: &execution)
        try execution.fail(invocationID: review.id, instance: #require(review.instance), nativeTurnID: review.id.uuidString, reason: "Quota exceeded")
        let original = execution.run
        let live = original.instances.map(restarted)
        execution = try AgentWorkflowExecution(restoring: original)
        try execution.resume(instances: live, now: now)
        #expect(execution.readyNodeIDs == [review.nodeID])
        let retry = try accept(1, execution: &execution)
        #expect(retry.id != review.id && retry.delivery.id != review.delivery.id)
        #expect(retry.instance == live[1])
        #expect(retry.delivery.sources == review.delivery.sources)
        #expect(retry.delivery.input.text.contains(retry.id.uuidString))
        #expect(!retry.delivery.input.text.contains(review.id.uuidString))
        #expect(execution.run.invocations[0] == original.invocations[0])
        #expect(execution.run.invocations[1] == original.invocations[1])
        let before = execution.run
        #expect(throws: AgentWorkflowError.self) {
            try execution.succeed(.init(invocationID: retry.id, nativeTurnID: review.id.uuidString, text: "Stale", completedAt: now), instance: live[1], now: now)
        }
        #expect(throws: AgentWorkflowError.self) {
            try execution.accept(invocationID: retry.id, instance: #require(review.instance), nativeTurnID: retry.id.uuidString)
        }
        #expect(execution.run == before)
        try execution.succeed(.init(invocationID: retry.id, nativeTurnID: retry.id.uuidString, text: "Reviewed", completedAt: now), instance: live[1], now: now)
        #expect(execution.run.status == .completed)
        let restored = try AgentWorkflowExecution(validating: JSONDecoder().decode(AgentWorkflowRun.self, from: JSONEncoder().encode(execution.run)))
        #expect(restored.run == execution.run)
        let state = AgentWorkflowRunState(restored.run, currentInstances: live)
        #expect(state.nodes[1].invocation?.id == retry.id)
        #expect(state.nodes[0].instance?.id == live[0].id)
    }

    @Test(arguments: ["host", "window", "pane"])
    func reusedRuntimeIDAndNameDoNotReplaceTarget(component: String) throws {
        var execution = try fixture()
        execution.pause(reason: "Operator")
        let old = execution.run.instances[0]
        var pane = old.workspacePane
        if component == "window" {
            pane.windowID = UUID()
        }
        if component == "pane" {
            pane.paneID = UUID()
        }
        let replacement = AgentWorkflowInstance(
            id: old.id, hostID: component == "host" ? UUID() : old.hostID, pluginID: old.pluginID,
            processID: old.processID, processRuntimeID: old.processRuntimeID, workspacePane: pane,
            paneID: old.paneID, conversationID: old.conversationID, displayName: old.displayName,
            workingDirectory: old.workingDirectory, capabilities: old.capabilities, readiness: .ready
        )
        let before = execution.run
        try execution.resume(instances: [replacement, before.instances[1]], now: now)
        #expect(execution.run.instances[0].target == old.target)
        #expect(execution.run.instances[0].readiness == .unavailable)
        #expect(throws: AgentWorkflowStartRejection.self) {
            try AgentWorkflowExecution(definition: before.definition, instances: [replacement, before.instances[1]], now: now, authorizationExpiresAt: before.authorizationExpiresAt)
        }
        #expect(execution.run.issue?.contains("Waiting for Agent") == true)
    }

    @Test
    func pendingInputRebindsWhileAcceptedReceiptStaysCorrelated() throws {
        var execution = try fixture()
        let pending = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        execution.pause(reason: "Operator")
        let live = execution.run.instances.map(restarted)
        try execution.resume(instances: live, now: now)
        #expect(execution.run.invocations[0].id == pending.id)
        #expect(execution.run.invocations[0].instance == live[0])
        #expect(execution.run.invocations[0].delivery.toAgentID == live[0].id)
        _ = try accept(0, execution: &execution)
        execution.pause(reason: "Operator")
        let before = execution.run
        try execution.resume(instances: live.map(restarted), now: now)
        #expect(execution.run.status == .running)
        #expect(execution.run.invocations == before.invocations)
        #expect(execution.readyNodeIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func waitingDeliveryUsesRecoveredTabExactlyOnce(operatorPaused: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-wait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try fixture().run
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: base.definition.hostID)
        let catalog = try await store.reconcile(base.instances.map(AgentWorkflowObservation.init))
        let definition = try await store.saveDefinition(base.definition.resolvingAgents(in: catalog), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        _ = try await store.reconcile([])
        let writes = Writes()
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { invocation, _ in
            await writes.record(invocation)
        }), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await runner.schedule(runID: run.id)
        for _ in 0..<200 {
            if try await !store.snapshot().runs[0].invocations.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await writes.values.isEmpty)
        let waiting = try await store.snapshot().runs[0]
        #expect(waiting.status == .running && waiting.invocations.first?.status == .pending)
        if operatorPaused {
            _ = try await store.update(runID: run.id) { $0.pause(reason: "Operator") }
        }
        let live = catalog.map(restarted)
        let service = AgentWorkflowService(store: store, scan: { _ in live.map(AgentWorkflowObservation.init) }, schedule: {
            await runner.schedule(runID: $0)
        }, now: { now })
        // A Viewer refresh may observe recovery before the monitoring tick.
        _ = try await service.snapshot(refreshInstances: true)
        try await service.checkActiveRuns()
        if operatorPaused {
            #expect(try await store.snapshot().runs[0].status == .paused)
            #expect(await writes.values.isEmpty)
            let paused = try await store.snapshot().runs[0]
            _ = try await service.resume(runID: run.id, expectedRevision: paused.revision)
        }
        for _ in 0..<200 {
            if await !writes.values.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await service.checkActiveRuns()
        let delivered = await writes.values
        #expect(delivered.count == 1)
        #expect(delivered.first?.id == waiting.invocations.first?.id)
        #expect(delivered.first?.instance?.target == live[0].target)
        #expect(delivered.first?.instance?.processID == live[0].processID)
        await service.shutdown()
        await runner.shutdown()
    }

    @Test
    func savedConfigurationAndReservationSurviveCatalogReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try fixture().run
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: base.definition.hostID)
        let catalog = try await store.reconcile(base.instances.map(AgentWorkflowObservation.init))
        var definition = base.definition
        for index in definition.nodes.indices {
            definition.nodes[index].agentInstanceID = catalog[index].id
        }
        definition.agentTargets = nil
        let saved = try await store.saveDefinition(definition, expectedRevision: nil)
        let run = try await store.start(definitionID: saved.id, expectedRevision: saved.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        try await store.update(runID: run.id) { $0.pause(reason: "Operator") }
        let live = try await store.reconcile(catalog.map(restarted).map(AgentWorkflowObservation.init))
        #expect(live.map(\.id) != catalog.map(\.id))
        #expect(saved.resolvingAgents(in: live).agentInstanceIDs == Set(live.map(\.id)))
        await #expect(throws: AgentWorkflowStartRejection.self) {
            try await store.start(definitionID: saved.id, expectedRevision: saved.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        }
        try await store.update(runID: run.id) { $0.end() }
        let next = try await store.start(definitionID: saved.id, expectedRevision: saved.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        #expect(next.instances == live)
        #expect(next.definition.agentInstanceIDs == Set(live.map(\.id)))
    }

    @Test
    func legacyFailedRunMigratesAndContinueDeliversOnlyReviewOnce() async throws {
        var execution = try fixture()
        let development = try accept(0, execution: &execution)
        try execution.succeed(
            .init(invocationID: development.id, nativeTurnID: development.id.uuidString, text: "Keep development", completedAt: now),
            instance: #require(development.instance),
            now: now
        )
        let review = try accept(1, execution: &execution)
        try execution.fail(invocationID: review.id, instance: #require(review.instance), nativeTurnID: review.id.uuidString, reason: "Quota exceeded")
        var legacy = execution.run
        legacy.definition.agentTargets = nil
        for index in legacy.invocations.indices {
            legacy.invocations[index].instance = nil
        }
        let live = legacy.instances.map(restarted)
        let host = legacy.definition.hostID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-target-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        let saved = AgentWorkflowArchive(schemaVersion: 6, hostID: host, definitions: [legacy.definition], instances: live, runs: [legacy])
        try JSONEncoder().encode(saved).write(to: file)
        let store = AgentWorkflowStore(fileURL: file, hostID: host)
        let restored = try await store.snapshot()
        #expect(restored.schemaVersion == 7)
        let reviewAgentID = try #require(legacy.definition.nodes[1].agentInstanceID)
        #expect(restored.definitions[0].agentTargets?[reviewAgentID] == live[1].target)
        #expect(try restored.runs[0].invocations[1].instance?.matchesBinding(#require(review.instance)) == true)
        let writes = Writes()
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { invocation, _ in
            await writes.record(invocation)
        }), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let service = AgentWorkflowService(
            store: store,
            scan: { _ in live.map(AgentWorkflowObservation.init) },
            schedule: { await runner.schedule(runID: $0) },
            now: { now }
        )
        do {
            let operation = ManageAgentWorkflows.Operation.resume(legacy.id, expectedRevision: restored.runs[0].revision, roundLimit: nil)
            await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(operation, expectedHostID: host, version: 6)) }
            let response = try await service.handle(.init(operation, expectedHostID: host))
            #expect(response.run?.summary.status == .running)
            for _ in 0..<500 {
                if await !writes.values.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let retry = try #require(await writes.values.first)
            #expect(retry.nodeID == review.nodeID && retry.id != review.id)
            #expect(retry.instance?.target == live[1].target)
            await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(operation, expectedHostID: host)) }
            try await runner.accepted(runID: legacy.id, invocationID: retry.id, instance: #require(retry.instance), nativeTurnID: "retry-turn")
            try await runner.succeeded(runID: legacy.id, result: .init(invocationID: retry.id, nativeTurnID: "retry-turn", text: "Reviewed", completedAt: now), instance: #require(retry.instance))
            #expect(await writes.values.count == 1)
            let completed = try await store.snapshot().runs[0]
            #expect(completed.status == .completed)
            #expect(completed.invocations[0].result?.text == "Keep development")
            #expect(completed.invocations[1].status == .failed && completed.invocations[2].status == .succeeded)
            #expect(completed.invocations[1].issue == "Quota exceeded")
        } catch {
            await runner.shutdown()
            throw error
        }
        await runner.shutdown()
    }
}
