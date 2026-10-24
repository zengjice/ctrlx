import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowFinishTests {
    private struct Fixture: Sendable {
        let directory: URL
        let store: AgentWorkflowStore
        let service: AgentWorkflowAgentService
        let instance: AgentWorkflowInstance
        let run: AgentWorkflowRun
        let invocation: AgentWorkflowInvocation
        let peer: PluginIngressPeer

        func request(id: UUID? = nil, reason: String = "Review passed") -> JSONRPCRequest {
            .init(id: UUID().uuidString, method: "workflow.finish", params: [
                "invocationId": .string((id ?? invocation.id).uuidString), "reason": .string(reason),
            ])
        }
    }

    private func fixture(
        allowsFinish: Bool = true,
        loop: Bool = false,
        maximumRounds: Int = 5,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance = { $0 }
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-finish-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID)
        let instance = try #require(await store.reconcile([.init(
            pluginID: "codex", processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "1:100", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Reviewer", workingDirectory: directory.path,
            capabilities: .init(maximumInputBytes: 10_000), readiness: .ready
        )]).first)
        let node = AgentWorkflowNode(name: "Reviewer", agentInstanceID: instance.id, allowsFinish: allowsFinish)
        let definition = try await store.saveDefinition(.init(
            name: "Review", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id,
            loop: loop ? .init(finalNodeID: node.id, maximumRounds: maximumRounds) : nil
        ), expectedRevision: nil)
        let run = try await store.start(
            definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(),
            now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600)
        )
        let active = try await store.update(runID: run.id) {
            let invocation = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            try $0.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn-1")
        }
        let peer = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { pid in
            switch pid {
            case 11: .init(processID: 11, parentProcessID: 10, userID: 501, startSeconds: 101, startMicroseconds: 0)
            case 10: .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
            default: nil
            }
        })
        return try .init(
            directory: directory, store: store,
            service: AgentWorkflowAgentService(store: store, inspect: inspect),
            instance: instance, run: active, invocation: #require(active.invocations.first), peer: peer
        )
    }

    @Test
    func acceptedRequestIsDurableIdempotentAndWaitsForFinalAnswer() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.invocation.delivery.input.text.contains("--invocation \(f.invocation.id.uuidString)"))
        let first = await f.service.handle(f.request(), peer: f.peer)
        let repeated = await f.service.handle(f.request(reason: "Must not replace the accepted reason"), peer: f.peer)
        #expect(first.ok && repeated.ok)
        #expect(first.result?["status"] == .string("finishing"))
        let archive = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: f.directory.appendingPathComponent("ledger.json")))
        #expect(archive.runs[0].status == .finishing)
        #expect(archive.runs[0].finishRequest?.reason == "Review passed")
        #expect(archive.runs[0].invocations[0].result == nil)
        let result = AgentWorkflowResult(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Final review", completedAt: Date())
        let done = try await f.store.update(runID: f.run.id) { _ = try $0.succeed(result, instance: f.instance, now: Date()) }
        #expect(done.status == .completed)
    }

    @Test
    func missingEvidenceAndSelfReportedIdentityAreRejected() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(), peer: nil).error?.code == "workflow_denied")
        var params = f.request().params
        params["_peerPID"] = .int(10)
        params["agentId"] = .string(f.instance.id.uuidString)
        let forged = JSONRPCRequest(id: "forged", method: "workflow.finish", params: params)
        #expect(await f.service.handle(forged, peer: f.peer).error?.code == "invalid_params")
        let stranger = try #require(PluginIngressPeer.capture(peerPID: 12, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        #expect(await f.service.handle(f.request(), peer: stranger).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].finishRequest == nil)
    }

    @Test(arguments: [false, true])
    func finishAcrossPermissionPauseWaitsForOperatorWithoutAnotherRound(pauseBeforeRequest: Bool) async throws {
        let f = try await fixture(loop: true, maximumRounds: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if !pauseBeforeRequest {
            try #require(await f.service.handle(f.request(), peer: f.peer).ok)
        }
        _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Permission requires a human response") }
        let response = await f.service.handle(f.request(), peer: f.peer)
        try #require(response.ok)
        #expect(response.result?["status"] == .string("paused"))
        let completed = try await f.store.update(runID: f.run.id) {
            _ = try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Review passed", completedAt: .now), instance: f.instance, now: .now)
        }
        #expect(completed.status == .paused)
        #expect(completed.issue == "Permission requires a human response")
        #expect(completed.finishRequest?.invocationID == f.invocation.id)
        #expect(completed.invocations[0].status == .succeeded)
        #expect(try AgentWorkflowExecution(validating: completed).readyNodeIDs.isEmpty)
        let resumed = try await f.store.update(runID: f.run.id) { try $0.resume(instances: [f.instance], now: .now) }
        #expect(resumed.status == .completed)
        #expect(resumed.round == 1 && resumed.invocations.count == 1)
    }

    @Test
    func ungrantedNodeCannotRequestFinish() async throws {
        let f = try await fixture(allowsFinish: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(!f.invocation.delivery.input.text.contains("ctrlx workflow finish"))
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
    }

    @Test
    func changedConversationAndReusedProcessCannotRequestFinish() async throws {
        let f = try await fixture { instance in
            var replacement = instance
            replacement.conversationID = "new-conversation"
            return replacement
        }
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        let reusedPID = try #require(PluginIngressPeer.capture(peerPID: 10, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0)
        })
        #expect(await f.service.handle(f.request(), peer: reusedPID).error?.code == "workflow_denied")
    }

    @Test(arguments: [false, true])
    func expiryAndEndCannotBeUndoneByFinish(paused: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if paused {
            _ = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Human input") }
        }
        let expired = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, now: { f.run.authorizationExpiresAt })
        #expect(await expired.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        _ = try await f.store.update(runID: f.run.id) { $0.end() }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].status == .ended)
    }

    @Test
    func delayedCommandFromPreviousRoundCannotFinishCurrentRound() async throws {
        let f = try await fixture(loop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let next = try await f.store.update(runID: f.run.id) {
            _ = try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn-1", text: "Continue", completedAt: Date()), instance: f.instance, now: Date())
            let second = try $0.prepareInvocation(nodeID: f.invocation.nodeID, now: Date())
            try $0.beginWriting(invocationID: second.id, instance: f.instance, now: Date())
            try $0.accept(invocationID: second.id, instance: f.instance, nativeTurnID: "turn-2")
        }
        #expect(await f.service.handle(f.request(), peer: f.peer).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].status == .running)
        let secondID = try #require(next.invocations.last?.id)
        #expect(await f.service.handle(f.request(id: secondID), peer: f.peer).ok)
    }

    @Test(arguments: ["", " \n\t", String(repeating: "界", count: 2_731)])
    func invalidReasonsDoNotChangeRun(_ reason: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.service.handle(f.request(reason: reason), peer: f.peer).error?.code == "invalid_params")
        #expect(try await f.store.snapshot().runs[0].finishRequest == nil)
    }
}
