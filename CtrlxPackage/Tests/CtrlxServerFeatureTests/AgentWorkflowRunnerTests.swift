import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

private actor WorkflowDeliveryProbe {
    var writes: [AgentWorkflowInvocation] = []
    var persistedStatuses: [AgentWorkflowInvocationStatus] = []
    var prepared: [UUID] = []

    func preparing(_ id: UUID) {
        prepared.append(id)
    }

    func written(_ invocation: AgentWorkflowInvocation, persistedStatus: AgentWorkflowInvocationStatus) {
        writes.append(invocation)
        persistedStatuses.append(persistedStatus)
    }
}

struct AgentWorkflowRunnerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture: Sendable {
        let directory: URL
        let store: AgentWorkflowStore
        let run: AgentWorkflowRun
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-runner-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("workflow.json"), hostID: hostID)
        let instances = try await store.reconcile((0..<3).map { index in
            .init(
                pluginID: "codex",
                processID: Int32(index + 10),
                processRuntimeID: "runtime-\(index)",
                workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)",
                conversationID: "conversation-\(index)",
                displayName: "Node \(index)",
                workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000),
                readiness: .ready
            )
        })
        let nodes = instances.map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let definition = try await store.saveDefinition(.init(
            name: "Parallel review",
            hostID: hostID,
            nodes: nodes,
            edges: [.init(source: nodes[0].id, target: nodes[1].id), .init(source: nodes[0].id, target: nodes[2].id)],
            entryNodeID: nodes[0].id
        ), expectedRevision: nil)
        let run = try await store.start(
            definitionID: definition.id,
            expectedRevision: definition.revision,
            requestID: UUID(),
            now: now,
            authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
        return .init(directory: directory, store: store, run: run)
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AgentWorkflowError("Timed out waiting for the test's workflow transition.")
    }

    @Test
    func persistsBeforeWritingAndRunsFanOutWithoutDuplicateDelivery() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = WorkflowDeliveryProbe()
        let runner = AgentWorkflowRunner(store: fixture.store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { invocation, _ in
            let run = try await fixture.store.snapshot().runs[0]
            let persisted = try #require(run.invocations.first { $0.id == invocation.id })
            await probe.written(invocation, persistedStatus: persisted.status)
        }), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await runner.schedule(runID: fixture.run.id)
        await runner.schedule(runID: fixture.run.id)
        try await waitUntil { await probe.writes.count == 1 }
        let developer = try #require(await probe.writes.first)
        try await runner.accepted(runID: fixture.run.id, invocationID: developer.id, instance: fixture.run.instances[0], nativeTurnID: "turn-1")
        let result = AgentWorkflowResult(invocationID: developer.id, nativeTurnID: "turn-1", text: "Done", completedAt: now)
        try await runner.succeeded(runID: fixture.run.id, result: result, instance: fixture.run.instances[0])
        try await runner.succeeded(runID: fixture.run.id, result: result, instance: fixture.run.instances[0])
        try await waitUntil { await probe.writes.count == 3 }
        #expect(await probe.persistedStatuses == [.writing, .writing, .writing])
        #expect(await Set(probe.writes.map(\.id)).count == 3)
        let writes = await probe.writes
        #expect(Set(writes.dropFirst().map(\.delivery.toAgentID)) == Set(fixture.run.instances.dropFirst().map(\.id)))
        await runner.shutdown()
    }

    @Test
    func pausingWhilePreparationAwaitsPreventsTerminalWrite() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = WorkflowDeliveryProbe()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let runner = AgentWorkflowRunner(store: fixture.store, transport: .init(inspect: { $0 }, prepare: { invocation, _ in
            await probe.preparing(invocation.id)
            for await _ in release {
                break
            }
        }, write: { _, _ in Issue.record("Paused preparation must not reach the terminal") }), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await runner.schedule(runID: fixture.run.id)
        try await waitUntil { await !probe.prepared.isEmpty }
        try await fixture.store.update(runID: fixture.run.id) { $0.pause(reason: "Human takeover") }
        continuation.yield(())
        try await waitUntil { try await fixture.store.snapshot().runs[0].issue != "Human takeover" }
        let state = try await fixture.store.snapshot().runs[0]
        #expect(state.status == .paused && state.invocations[0].status == .pending)
        await runner.shutdown()
    }

    @Test
    func provenUnwrittenInputCanResumeAndPreparationIsDiscarded() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let discarded = WorkflowDeliveryProbe()
        let runner = AgentWorkflowRunner(store: fixture.store, transport: .init(
            inspect: { $0 }, prepare: { _, _ in },
            write: { _, _ in throw AgentWorkflowInputNotWritten(reason: "Human took over before paste") },
            discard: { await discarded.preparing($0) }
        ), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await runner.schedule(runID: fixture.run.id)
        try await waitUntil { await !discarded.prepared.isEmpty }
        let paused = try await fixture.store.snapshot().runs[0]
        #expect(paused.status == .paused && paused.invocations[0].status == .pending)
        let resumed = try await fixture.store.update(runID: fixture.run.id) {
            try $0.resume(instances: fixture.run.instances, now: now)
        }
        #expect(resumed.status == .running)
        await runner.shutdown()
    }

    @Test
    func failedWriteAndMissingAcknowledgementRemainUncertain() async throws {
        for failWrite in [true, false] {
            let fixture = try await fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let probe = WorkflowDeliveryProbe()
            let runner = AgentWorkflowRunner(store: fixture.store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { invocation, _ in
                await probe.written(invocation, persistedStatus: .writing)
                if failWrite {
                    throw AgentWorkflowError("Connection lost after paste")
                }
            }), acceptanceTimeout: .milliseconds(10), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
            await runner.schedule(runID: fixture.run.id)
            try await waitUntil { try await fixture.store.snapshot().runs[0].status == .paused }
            let state = try await fixture.store.snapshot().runs[0]
            #expect(state.invocations[0].status == .uncertain)
            await runner.schedule(runID: fixture.run.id)
            #expect(await probe.writes.count == 1)
            await runner.shutdown()
        }
    }

    @Test
    func stalePreflightLeavesInputUnwritten() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AgentWorkflowRunner(
            store: fixture.store,
            transport: .init(inspect: { original in
                var replaced = original
                replaced.conversationID = "reset"
                return replaced
            }, prepare: { _, _ in Issue.record("Identity must be checked before preparing") }, write: { _, _ in Issue.record("Changed Agent must not receive input") }),
            now: { now },
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        await runner.schedule(runID: fixture.run.id)
        try await waitUntil { try await fixture.store.snapshot().runs[0].status == .paused }
        #expect(try await fixture.store.snapshot().runs[0].invocations[0].status == .pending)
        await runner.shutdown()
    }
}
