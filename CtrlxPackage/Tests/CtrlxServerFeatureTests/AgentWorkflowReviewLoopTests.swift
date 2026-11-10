import CryptoKit
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

private actor ReviewLoopDeliveryProbe {
    var writes: [AgentWorkflowInvocation] = []
    func record(_ invocation: AgentWorkflowInvocation) {
        writes.append(invocation)
    }
}

struct AgentWorkflowReviewLoopTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func observations() -> [AgentWorkflowObservation] {
        ["Developer", "Reviewer"].enumerated().map { index, name in
            .init(
                pluginID: index == 0 ? "codex" : "claude-code",
                processID: Int32(index + 42),
                processRuntimeID: "runtime-\(index)",
                workspacePane: .init(serverID: "private-tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)",
                conversationID: "conversation-\(index)",
                displayName: name,
                workingDirectory: "/private/workflow-sample",
                capabilities: .init(maximumInputBytes: 100_000, mediaTypes: ["image/png"]),
                readiness: .ready
            )
        }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentWorkflowError("Timed out waiting for the review-loop sample.")
    }

    @Test
    func imageTaskReviewJudgmentRepairAndReviewAgainCompleteWithTwoAgents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-review-loop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID(), imageID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID)
        let agents = try await store.reconcile(observations())
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6iYQAAAAASUVORK5CYII="))
        _ = try await store.uploadAttachment(.begin(id: imageID, name: "task.png", mediaType: "image/png", size: image.count))
        _ = try await store.uploadAttachment(.append(id: imageID, offset: 0, data: image))
        _ = try await store.uploadAttachment(.finish(id: imageID, sha256: SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()))
        var definition = AgentWorkflowDefinition(name: "Requested sample", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID(), initialInput: .init(text: "USER_IMAGE_TASK: implement this image", attachmentIDs: [imageID]))
        AgentWorkflowReviewTemplate.apply(to: &definition, developerID: agents[0].id, reviewerID: agents[1].id)
        definition.nodes[1].input.text += "\nEnd this workflow only when there are no P0, P1, P2 or P3 findings."
        let saved = try await store.saveDefinition(definition, expectedRevision: nil)
        let run = try await store.start(definitionID: saved.id, expectedRevision: saved.revision, requestID: UUID(), now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        #expect(run.instances.count == 2)
        #expect(try await store.snapshot().schemaVersion == 6)
        let probe = ReviewLoopDeliveryProbe()
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { invocation, _ in
            let snapshot = try await store.snapshot().runs[0]
            #expect(snapshot.invocations.first { $0.id == invocation.id }?.status == .writing)
            await probe.record(invocation)
        }), now: { now }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        do {
            await runner.schedule(runID: run.id)
            let steps = saved.nodes
            let order = [steps[0], steps[1], steps[2], steps[4], steps[1]]
            let answers = ["DEVELOPMENT_DONE", "P2 REVIEW_FINDING: missing validation", "Accepted: REVIEW_FINDING. Rejected: none.", "REPAIR_DONE", "No P0–P3 findings."]
            for (index, step) in order.enumerated() {
                try await waitUntil { await probe.writes.count > index }
                let invocation = await probe.writes[index]
                let agent = try #require(run.instances.first { $0.id == invocation.delivery.toAgentID })
                #expect(invocation.nodeID == step.id && invocation.delivery.toAgentID == step.agentInstanceID)
                #expect(invocation.round == (index == 4 ? 2 : 1))
                let input = invocation.delivery.input
                #expect(input.attachmentIDs == (index == 0 ? [imageID] : []))
                if index == 0 {
                    #expect(input.text.contains("USER_IMAGE_TASK"))
                } else {
                    #expect(!input.text.contains("USER_IMAGE_TASK"))
                }
                if index == 1 || index == 4 {
                    #expect(input.text.contains("Review the current implementation"))
                    #expect(!input.text.contains("DEVELOPMENT_DONE") && !input.text.contains("REPAIR_DONE"))
                    #expect(!input.text.contains("Answer from") && !input.text.contains("Content from"))
                } else if index == 2 {
                    #expect(input.text.contains("P2 REVIEW_FINDING") && input.text.contains("Do not fix them yet"))
                } else if index == 3 {
                    #expect(input.text.contains("Fix the Accepted findings"))
                    #expect(!input.text.contains("Accepted: REVIEW_FINDING"))
                    #expect(await probe.writes[2].delivery.toAgentID == agent.id)
                }
                let turn = "native-\(invocation.id)"
                try await runner.accepted(runID: run.id, invocationID: invocation.id, instance: agent, nativeTurnID: turn, transcriptPath: "/fixture/native.jsonl")
                if [0, 3].contains(index) {
                    try await store.update(runID: run.id) { try $0.requestStepCompletion(invocationID: invocation.id, instance: agent, turnID: turn, now: now) }
                }
                if index == 0 {
                    let files = try await store.invocationAttachments(invocation, instance: agent, status: .running, now: now)
                    #expect(try Data(contentsOf: #require(files.first?.url)) == image)
                }
                if index == 4 {
                    try await store.update(runID: run.id) {
                        try $0.requestFinish(invocationID: invocation.id, instance: agent, reason: "No P0–P3 findings", now: now)
                    }
                }
                try await runner.succeeded(runID: run.id, result: .init(invocationID: invocation.id, nativeTurnID: turn, text: answers[index], completedAt: now), instance: agent)
            }
            try await waitUntil { try await store.snapshot().runs[0].status == .completed }
            await runner.shutdown()
            let complete = try await store.snapshot().runs[0]
            #expect(await probe.writes.count == 5)
            #expect(complete.invocations.count == 6)
            #expect(complete.invocations.filter { $0.nodeID == steps[0].id }.count == 1)
            #expect(complete.invocations.first { $0.nodeID == steps[3].id }?.result?.text == steps[3].input.text)
            #expect(complete.instances == run.instances)
            _ = try AgentWorkflowExecution(validating: complete)
            let state = AgentWorkflowRunState(complete, currentInstances: run.instances)
            #expect(state.nodes[0].isSkipped && state.nodes[0].invocation == nil)
            #expect(state.nodes[1].invocation?.status == .succeeded)
            if let output = ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_STEP_EVIDENCE"] {
                let destination = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(complete).write(to: destination.appendingPathComponent("sample-run.json"))
                try encoder.encode(await probe.writes).write(to: destination.appendingPathComponent("sample-deliveries.json"))
            }
        } catch {
            await runner.shutdown()
            throw error
        }
    }

    @Test
    func passingFirstReviewFinishesBeforeJudgmentAndRepairAreDispatched() throws {
        let hostID = UUID()
        let agents = observations().map { $0.instance(hostID: hostID, id: UUID()) }
        var definition = AgentWorkflowDefinition(name: "Already correct", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID())
        AgentWorkflowReviewTemplate.apply(to: &definition, developerID: agents[0].id, reviewerID: agents[1].id)
        definition.nodes[1].input.text += "\nEnd this workflow only when there are no P0, P1, P2 or P3 findings."
        var execution = try AgentWorkflowExecution(definition: definition, instances: agents, now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        for (index, node) in definition.nodes.prefix(2).enumerated() {
            let task = try execution.prepareInvocation(nodeID: node.id, now: now)
            let agent = agents[index]
            try execution.beginWriting(invocationID: task.id, instance: agent, now: now)
            try execution.didWrite(invocationID: task.id)
            try execution.accept(invocationID: task.id, instance: agent, nativeTurnID: task.id.uuidString, transcriptPath: "/fixture/native.jsonl")
            if node.completion == .explicit {
                try execution.requestStepCompletion(invocationID: task.id, instance: agent, turnID: task.id.uuidString, now: now)
            }
            if index == 0 {
                #expect(throws: AgentWorkflowError.self) { try execution.requestFinish(invocationID: task.id, instance: agent, reason: "Not granted", now: now) }
            } else {
                try execution.requestFinish(invocationID: task.id, instance: agent, reason: "No P0–P3 findings", now: now)
            }
            try execution.succeed(.init(invocationID: task.id, nativeTurnID: task.id.uuidString, text: node.name, completedAt: now), instance: agent, now: now)
        }
        #expect(execution.run.status == .completed && execution.run.round == 1)
        #expect(execution.run.invocations.count == 2 && execution.readyNodeIDs.isEmpty)
    }

    @Test
    func savedStepRunResumesTheSamePendingReviewWithoutReplayingInitialDevelopment() throws {
        let hostID = UUID()
        let agents = observations().map { $0.instance(hostID: hostID, id: UUID()) }
        var definition = AgentWorkflowDefinition(name: "Restore", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID())
        AgentWorkflowReviewTemplate.apply(to: &definition, developerID: agents[0].id, reviewerID: agents[1].id)
        definition.nodes[1].input.text += "\nEnd this workflow only when there are no P0, P1, P2 or P3 findings."
        var execution = try AgentWorkflowExecution(definition: definition, instances: agents, now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
        for node in definition.nodes {
            let task = try execution.prepareInvocation(nodeID: node.id, now: now)
            if node.kind == .content {
                continue
            }
            let agent = try #require(agents.first { $0.id == node.agentInstanceID })
            try execution.beginWriting(invocationID: task.id, instance: agent, now: now)
            try execution.didWrite(invocationID: task.id)
            try execution.accept(invocationID: task.id, instance: agent, nativeTurnID: task.id.uuidString, transcriptPath: "/fixture/native.jsonl")
            if node.completion == .explicit {
                try execution.requestStepCompletion(invocationID: task.id, instance: agent, turnID: task.id.uuidString, now: now)
            }
            try execution.succeed(.init(invocationID: task.id, nativeTurnID: task.id.uuidString, text: node.name, completedAt: now), instance: agent, now: now)
        }
        #expect(execution.run.round == 2 && execution.readyNodeIDs == [definition.nodes[1].id])
        let review = try execution.prepareInvocation(nodeID: definition.nodes[1].id, now: now)
        var restored = try AgentWorkflowExecution(restoring: execution.run)
        #expect(restored.run.status == .paused)
        try restored.resume(instances: agents, now: now)
        #expect(try restored.prepareInvocation(nodeID: review.nodeID, now: now).id == review.id)
        #expect(!restored.readyNodeIDs.contains(definition.nodes[0].id))
        #expect(restored.run.invocations.count == 6)
    }
}
