import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    final private class Backend {
        var observations: [AgentWorkflowObservation]
        var failScan = false
        var scans = 0
        var scheduled: [UUID] = []
        var beforeScan: (() async -> Void)?

        init() {
            self.observations = ["Developer", "Reviewer"].enumerated().map { index, name in
                .init(
                    pluginID: "codex", processID: Int32(100 + index), processRuntimeID: "start-\(index)",
                    workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                    paneID: "%\(index)", conversationID: UUID().uuidString,
                    displayName: name, workingDirectory: "/work",
                    capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
                )
            }
        }

        func scan() async throws -> [AgentWorkflowObservation] {
            scans += 1
            await beforeScan?()
            if failScan {
                throw AgentWorkflowError("Process inspection unavailable")
            }
            return observations
        }
    }

    private struct Fixture {
        let root: URL
        let store: AgentWorkflowStore
        let backend: Backend
        let service: AgentWorkflowService
        let definition: AgentWorkflowDefinition
    }

    private func fixture(clock: (@Sendable () -> Date)? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-service-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let backend = Backend()
        let service = AgentWorkflowService(
            store: store, scan: { _ in try await backend.scan() },
            schedule: { id in await MainActor.run { backend.scheduled.append(id) } }, now: clock ?? { now }
        )
        let instances = try await service.refreshInstancesCatalog()
        let nodes = instances.map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let definition = try await service.save(.init(
            name: "Review", hostID: hostID, nodes: nodes,
            edges: [.init(source: nodes[0].id, target: nodes[1].id)], entryNodeID: nodes[0].id,
            initialInput: .init(text: "Implement the task")
        ), expectedRevision: nil)
        return .init(root: root, store: store, backend: backend, service: service, definition: definition)
    }

    private func start(_ f: Fixture, id: UUID = UUID()) async throws -> AgentWorkflowRun {
        try await f.service.start(
            definitionID: f.definition.id, expectedRevision: f.definition.revision,
            requestID: id, authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
    }

    @Test
    func startsPersistedRunAndRetrySurvivesBusyAgentAndChangedTemplate() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        #expect(try await f.store.snapshot().runs == [run])
        #expect(f.backend.scheduled == [run.id])
        var definition = f.definition
        definition.initialInput.text = "Another task"
        _ = try await f.service.save(definition, expectedRevision: definition.revision)
        f.backend.failScan = true
        #expect(try await start(f, id: run.id) == run)
        #expect(f.backend.scans == 2)
        #expect(f.backend.scheduled == [run.id])
    }

    @Test
    func unavailableProcessScanKeepsCatalogAndRunUntouched() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await start(f)
        let before = try await f.service.snapshot()
        f.backend.failScan = true
        await #expect(throws: AgentWorkflowError.self) { try await f.service.snapshot(refreshInstances: true) }
        #expect(try await f.service.snapshot() == before)
        #expect(f.backend.scheduled.count == 1)
    }

    @Test
    func pausesResumesAndEndsWithoutCreatingAnotherRun() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        let paused = try await f.service.pause(runID: run.id, expectedRevision: run.revision)
        #expect(paused.status == .paused)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.resume(runID: run.id, expectedRevision: run.revision)
        }
        let resumed = try await f.service.resume(runID: run.id, expectedRevision: paused.revision)
        #expect(resumed.status == .running)
        #expect(f.backend.scheduled == [run.id, run.id])
        let ended = try await f.service.end(runID: run.id, expectedRevision: resumed.revision)
        #expect(ended.status == .ended)
        try await f.service.deleteRun(id: run.id, expectedRevision: ended.revision)
        #expect(try await f.service.snapshot().runs.isEmpty)
        #expect(try await f.service.snapshot().instances.count == 2)
    }

    @Test
    func replacementCannotInheritPausedRun() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        let paused = try await f.service.pause(runID: run.id, expectedRevision: run.revision)
        f.backend.observations[0].processRuntimeID = "replacement-start"
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.resume(runID: run.id, expectedRevision: paused.revision)
        }
        let snapshot = try await f.service.snapshot()
        #expect(snapshot.runs.first?.status == .paused)
        #expect(snapshot.instances.first?.id != run.instances.first?.id)
        #expect(f.backend.scheduled.count == 1)
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .awaitingHuman, .busy, .unavailable])
    func blockedAgentPreventsStart(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.backend.observations[1].readiness = readiness
        await #expect(throws: AgentWorkflowError.self) { try await start(f) }
        #expect(try await f.service.snapshot().runs.isEmpty)
        #expect(f.backend.scheduled.isEmpty)
    }

    @Test
    func overlappingViewersShareOneCatalogScan() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        f.backend.beforeScan = {
            entered.continuation.yield(())
            for await _ in released.stream {
                break
            }
        }
        let first = Task { try await f.service.refreshInstancesCatalog() }
        for await _ in entered.stream {
            break
        }
        let second = Task { try await f.service.refreshInstancesCatalog() }
        // Give the second request a chance to reach the already-pending scan.
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.backend.scans == 2)
        released.continuation.finish()
        #expect(try await first.value == second.value)
        #expect(f.backend.scans == 2)
        await f.service.shutdown()
    }

    @Test
    func hostMonitorFindsExitWithoutAnyViewerRequest() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        f.backend.observations.removeFirst()
        await f.service.startMonitoring(interval: .milliseconds(10))
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await f.service.shutdown()
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.id == run.id && saved.status == .paused)
        #expect(saved.issue?.contains("identity") == true)
        #expect(f.backend.scheduled == [run.id])
        let scans = f.backend.scans
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.backend.scans == scans)
    }

    @Test
    func idleWithoutVerifiedResultPausesButNeverResendsOrCompletes() async throws {
        let clock = LockIsolated(now)
        let f = try await fixture(clock: { clock.value })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        let instance = run.instances[0]
        let prepared = try await f.store.update(runID: run.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
            try execution.beginWriting(invocationID: invocation.id, instance: instance, now: now)
            try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "accepted")
        }
        let invocation = try #require(prepared.invocations.first)
        try await f.service.checkActiveRuns()
        clock.setValue(now.addingTimeInterval(59))
        try await f.service.checkActiveRuns()
        #expect(try await f.store.snapshot().runs[0].status == .running)
        clock.setValue(now.addingTimeInterval(60))
        try await f.service.checkActiveRuns()
        let paused = try await f.store.snapshot().runs[0]
        #expect(paused.status == .paused)
        #expect(paused.issue?.contains("without a verified final result") == true)
        #expect(paused.invocations.count == 1 && paused.invocations[0].result == nil)
        #expect(f.backend.scheduled == [run.id])
        // A late *verified* final result is retained while handoffs stay paused.
        let completed = try await f.store.update(runID: run.id) {
            try $0.succeed(.init(invocationID: invocation.id, nativeTurnID: "accepted", text: "Final", completedAt: now), instance: instance, now: now)
        }
        #expect(completed.status == .paused)
        #expect(completed.invocations[0].result?.text == "Final")
    }

    @Test
    func terminalRunsAvoidScansAndExpiryKeepsPausedCatalogFresh() async throws {
        let clock = LockIsolated(now)
        let f = try await fixture(clock: { clock.value })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let scans = f.backend.scans
        try await f.service.checkActiveRuns()
        #expect(f.backend.scans == scans)
        _ = try await start(f)
        clock.setValue(now.addingTimeInterval(3_601))
        try await f.service.checkActiveRuns()
        #expect(try await f.store.snapshot().runs[0].status == .paused)
        #expect(try await f.store.snapshot().runs[0].issue?.contains("authorization expired") == true)
        let afterExpiry = f.backend.scans
        try await f.service.checkActiveRuns()
        #expect(f.backend.scans == afterExpiry + 1)
        let paused = try #require(await f.store.snapshot().runs.first)
        let ended = try await f.service.end(runID: paused.id, expectedRevision: paused.revision)
        let afterEnd = f.backend.scans
        try await f.service.checkActiveRuns()
        #expect(f.backend.scans == afterEnd)
        #expect(try await f.store.snapshot().runs.first == ended)
    }

    @Test(arguments: [AgentWorkflowReadiness.awaitingHuman, .ready])
    func pausedMonitorRefreshesRecoveredInstanceWithoutResuming(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await start(f)
        f.backend.observations[1].readiness = .unavailable
        try await f.service.checkActiveRuns()
        let paused = try #require(await f.store.snapshot().runs.first)
        #expect(paused.status == .paused)

        // A native question can arrive after a transiently unrecognized TUI.
        // Refresh its navigation state without dispatching another task.
        f.backend.observations[1].readiness = readiness
        try await f.service.checkActiveRuns()
        let snapshot = try await f.store.snapshot()
        let response = try await f.service.handle(.init(.run(run.id)))
        #expect(snapshot.runs.first == paused)
        #expect(snapshot.instances[1].id == run.instances[1].id)
        #expect(snapshot.instances[1].readiness == readiness)
        #expect(response.run?.nodes[1].instance?.readiness == readiness)
        #expect(f.backend.scheduled == [run.id])
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .awaitingHuman])
    func backgroundMonitorPausesForHumanWork(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await start(f)
        f.backend.observations[1].readiness = readiness
        try await f.service.checkActiveRuns()
        #expect(try await f.store.snapshot().runs[0].status == .paused)
        #expect(try await f.store.snapshot().runs[0].issue?.contains("human input") == true)
        #expect(f.backend.scheduled.count == 1)
    }
}
