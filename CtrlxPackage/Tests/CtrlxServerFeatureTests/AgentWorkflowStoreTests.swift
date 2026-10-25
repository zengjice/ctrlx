import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture: Sendable {
        let directory: URL
        let file: URL
        let hostID: UUID
        let store: AgentWorkflowStore
        let observations: [AgentWorkflowObservation]
        let instances: [AgentWorkflowInstance]
        let definition: AgentWorkflowDefinition
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-tests-\(UUID())")
        let file = directory.appendingPathComponent("state/workflows.json")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: file, hostID: hostID)
        let observations = ["Developer", "Reviewer"].enumerated().map { index, name in
            AgentWorkflowObservation(
                pluginID: "codex",
                processID: Int32(100 + index),
                processRuntimeID: "start-\(index)",
                workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)",
                conversationID: UUID().uuidString,
                displayName: name,
                workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000),
                readiness: .ready
            )
        }
        let instances = try await store.reconcile(observations)
        let nodes = instances.map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let definition = try await store.saveDefinition(
            .init(
                name: "Review",
                hostID: hostID,
                nodes: nodes,
                edges: [.init(source: nodes[0].id, target: nodes[1].id)],
                entryNodeID: nodes[0].id
            ),
            expectedRevision: nil
        )
        return .init(
            directory: directory,
            file: file,
            hostID: hostID,
            store: store,
            observations: observations,
            instances: instances,
            definition: definition
        )
    }

    private func start(_ fixture: Fixture, requestID: UUID = UUID()) async throws -> AgentWorkflowRun {
        try await fixture.store.start(
            definitionID: fixture.definition.id,
            expectedRevision: fixture.definition.revision,
            requestID: requestID,
            now: now,
            authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
    }

    @Test
    func sameProcessKeepsUUIDThroughMovesAndHostRestart() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var moved = fixture.observations
        moved[0].workspacePane.windowID = UUID()
        moved[0].workspacePane.sessionID = UUID()
        moved[0].displayName = "New name"
        let updated = try await fixture.store.reconcile(moved)
        #expect(updated.map(\.id) == fixture.instances.map(\.id))
        let restarted = AgentWorkflowStore(fileURL: fixture.file, hostID: fixture.hostID)
        #expect(try await restarted.snapshot().instances.allSatisfy { $0.readiness == .unavailable })
        #expect(try await restarted.reconcile(moved).map(\.id) == fixture.instances.map(\.id))
    }

    @Test(arguments: ["process", "pane", "server", "conversation", "exited"])
    func changedIdentityPausesAndCannotInheritRun(scenario: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        var observations = fixture.observations
        switch scenario {
        case "process": observations[0].processRuntimeID = "reused-pid"
        case "pane": observations[0].workspacePane.paneID = UUID()
        case "server": observations[0].workspacePane.serverID = "new-tmux"
        case "conversation": observations[0].conversationID = "new-conversation"
        default: observations.removeFirst()
        }
        let current = try await fixture.store.reconcile(observations)
        let snapshot = try await fixture.store.snapshot()
        #expect(snapshot.runs[0].status == .paused)
        if scenario != "conversation" {
            #expect(!current.contains { $0.id == fixture.instances[0].id })
        }
        await #expect(throws: AgentWorkflowError.self) {
            try await fixture.store.update(runID: run.id) { execution in
                try execution.resume(instances: current, now: now)
            }
        }
    }

    @Test
    func missingEvidenceKeepsUUIDButPausesUntilVerifiedAgain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        var observations = fixture.observations
        observations[0].readiness = .unavailable
        #expect(try await fixture.store.reconcile(observations).map(\.id) == fixture.instances.map(\.id))
        #expect(try await fixture.store.snapshot().runs[0].status == .paused)
        let current = try await fixture.store.reconcile(fixture.observations)
        #expect(current.map(\.id) == fixture.instances.map(\.id))
        let resumed = try await fixture.store.update(runID: run.id) { try $0.resume(instances: current, now: now) }
        #expect(resumed.status == .running)
    }

    @Test
    func runtimeCapabilityLossPreservesInstanceButPreventsDispatch() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        var observations = fixture.observations
        observations[0].capabilities = nil
        observations[0].capabilityIssue = "CLI build is not verified."
        observations[0].readiness = .unavailable
        let unsupported = try await fixture.store.reconcile(observations)
        #expect(unsupported.map(\.id) == fixture.instances.map(\.id))
        #expect(unsupported[0].capabilityIssue == observations[0].capabilityIssue)
        #expect(unsupported[1].readiness == .ready)
        let paused = try #require(await fixture.store.snapshot().runs.first)
        #expect(paused.status == .paused)
        #expect(paused.issue == observations[0].capabilityIssue)
        await #expect(throws: AgentWorkflowError.self) {
            try await fixture.store.update(runID: run.id) { try $0.resume(instances: unsupported, now: now) }
        }
        let restored = try await fixture.store.reconcile(fixture.observations)
        #expect(restored[0].id == unsupported[0].id && restored[0].capabilityIssue == nil)
        #expect(try await fixture.store.snapshot().runs[0].status == .paused)
        let resumed = try await fixture.store.update(runID: run.id) { try $0.resume(instances: restored, now: now) }
        #expect(resumed.status == .running)
    }

    @Test
    func duplicateStartsAreIdempotentAndDoNotReserveTwice() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let requestID = UUID()
        async let first = start(fixture, requestID: requestID)
        async let second = start(fixture, requestID: requestID)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(try await fixture.store.snapshot().runs.count == 1)
    }

    @Test
    func activeAndPausedRunsReserveInstancesUntilEnded() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        await #expect(throws: AgentWorkflowError.self) { try await start(fixture) }
        try await fixture.store.update(runID: run.id) { $0.pause(reason: "Manual pause") }
        await #expect(throws: AgentWorkflowError.self) { try await start(fixture) }
        try await fixture.store.update(runID: run.id) { $0.end() }
        let next = try await start(fixture)
        #expect(next.id != run.id)
    }

    @Test
    func multiViewerEditsUseRevisionAndRunKeepsFrozenConfiguration() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        var changed = fixture.definition
        changed.nodes[0].input.text = "New instructions"
        let saved = try await fixture.store.saveDefinition(changed, expectedRevision: fixture.definition.revision)
        #expect(saved.revision == 2)
        let snapshot = try await fixture.store.snapshot()
        #expect(snapshot.runs[0].definition == fixture.definition)
        await #expect(throws: AgentWorkflowError.self) {
            try await fixture.store.saveDefinition(changed, expectedRevision: fixture.definition.revision)
        }
        let paused = try await fixture.store.update(runID: run.id, expectedRevision: run.revision) { $0.pause(reason: "From Viewer A") }
        #expect(paused.revision > run.revision)
        await #expect(throws: AgentWorkflowError.self) {
            try await fixture.store.update(runID: run.id, expectedRevision: run.revision) { $0.end() }
        }
    }

    @Test
    func committedWriteIntentSurvivesRestartAsUncertain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let run = try await start(fixture)
        let written = try await fixture.store.update(runID: run.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: fixture.definition.entryNodeID, now: now)
            try execution.beginWriting(invocationID: invocation.id, instance: fixture.instances[0], now: now)
        }
        let persisted = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fixture.file))
        #expect(persisted.runs[0] == written)
        let restarted = AgentWorkflowStore(fileURL: fixture.file, hostID: fixture.hostID)
        let restored = try await restarted.snapshot()
        #expect(restored.runs[0].status == .paused)
        #expect(restored.runs[0].invocations[0].status == .uncertain)
        #expect(restored.runs[0].invocations[0].delivery == written.invocations[0].delivery)
        #expect(try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fixture.file)) == restored)
    }

    @Test
    func failedPersistenceDoesNotExposeAnUnsavedMutation() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try await fixture.store.snapshot()
        try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
        try Data("not a directory".utf8).write(to: fixture.file.deletingLastPathComponent())
        var changed = fixture.definition
        changed.name = "Must not be exposed"
        await #expect(throws: (any Error).self) {
            try await fixture.store.saveDefinition(changed, expectedRevision: fixture.definition.revision)
        }
        #expect(try await fixture.store.snapshot() == original)
    }

    @Test
    func badArchiveFailsWithoutSilentlyReplacingHistory() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let otherHost = AgentWorkflowStore(fileURL: fixture.file, hostID: UUID())
        await #expect(throws: AgentWorkflowError.self) { try await otherHost.snapshot() }
        let bytes = Data("broken JSON".utf8)
        try bytes.write(to: fixture.file)
        let broken = AgentWorkflowStore(fileURL: fixture.file, hostID: fixture.hostID)
        await #expect(throws: (any Error).self) { try await broken.snapshot() }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }
}
