import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbiterTests {
    @Test(arguments: ["codex", "claude-code"])
    func twentyMessagesUseAgentIdentityWithoutWorkflowOrTaskLifecycle(plugin: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        service.draft.title = "Expert"
        service.draft.goal = "Selected material"
        service.draft.directory = f.root.path
        let id = try await service.create(pluginID: plugin, providerID: "custom")
        service.historyAgentID = id
        #expect(f.writes.isEmpty)
        #expect(service.agents[0].creation?.providerID == "custom")
        for i in 0..<20 {
            service.drafts[id] = "round \(i)"
            try await service.send(id)
            let message = try #require(service.messages.last)
            try await f.complete(message)
            await service.refresh()
        }
        #expect(service.history(service.agents[0]).count == 20 && f.writes.count == 20 && service.agents.count == 1)
        #expect(service.agents[0].id == id)
        #expect(service.agents[0].directory == f.root.path)
        #expect(try !FileManager.default.fileExists(atPath: f.paths.orbiterDirectory(#require(service.agents[0].creation?.id)).appendingPathComponent("TASK.md").path))
        try await f.cleanup()
    }

    @Test
    func moreThanTwoAgentsCanBeCreatedAndAssociatedIndependently() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        for _ in 0..<3 {
            service.draft.title = "Same name"
            service.draft.goal = "Draft only"
            service.draft.directory = f.root.path
            _ = try await service.create(pluginID: "codex", providerID: nil)
        }
        #expect(service.agents.count == 3 && Set(service.agents.map(\.agentID)).count == 3)
        #expect(f.writes.isEmpty)
        let reopened = await f.orbiters()
        #expect(reopened.agents.count == 3 && f.launches.count == 3)
        try await f.cleanup()
    }

    @Test
    func workflowOccupancyDoesNotEndOrArchiveTheAgent() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        service.draft.title = "Expert"
        service.draft.goal = "hello"
        service.draft.directory = f.root.path
        let id = try await service.create(pluginID: "codex", providerID: nil)
        f.workflowOccupied = true
        await #expect(throws: AgentWorkflowError.self) { try await service.send(id) }
        #expect(f.writes.isEmpty && service.drafts[id] == "hello")
        f.workflowOccupied = false
        try await service.send(id)
        try await f.complete(#require(service.messages.last))
        await service.refresh()
        #expect(service.availability(service.agents[0]) == nil)
        try await f.cleanup()
    }

    @Test
    func ordinaryConversationContinuesAcrossSingleAndMultiAgentWorkflows() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        for title in ["Expert", "Reviewer"] {
            service.draft.title = title
            service.draft.goal = "hello"
            service.draft.directory = f.root.path
            _ = try await service.create(pluginID: "codex", providerID: nil)
        }
        let id = try #require(service.agents.first?.id)
        service.historyAgentID = id
        let store = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("workflow.json"), hostID: f.hostID)
        f.workflowStore = store
        let instances = try await store.reconcile(f.observations)
        let delivery = AgentWorkflowTerminalTransport(store: store, gate: f.gate, temporaryDirectory: f.root.appendingPathComponent("workflow-input"), inspect: { $0 }, checkInputOwner: { agentID in
            if try await f.interaction.store.pending().contains(where: { $0.agentID == agentID }) {
                throw AgentWorkflowError("Ordinary message pending")
            }
        }, submit: { _, _, _, authorize, _ in try authorize { } }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let runner = AgentWorkflowRunner(store: store, transport: delivery.transport, onFailure: { Issue.record(Comment(rawValue: $0)) })
        for size in 1...2 {
            service.drafts[id] = "before workflow \(size)"
            try await service.send(id)
            try await f.complete(#require(service.messages.last))
            await service.refresh()
            let nodes = instances.prefix(size).map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
            let edges: [AgentWorkflowEdge] = size == 1 ? [] : [.init(source: nodes[0].id, target: nodes[1].id)]
            let definition = try await store.saveDefinition(.init(name: "Explicit workflow", hostID: f.hostID, nodes: nodes, edges: edges, entryNodeID: nodes[0].id), expectedRevision: nil)
            let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(300))
            service.drafts[id] = "after workflow \(size)"
            await #expect(throws: AgentWorkflowError.self) { try await service.send(id) }
            await runner.schedule(runID: run.id)
            for node in nodes {
                var pending: AgentWorkflowInvocation?
                for _ in 0..<1_000 {
                    pending = try await store.snapshot().runs.first { $0.id == run.id }?.invocations.first { $0.nodeID == node.id && $0.status == .awaitingAcceptance }
                    if pending != nil {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let invocation = try #require(pending)
                let instance = try #require(invocation.instance)
                let turn = UUID().uuidString
                try await runner.accepted(runID: run.id, invocationID: invocation.id, instance: instance, nativeTurnID: turn)
                try await runner.succeeded(runID: run.id, result: .init(invocationID: invocation.id, nativeTurnID: turn, text: "Verified workflow reply", completedAt: Date()), instance: instance)
            }
            for _ in 0..<1_000 {
                if try await store.snapshot().runs.first(where: { $0.id == run.id })?.status.isTerminal == true {
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(try await store.snapshot().runs.first { $0.id == run.id }?.status == .completed)
            try await service.send(id)
            try await f.complete(#require(service.messages.last))
            await service.refresh()
            #expect(service.agents.count == 2 && service.agents[0].id == id)
        }
        #expect(try await store.snapshot().runs.count == 2)
        #expect(service.history(service.agents[0]).count == 4)
        await runner.shutdown()
        try await f.cleanup()
    }

    @Test
    func lostCreationReplyReconcilesTheSameAgentAndKeepsDraft() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        service.draft.title = "Expert"
        service.draft.goal = "hello"
        service.draft.directory = f.root.path
        f.lostCreateReply = true
        await #expect(throws: AgentWorkflowError.self) { try await service.create(pluginID: "codex", providerID: nil) }
        await service.refresh()
        #expect(service.agents.count == 1 && service.agents[0].agentID != nil)
        #expect(service.drafts[service.agents[0].id] == "hello")
        await #expect(throws: AgentWorkflowError.self) { try await service.create(pluginID: "codex", providerID: nil) }
        #expect(f.launches.count == 1 && f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func forkRetainsVerifiedSourceAndNativeProviderChoice() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let service = await f.orbiters(source: main.instance)
        service.draft.title = "Expert"
        service.draft.goal = "hello"
        service.draft.directory = f.root.path
        _ = try await service.create(pluginID: "codex", providerID: "other", fork: true)
        #expect(service.agents[0].sourceAgentID == main.instance?.agentID)
        #expect(service.agents[0].creation?.providerID == "other")
        #expect(service.agents[0].creation?.forkSource?.conversationID == main.instance?.conversationID)
        try await f.cleanup()
    }

    @Test
    func newDraftWhileSendingDoesNotGetCleared() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbiters()
        service.draft.title = "Expert"
        service.draft.goal = "old"
        service.draft.directory = f.root.path
        let id = try await service.create(pluginID: "codex", providerID: nil)
        f.beforeWrite = { service.drafts[id] = "new" }
        try await service.send(id)
        #expect(service.drafts[id] == "new")
        #expect(service.messages.last?.text == "old")
        try await f.cleanup()
    }
}
