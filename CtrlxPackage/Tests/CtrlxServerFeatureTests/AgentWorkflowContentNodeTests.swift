import CryptoKit
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowContentNodeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func instance(hostID: UUID, name: String) -> AgentWorkflowInstance {
        .init(
            hostID: hostID,
            pluginID: "codex",
            processID: 42,
            processRuntimeID: UUID().uuidString,
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1",
            conversationID: UUID().uuidString,
            displayName: name,
            workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 100_000, mediaTypes: ["text/plain"]),
            readiness: .ready
        )
    }

    private func finish(_ task: AgentWorkflowInvocation, text: String, in execution: inout AgentWorkflowExecution, artifacts: [UUID] = []) throws {
        let agent = try #require(execution.run.instances.first { $0.id == task.delivery.toAgentID })
        try execution.beginWriting(invocationID: task.id, instance: agent, now: now)
        try execution.didWrite(invocationID: task.id)
        try execution.accept(invocationID: task.id, instance: agent, nativeTurnID: task.id.uuidString)
        for id in artifacts {
            try execution.shareArtifact(id, invocationID: task.id, instance: agent, now: now)
        }
        try execution.succeed(.init(invocationID: task.id, nativeTurnID: task.id.uuidString, text: text, completedAt: now), instance: agent, now: now)
    }

    @Test
    func contentJoinsAllUpstreamsInNodeOrderThenFansOutOneSavedResult() throws {
        let hostID = UUID()
        let agents = ["Review A", "Review B", "Dev A", "Dev B"].map { instance(hostID: hostID, name: $0) }
        let root = AgentWorkflowNode(name: "Brief", content: .init(text: "Original brief"))
        let reviewers = agents.prefix(2).map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let preset = UUID(), artifact = UUID()
        let content = AgentWorkflowNode(name: "Implementation instructions", content: .init(text: "$implement\nFix all findings", attachmentIDs: [preset]))
        let developers = agents.suffix(2).map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let nodes = [root] + reviewers + [content] + developers
        let edges = reviewers.flatMap { [AgentWorkflowEdge(source: root.id, target: $0.id), .init(source: $0.id, target: content.id)] }
            + developers.map { AgentWorkflowEdge(source: content.id, target: $0.id) }
        let definition = AgentWorkflowDefinition(name: "Join", hostID: hostID, nodes: nodes, edges: edges, entryNodeID: root.id)
        var execution = try AgentWorkflowExecution(definition: definition, instances: agents, now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        let rootTask = try execution.prepareInvocation(nodeID: root.id, now: now)
        #expect(rootTask.status == .succeeded && rootTask.delivery.toAgentID == nil && rootTask.result?.nativeTurnID == nil)
        let a = try execution.prepareInvocation(nodeID: reviewers[0].id, now: now)
        let b = try execution.prepareInvocation(nodeID: reviewers[1].id, now: now)
        try finish(b, text: "B's complete answer", in: &execution)
        #expect(!execution.readyNodeIDs.contains(content.id))
        #expect(throws: AgentWorkflowError.self) { try execution.prepareInvocation(nodeID: content.id, now: now) }
        try finish(a, text: "A's complete answer", in: &execution, artifacts: [artifact])
        let joined = try execution.prepareInvocation(nodeID: content.id, now: now)
        #expect(joined.result?.text == "$implement\nFix all findings\n\nOutput from Review A (round 1):\nA's complete answer\n\nOutput from Review B (round 1):\nB's complete answer")
        #expect(joined.result?.attachmentIDs == [preset, artifact])
        #expect(try execution.prepareInvocation(nodeID: content.id, now: now) == joined)
        #expect(execution.readyNodeIDs == developers.map(\.id))
        let left = try execution.prepareInvocation(nodeID: developers[0].id, now: now)
        let right = try execution.prepareInvocation(nodeID: developers[1].id, now: now)
        #expect(left.delivery.sources == right.delivery.sources)
        #expect(left.delivery.sources.first?.resultID == joined.result?.id)
        #expect(left.delivery.sources.first?.agentInstanceID == nil)
        #expect(left.delivery.input.attachmentIDs == [preset, artifact])
        #expect(left.delivery.input.text.contains("Content from Implementation instructions"))
        #expect(try left.delivery.input.text.contains(#require(joined.result?.text)))
        _ = try AgentWorkflowExecution(validating: execution.run)
        #expect(throws: AgentWorkflowError.self) { try execution.accept(invocationID: joined.id, instance: agents[0], nativeTurnID: "forged") }
        #expect(throws: AgentWorkflowError.self) { try execution.requestFinish(invocationID: joined.id, instance: agents[0], reason: "forged", now: now) }
        #expect(throws: AgentWorkflowError.self) { try execution.authorizeArtifact(invocationID: joined.id, instance: agents[0], now: now) }
    }

    @Test(arguments: ["pause", "end", "expired"])
    func stoppedControlPreventsContentOutput(scenario: String) throws {
        let nodes = [AgentWorkflowNode(name: "A", content: .init(text: "A")), .init(name: "B", content: .init(text: "B"))]
        let definition = AgentWorkflowDefinition(
            name: "Content",
            hostID: UUID(),
            nodes: nodes,
            edges: [.init(source: nodes[0].id, target: nodes[1].id)],
            entryNodeID: nodes[0].id
        )
        var execution = try AgentWorkflowExecution(definition: definition, instances: [], now: now, authorizationExpiresAt: now.addingTimeInterval(60))
        _ = try execution.prepareInvocation(nodeID: nodes[0].id, now: now)
        if scenario == "pause" {
            execution.pause(reason: "Operator paused")
        }
        if scenario == "end" {
            execution.end()
        }
        #expect(throws: AgentWorkflowError.self) {
            try execution.prepareInvocation(nodeID: nodes[1].id, now: scenario == "expired" ? now.addingTimeInterval(60) : now)
        }
        #expect(execution.run.invocations.count == 1)
        if scenario == "pause" {
            try execution.resume(instances: [], now: now)
            _ = try execution.prepareInvocation(nodeID: nodes[1].id, now: now)
            #expect(execution.run.status == .completed)
        }
    }

    @Test(arguments: ["text", "attachments"])
    func oversizedContentDoesNotCreatePartialResult(scenario: String) throws {
        let agent = instance(hostID: UUID(), name: "Agent")
        let first = AgentWorkflowNode(name: "Agent", agentInstanceID: agent.id)
        let next = AgentWorkflowNode(name: "Content", content: .init(text: "Preset", attachmentIDs: scenario == "attachments" ? [UUID()] : []))
        let definition = AgentWorkflowDefinition(name: "Limit", hostID: agent.hostID, nodes: [first, next], edges: [.init(source: first.id, target: next.id)], entryNodeID: first.id)
        var execution = try AgentWorkflowExecution(definition: definition, instances: [agent], now: now, authorizationExpiresAt: now.addingTimeInterval(60))
        let task = try execution.prepareInvocation(nodeID: first.id, now: now)
        try finish(
            task,
            text: scenario == "text" ? String(repeating: "x", count: AgentWorkflowWire.maximumContentBytes) : "Done",
            in: &execution,
            artifacts: scenario == "attachments" ? (0..<32).map { _ in UUID() } : []
        )
        #expect(throws: AgentWorkflowError.self) { try execution.prepareInvocation(nodeID: next.id, now: now) }
        #expect(execution.run.invocations.count == 1)
    }

    @Test
    func contentRunNeedsNoAgentScanAndRestartPreservesItsSavedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-content-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID(), path = root.appendingPathComponent("ledger.json")
        let store = AgentWorkflowStore(fileURL: path, hostID: hostID)
        let service = AgentWorkflowService(store: store, scan: { _ in throw AgentWorkflowError("No Agent scan is available") }, schedule: { _ in }, now: { now })
        let a = AgentWorkflowNode(name: "A", content: .init(text: "$skill")), b = AgentWorkflowNode(name: "B", content: .init(text: "Preset"))
        let definition = try await service.save(.init(name: "Content", hostID: hostID, nodes: [a, b], edges: [.init(source: a.id, target: b.id)], entryNodeID: a.id), expectedRevision: nil)
        let run = try await service.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), authorizationExpiresAt: now.addingTimeInterval(60))
        let saved = try await store.update(runID: run.id) { _ = try $0.prepareInvocation(nodeID: a.id, now: now) }
        try await service.checkActiveRuns()
        #expect(try await store.snapshot().schemaVersion == 2)
        let reopened = AgentWorkflowStore(fileURL: path, hostID: hostID)
        let recovered = try #require(try await reopened.snapshot().runs.first)
        #expect(recovered.status == .paused)
        #expect(recovered.invocations == saved.invocations)
        let restarted = AgentWorkflowService(store: reopened, scan: { _ in throw AgentWorkflowError("No Agent scan is available") }, schedule: { _ in }, now: { now })
        let resumed = try await restarted.resume(runID: run.id, expectedRevision: recovered.revision)
        #expect(resumed.instances.isEmpty)
        let completed = try await reopened.update(runID: run.id) { _ = try $0.prepareInvocation(nodeID: b.id, now: now) }
        #expect(completed.status == .completed && completed.invocations.count == 2)
        #expect(completed.invocations[0] == saved.invocations[0])
        let state = AgentWorkflowRunState(completed, currentInstances: [])
        #expect(state.nodes.allSatisfy { $0.kind == .content && $0.instance == nil })
        #expect(try JSONDecoder().decode(AgentWorkflowRunState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test
    func contentAttachmentsAreValidatedAndReadableOnlyByTheDownstreamAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-content-attachments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let data = Data("Read this complete preset.\n第二行".utf8), attachmentID = UUID()
        _ = try await store.uploadAttachment(.begin(id: attachmentID, name: "brief.txt", mediaType: "text/plain", size: data.count))
        _ = try await store.uploadAttachment(.append(id: attachmentID, offset: 0, data: data))
        _ = try await store.uploadAttachment(.finish(id: attachmentID, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let agents = try await store.reconcile([AgentWorkflowObservation(instance(hostID: hostID, name: "Dev"))])
        let agent = try #require(agents.first)
        let a = AgentWorkflowNode(name: "Content", content: .init(text: "$skill", attachmentIDs: [attachmentID]))
        let b = AgentWorkflowNode(name: "Dev", agentInstanceID: agent.id)
        let definition = try await store.saveDefinition(.init(name: "Attachments", hostID: hostID, nodes: [a, b], edges: [.init(source: a.id, target: b.id)], entryNodeID: a.id), expectedRevision: nil)
        let files = try await store.definitionAttachments(id: definition.id, revision: definition.revision)
        try await AgentWorkflowAttachmentReader().validate(files)
        #expect(files.map(\.attachment.id) == [attachmentID])
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(60))
        let prepared = try await store.update(runID: run.id) {
            _ = try $0.prepareInvocation(nodeID: a.id, now: now)
            _ = try $0.prepareInvocation(nodeID: b.id, now: now)
        }
        let input = try await store.invocationAttachments(prepared.invocations[1], instance: agent, status: .pending, now: now)
        #expect(input.map(\.attachment.id) == [attachmentID])
        #expect(try Data(contentsOf: #require(input.first?.url)) == data)
        await #expect(throws: AgentWorkflowError.self) {
            try await store.invocationAttachments(prepared.invocations[0], instance: agent, status: .succeeded, now: now)
        }
        await store.shutdownAttachmentUploads()
    }

    @Test
    func runnerExecutesContentChainsAndStopsAtRoundLimitWithoutTerminalCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-content-runner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let nodes = [AgentWorkflowNode(name: "A", content: .init(text: "A")), .init(name: "B", content: .init(text: "B"))]
        let definition = try await store.saveDefinition(.init(
            name: "Content loop",
            hostID: hostID,
            nodes: nodes,
            edges: [.init(source: nodes[0].id, target: nodes[1].id)],
            entryNodeID: nodes[0].id,
            loop: .init(finalNodeID: nodes[1].id, maximumRounds: 2)
        ), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(60))
        let runner = AgentWorkflowRunner(store: store, transport: .init(
            inspect: { _ in throw AgentWorkflowError("Content must not inspect an Agent") },
            prepare: { _, _ in Issue.record("Content must not prepare terminal input") },
            write: { _, _ in Issue.record("Content must not write terminal input") }
        ), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await runner.schedule(runID: run.id)
        await runner.schedule(runID: run.id)
        for _ in 0..<1_000 {
            if try await store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await runner.shutdown()
        let paused = try await store.snapshot().runs[0]
        #expect(paused.status == .paused && paused.round == 2)
        #expect(paused.invocations.count == 4)
        #expect(paused.invocations.allSatisfy { $0.status == .succeeded && $0.nativeTurnID == nil })
        #expect(paused.invocations[2].delivery.sources.first?.resultID == paused.invocations[1].result?.id)
    }
}
