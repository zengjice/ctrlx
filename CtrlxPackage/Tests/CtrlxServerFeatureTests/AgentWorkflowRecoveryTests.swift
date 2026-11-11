import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["over-limit", "exact-limit", "revision-growth"])
    func nameMigrationKeepsTheArchiveAccessibleNearTheTotalLimit(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-name-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        let hostID = UUID()
        let instance = AgentWorkflowInstance(
            hostID: hostID,
            pluginID: "codex",
            processID: 42,
            processRuntimeID: "runtime",
            workspacePane: .init(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1",
            conversationID: "conversation",
            displayName: String(repeating: "中", count: 88),
            workingDirectory: "/fixture",
            capabilities: .init(maximumInputBytes: 200_000),
            readiness: .ready
        )
        let node = AgentWorkflowNode(name: "Task", agentInstanceID: instance.id, initialTask: .textAndAttachments)
        var original = AgentWorkflowDefinition(
            revision: scenario == "revision-growth" ? 9 : 1,
            name: "Near the limit",
            hostID: hostID,
            nodes: [node],
            edges: [],
            entryNodeID: node.id,
            participants: [.init(agentInstanceID: instance.id, name: "Reviewer")]
        )
        original.rememberTargets(from: [instance])
        let encoder = JSONEncoder()
        let originalBytes = try encoder.encode(original).count
        var candidate = original
        candidate.updateAgentNames(from: [instance])
        candidate.revision += 1
        let growth = try encoder.encode(candidate).count - originalBytes
        let targetBytes = AgentWorkflowWire.maximumDefinitionBytes - (scenario == "over-limit" ? 64 : growth) + (scenario == "revision-growth" ? 1 : 0)
        original.initialInput.text = String(repeating: "x", count: targetBytes - originalBytes)
        try AgentWorkflowWire.validate(original)
        candidate = original
        candidate.updateAgentNames(from: [instance])
        candidate.revision += 1
        if scenario == "exact-limit" {
            #expect(try encoder.encode(candidate).count == AgentWorkflowWire.maximumDefinitionBytes)
        } else {
            #expect(try encoder.encode(candidate).count > AgentWorkflowWire.maximumDefinitionBytes)
            if scenario == "revision-growth" {
                var beforeRevision = candidate
                beforeRevision.revision = original.revision
                #expect(try encoder.encode(beforeRevision).count == AgentWorkflowWire.maximumDefinitionBytes)
            }
        }
        let other = AgentWorkflowNode(name: "Unrelated", content: .init(text: "Keep this configuration accessible"))
        let unrelated = AgentWorkflowDefinition(name: "Unrelated", hostID: hostID, nodes: [other], edges: [], entryNodeID: other.id)
        try encoder.encode(AgentWorkflowArchive(hostID: hostID, definitions: [original, unrelated], instances: [instance])).write(to: file)

        let expected = scenario == "exact-limit" ? candidate : original
        let store = AgentWorkflowStore(fileURL: file, hostID: hostID)
        let restored = try await store.snapshot()
        #expect(restored.definitions == [expected, unrelated])
        for definition in restored.definitions {
            try AgentWorkflowWire.validate(definition)
        }
        for _ in 0..<3 {
            let reloaded = try await AgentWorkflowStore(fileURL: file, hostID: hostID).snapshot()
            #expect(reloaded.definitions == restored.definitions)
        }
        try await store.deleteDefinition(id: unrelated.id, expectedRevision: unrelated.revision)
        #expect(try await store.snapshot().definitions == [expected])
        _ = try await store.reconcile([AgentWorkflowObservation(instance)])
        let run = try await store.start(definitionID: expected.id, expectedRevision: expected.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        #expect(run.definition == expected)
        #expect(run.instances.first?.id == instance.id)
    }

    @Test
    func anAlreadyOversizedDefinitionIsNotSilentlyKeptByNameMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-invalid-name-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        var saved = try archive(completed: true)
        saved.definitions[0].initialInput.text = String(repeating: "x", count: AgentWorkflowWire.maximumDefinitionBytes)
        let bytes = try JSONEncoder().encode(saved)
        try bytes.write(to: file)
        await #expect(throws: AgentWorkflowError.self) {
            try await AgentWorkflowStore(fileURL: file, hostID: saved.hostID).snapshot()
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: ["live", "restarted", "historical", "missing"])
    func roleAliasesMigrateToAgentNamesWithoutRebindingOrChangingHistory(source: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-agent-names-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.json")
        let legacy = try archive(completed: true)
        try JSONEncoder().encode(legacy).write(to: file)
        var saved = try await AgentWorkflowStore(fileURL: file, hostID: legacy.hostID).snapshot()
        let agent = try #require(saved.instances.first)
        saved.definitions[0].participants = [.init(agentInstanceID: agent.id, name: "Old role alias")]
        saved.definitions[0].revision = 4
        var observation = AgentWorkflowObservation(agent)
        observation.displayName = "workspace · dev"
        if source == "restarted" {
            observation.processID += 1
            observation.processRuntimeID = "restarted"
            observation.conversationID = UUID().uuidString
        }
        saved.instances = ["live", "restarted"].contains(source)
            ? [observation.instance(hostID: saved.hostID, id: source == "restarted" ? UUID() : agent.id)] : []
        if source == "missing" {
            saved.runs = []
        }
        try JSONEncoder().encode(saved).write(to: file)

        let store = AgentWorkflowStore(fileURL: file, hostID: saved.hostID)
        let restored = try await store.snapshot()
        let expectedName = ["live", "restarted"].contains(source) ? "workspace · dev" : source == "historical" ? agent.displayName : "Agent unavailable"
        var expected = saved.definitions[0]
        expected.participants = [.init(agentInstanceID: agent.id, name: expectedName)]
        expected.revision += 1
        #expect(restored.definitions == [expected])
        #expect(restored.runs == saved.runs)
        #expect(restored.schemaVersion == saved.schemaVersion)
        #expect(restored.definitions[0].nodes == saved.definitions[0].nodes)
        await #expect(throws: AgentWorkflowError.self) {
            try await store.saveDefinition(saved.definitions[0], expectedRevision: 4)
        }
        let reloaded = try await AgentWorkflowStore(fileURL: file, hostID: saved.hostID).snapshot()
        #expect(reloaded.definitions == restored.definitions)
        #expect(reloaded.runs == restored.runs)
    }

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
        #expect(restored.schemaVersion == 7)
        var expectedDefinitions = saved.definitions
        for index in expectedDefinitions.indices {
            expectedDefinitions[index].rememberTargets(from: saved.instances)
        }
        #expect(restored.definitions == expectedDefinitions)
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
        #expect(reloaded.schemaVersion == 7)
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
            saved.schemaVersion = 8
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
