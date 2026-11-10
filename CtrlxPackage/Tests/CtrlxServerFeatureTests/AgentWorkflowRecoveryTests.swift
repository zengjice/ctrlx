import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func archive(completed: Bool) throws -> AgentWorkflowArchive {
        let hostID = UUID()
        let agent = AgentWorkflowInstance(
            hostID: hostID, pluginID: "codex", processID: 42, processRuntimeID: "runtime",
            workspacePane: .init(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Developer", workingDirectory: "/fixture",
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )
        let brief = AgentWorkflowNode(name: "Brief", content: .init(text: "Task", attachmentIDs: [UUID()]))
        let developer = AgentWorkflowNode(name: "Developer", agentInstanceID: agent.id)
        let after = AgentWorkflowNode(name: "After", content: .init(text: "Next"))
        let definition = AgentWorkflowDefinition(
            name: "Recovery", hostID: hostID, nodes: [brief, developer, after],
            edges: [.init(source: brief.id, target: developer.id), .init(source: developer.id, target: after.id)],
            entryNodeID: brief.id
        )
        var execution = try AgentWorkflowExecution(
            definition: definition, instances: [agent], now: now, authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
        _ = try execution.prepareInvocation(nodeID: brief.id, now: now)
        let invocation = try execution.prepareInvocation(nodeID: developer.id, now: now)
        try execution.beginWriting(invocationID: invocation.id, instance: agent, now: now)
        try execution.didWrite(invocationID: invocation.id)
        try execution.accept(invocationID: invocation.id, instance: agent, nativeTurnID: "native-turn")
        try execution.succeed(
            .init(invocationID: invocation.id, nativeTurnID: "native-turn", text: "Answer", completedAt: now),
            instance: agent, now: now
        )
        if completed {
            _ = try execution.prepareInvocation(nodeID: after.id, now: now)
        }
        var run = execution.run
        let result = try #require(run.invocations[1].result)
        run.invocations[1].result = .init(
            id: result.id, invocationID: result.invocationID, nativeTurnID: result.nativeTurnID,
            text: result.text, attachmentIDs: [UUID()], completedAt: result.completedAt
        )
        return .init(schemaVersion: 3, hostID: hostID, definitions: [definition], instances: [agent], runs: [run])
    }

    @Test(arguments: [1, 2, 3], [false, true])
    func oldAgentOutputsDoNotPreventLoadingOtherWorkflowData(schema: Int, completed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        var saved = try archive(completed: completed)
        saved.schemaVersion = schema
        try JSONEncoder().encode(saved).write(to: file)
        let restored = try await AgentWorkflowStore(fileURL: file, hostID: saved.hostID).snapshot()
        let run = try #require(restored.runs.first)
        #expect(restored.schemaVersion == 6)
        #expect(restored.definitions == saved.definitions)
        #expect(run.id == saved.runs[0].id)
        #expect(run.status == (completed ? .completed : .paused))
        #expect(run.invocations.count == saved.runs[0].invocations.count)
        #expect(run.invocations[0] == saved.runs[0].invocations[0])
        #expect(run.invocations.map(\.delivery) == saved.runs[0].invocations.map(\.delivery))
        let result = try #require(run.invocations[1].result)
        let original = try #require(saved.runs[0].invocations[1].result)
        #expect(result == .init(
            id: original.id, invocationID: original.invocationID, nativeTurnID: original.nativeTurnID,
            text: original.text, completedAt: original.completedAt
        ))
        #expect(try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: file)) == restored)
        let reloaded = try await AgentWorkflowStore(fileURL: file, hostID: saved.hostID).snapshot()
        #expect(reloaded.schemaVersion == 6)
        #expect(reloaded.definitions == restored.definitions)
        #expect(reloaded.runs[0].status == run.status)
        #expect(reloaded.runs[0].invocations == run.invocations)
    }

    @Test(arguments: ["current-output", "missing-turn", "wrong-host", "future-schema"])
    func invalidRecordsAreStillRejectedWithoutRewriting(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        var saved = try archive(completed: true)
        if scenario == "current-output" {
            saved.schemaVersion = 4
        }
        if scenario == "future-schema" {
            saved.schemaVersion = 7
        }
        if scenario == "missing-turn" {
            saved.runs[0].invocations[1].nativeTurnID = nil
            let result = try #require(saved.runs[0].invocations[1].result)
            saved.runs[0].invocations[1].result = .init(
                id: result.id, invocationID: result.invocationID, nativeTurnID: nil,
                text: result.text, attachmentIDs: result.attachmentIDs, completedAt: result.completedAt
            )
        }
        let data = try JSONEncoder().encode(saved)
        try data.write(to: file)
        let store = AgentWorkflowStore(fileURL: file, hostID: scenario == "wrong-host" ? UUID() : saved.hostID)
        await #expect(throws: AgentWorkflowError.self) { try await store.snapshot() }
        #expect(try Data(contentsOf: file) == data)
    }

    @MainActor
    @Test
    func localEndpointReportsStartupFailureAndCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[HostIdentityClient.self].load = { UUID() }
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.ctrlxPaths = CtrlxPaths(stateRootOverride: directory)
            let endpoint = coordinator.localWorkflowEndpoint()
            #expect(endpoint.isSupported)
            await #expect(throws: AgentWorkflowError("Workflows are still starting on this Mac. Try again shortly.")) {
                try await endpoint.request(.definitions(offset: 0))
            }
            let file = directory.appendingPathComponent("Workflows/ledger.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let corrupt = Data("not JSON".utf8)
            try corrupt.write(to: file)
            await coordinator.setupAgentWorkflows()
            let message = try #require(coordinator.agentWorkflowStartupError)
            #expect(message.hasPrefix("Could not load workflows on this Mac:"))
            await #expect(throws: AgentWorkflowError(message)) { try await endpoint.request(.definitions(offset: 0)) }
            #expect(try Data(contentsOf: file) == corrupt)
            let saved = try archive(completed: true)
            try JSONEncoder().encode(saved).write(to: file)
            try await withDependencies {
                $0[HostIdentityClient.self].load = { saved.hostID }
            } operation: {
                await coordinator.setupAgentWorkflows()
                #expect(coordinator.agentWorkflowStartupError == nil)
                let overview = try await endpoint.overview()
                #expect(overview.hostID == saved.hostID)
                #expect(overview.definitions.map(\.id) == saved.definitions.map(\.id))
                #expect(overview.runs.map(\.id) == saved.runs.map(\.id))
                await coordinator.stopAgentWorkflows()
            }
        }
    }
}
