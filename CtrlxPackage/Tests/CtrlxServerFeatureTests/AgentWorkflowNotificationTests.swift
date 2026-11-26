import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowNotificationTests {
    private struct Fixture {
        let directory: URL
        let store: AgentWorkflowStore
        let run: AgentWorkflowRun

        func complete() async throws -> AgentWorkflowRun {
            try await store.update(runID: run.id) { execution in
                for node in execution.run.definition.nodes {
                    _ = try execution.prepareInvocation(nodeID: node.id, now: Date())
                }
            }
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-notifications-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID)
        let review = AgentWorkflowNode(name: "Review", content: .init(text: "Approved"))
        let commit = AgentWorkflowNode(name: "Commit", content: .init(text: "Final handoff"))
        let definition = try await store.saveDefinition(.init(
            name: "Develop and review", hostID: hostID, nodes: [review, commit],
            edges: [.init(source: review.id, target: commit.id)], entryNodeID: review.id
        ), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        return .init(directory: directory, store: store, run: run)
    }

    @Test
    func completionIntentWaitsForFinalStepAndIsDurable() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try #require(fixture.run.definition.nodes.first)
        _ = try await fixture.store.update(runID: fixture.run.id) {
            _ = try $0.prepareInvocation(nodeID: first.id, now: Date())
        }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id] == nil)
        let completed = try await fixture.complete()
        #expect(completed.status == .completed)
        let intent = try #require(await fixture.store.snapshot().notifications?[fixture.run.id])
        #expect(intent.kind == .completed && intent.target.runID == completed.id)
        let restarted = AgentWorkflowStore(fileURL: fixture.directory.appendingPathComponent("ledger.json"), hostID: completed.definition.hostID)
        #expect(try await restarted.snapshot().notifications?[completed.id] == intent)
        _ = try await fixture.store.update(runID: completed.id) { _ in }
        #expect(try await fixture.store.snapshot().notifications?[completed.id]?.id == intent.id)
    }

    @Test
    func manualPauseAndEndAreSilentButNewBlockingEpisodesAlert() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Operator pause", operatorInitiated: true) }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id] == nil)
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Agent failed while paused") }
        let pausedFailure = try #require(await fixture.store.snapshot().notifications?[fixture.run.id])
        #expect(pausedFailure.kind == .attention && pausedFailure.issue == "Agent failed while paused")
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Agent failed while paused") }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id]?.id == pausedFailure.id)
        _ = try await fixture.store.update(runID: fixture.run.id) { try $0.resume(instances: [], now: Date()) }
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Receipt verification timed out") }
        let first = try #require(await fixture.store.snapshot().notifications?[fixture.run.id])
        #expect(first.kind == .attention)
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Receipt verification timed out") }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id]?.id == first.id)
        _ = try await fixture.store.update(runID: fixture.run.id) { try $0.resume(instances: [], now: Date()) }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id] == nil)
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Agent unavailable") }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id]?.id != first.id)
        _ = try await fixture.store.update(runID: fixture.run.id) { $0.end() }
        #expect(try await fixture.store.snapshot().notifications?[fixture.run.id] == nil)
    }

    @Test
    func migrationDoesNotNotifyHistoricalCompletions() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.complete()
        var archive = try await fixture.store.snapshot()
        archive.schemaVersion = 11
        archive.notifications = nil
        let file = fixture.directory.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(archive).write(to: file)
        let restored = try await AgentWorkflowStore(fileURL: file, hostID: archive.hostID).snapshot()
        #expect(restored.notifications == nil)
        #expect(restored.runs.first?.status == .completed)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("schema-11.backup").path))
    }

    @Test
    func retriesAfterRestartOnlySendFailedDestinationsAndDoNotChangeRunRevision() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let completed = try await fixture.complete()
        let time = LockIsolated(Date())
        let sent = LockIsolated<[String]>([])
        let delivery = AgentWorkflowNotificationDelivery(store: fixture.store, destinations: { ["local", "phone"] }, send: { _, target in
            sent.withValue { $0.append(target) }
            if target == "phone" {
                throw AgentWorkflowError("Relay offline")
            }
        }, now: { time.value })
        try await delivery.flush()
        try await delivery.flush()
        #expect(sent.value == ["local", "phone"])
        let first = try #require(await fixture.store.snapshot().notifications?[completed.id])
        #expect(first.deliveries?.first(where: { $0.destination == "phone" })?.error == "Relay offline")
        #expect(try await fixture.store.snapshot().runs.first?.revision == completed.revision)
        time.withValue { $0 = $0.addingTimeInterval(60) }
        let restarted = AgentWorkflowStore(fileURL: fixture.directory.appendingPathComponent("ledger.json"), hostID: completed.definition.hostID)
        let retry = AgentWorkflowNotificationDelivery(store: restarted, destinations: { ["local", "phone"] }, send: { _, target in
            sent.withValue { $0.append(target) }
        }, now: { time.value })
        try await retry.flush()
        try await retry.flush()
        #expect(sent.value == ["local", "phone", "phone"])
        #expect(try await restarted.snapshot().notifications?[completed.id]?.deliveries?.allSatisfy { $0.submittedAt != nil } == true)
    }

    @Test
    func terminalLookupKeepsRecentCompletionWithoutLiveProcessCatalog() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let hostID = fixture.run.definition.hostID
        let pane = WorkspacePaneIdentity(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let instance = try #require(await fixture.store.reconcile([.init(
            pluginID: "codex", processID: 101, processRuntimeID: "101:start", workspacePane: pane,
            paneID: "%1", conversationID: "native", displayName: "Developer", workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )]).first)
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = try await fixture.store.saveDefinition(.init(name: "Agent work", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id), expectedRevision: nil)
        let run = try await fixture.store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        _ = try await fixture.store.update(runID: run.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: node.id, now: Date())
            try execution.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn")
            try execution.succeed(.init(invocationID: invocation.id, nativeTurnID: "turn", text: "Done", completedAt: Date()), instance: instance, now: Date())
        }
        _ = try await fixture.store.reconcile([])
        let service = AgentWorkflowService(store: fixture.store, scan: { _ in [] }, schedule: { _ in })
        let response = try await service.handle(.init(.terminal(pane)))
        #expect(response.run?.summary.id == run.id)
        #expect(response.run?.summary.status == .completed)
        #expect(response.run?.notification?.kind == .completed)
    }
}
