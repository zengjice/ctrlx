import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowModelExecutionTests {
    @Test
    func oneAgentUsesEachStepSelectionAndKeepsTheLastSelectionForAnUnconfiguredStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let instances = try await store.reconcile([.init(pluginID: "codex", processID: 42, processRuntimeID: "42:1", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%1", conversationID: "conversation", displayName: "Developer", workingDirectory: root.path, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)])
        let instance = try #require(instances.first)
        let low = AgentModelSelection(model: "fast", effort: "low")
        let high = AgentModelSelection(model: "strong", effort: "high")
        let nodes = [
            AgentWorkflowNode(name: "Develop", agentInstanceID: instance.id, modelSelection: low),
            AgentWorkflowNode(name: "Judge", agentInstanceID: instance.id, modelSelection: high),
            AgentWorkflowNode(name: "Continue", agentInstanceID: instance.id),
        ]
        let definition = try await store.saveDefinition(.init(name: "One Agent", hostID: hostID, nodes: nodes, edges: [.init(source: nodes[0].id, target: nodes[1].id), .init(source: nodes[1].id, target: nodes[2].id)], entryNodeID: nodes[0].id), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: .distantFuture)
        // Editing a saved configuration never mutates an in-flight snapshot.
        var edited = definition
        edited.nodes[0].modelSelection = high
        _ = try await store.saveDefinition(edited, expectedRevision: definition.revision)
        let current = LockIsolated(AgentModelSelection(model: "original", effort: "medium"))
        var configurations: [AgentModelSelection] = []
        let tasks = LockIsolated<[AgentModelSelection]>([])
        let delivery = AgentWorkflowTerminalTransport(store: store, gate: .init(), temporaryDirectory: root.appendingPathComponent("input"), inspect: { $0 }, configureModel: { _, selection, input in
            try input.authorization.performConfiguration { current.setValue(selection)
                configurations.append(selection)
            }
        }, submit: { _, _, _, write, _ in
            try write { tasks.withValue { $0.append(current.value) } }
        }, onFailure: { Issue.record("\($0)") })
        for node in nodes {
            let prepared = try await store.update(runID: run.id) { _ = try $0.prepareInvocation(nodeID: node.id, now: Date()) }
            let invocation = try #require(prepared.invocations.first { $0.nodeID == node.id })
            try await delivery.transport.prepare(invocation, instance)
            _ = try await store.update(runID: run.id) { try $0.beginWriting(invocationID: invocation.id, instance: instance, now: Date()) }
            try await delivery.transport.write(invocation, instance)
            await delivery.transport.discard(invocation.id)
            _ = try await store.update(runID: run.id) {
                try $0.didWrite(invocationID: invocation.id)
                try $0.accept(invocationID: invocation.id, instance: instance, nativeTurnID: invocation.id.uuidString)
                try $0.succeed(.init(invocationID: invocation.id, nativeTurnID: invocation.id.uuidString, text: "Done", completedAt: Date()), instance: instance, now: Date())
            }
        }
        #expect(configurations == [low, high])
        #expect(tasks.value == [low, high, high])
        #expect(current.value == high)
        #expect(try await store.snapshot().runs.first?.status == .completed)
    }

    @Test
    func catalogRequestsStayReadOnlyAndRequireTheCurrentHostProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let instances = try await store.reconcile([.init(pluginID: "codex", processID: 42, processRuntimeID: "42:1", workspacePane: .init(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%1", conversationID: "conversation", displayName: "Agent", workingDirectory: root.path, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)])
        let instance = try #require(instances.first)
        let expected = AgentModelSnapshot(runtimeID: instance.processRuntimeID, models: [.init(id: "model", name: "Model", efforts: ["high"], defaultEffort: "high")], selection: .init(model: "model", effort: "high"), unavailableReason: nil)
        let service = AgentWorkflowService(store: store, scan: { _ in [] }, schedule: { _ in Issue.record("Catalog read scheduled execution") }, models: { current, refresh in
            #expect(current == instance && refresh)
            return expected
        })
        #expect(try await service.handle(.init(.models(instanceID: instance.id, refresh: true), expectedHostID: hostID)).modelSnapshot == expected)
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(.models(instanceID: instance.id, refresh: true), expectedHostID: UUID())) }
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(.models(instanceID: UUID(), refresh: true), expectedHostID: hostID)) }
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(.catalog(offset: 0), version: 5)) }
        #expect(try await store.snapshot().runs.isEmpty)
    }

    @Test
    func versionFiveDefinitionsMigrateWithNoModelOverride() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-v5-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("ledger.json")
        let hostID = UUID()
        let node = AgentWorkflowNode(name: "Agent", agentInstanceID: UUID())
        let definition = AgentWorkflowDefinition(name: "Legacy", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
        let archive = AgentWorkflowArchive(schemaVersion: 5, hostID: hostID, definitions: [definition])
        try JSONEncoder().encode(archive).write(to: file)
        let restored = try await AgentWorkflowStore(fileURL: file, hostID: hostID).snapshot()
        #expect(restored.schemaVersion == 7)
        #expect(restored.definitions == [definition])
        #expect(restored.definitions.first?.nodes.first?.modelSelection == nil)
    }
}
