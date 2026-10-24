import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowArtifactTests {
    private struct Fixture: Sendable {
        let root: URL
        let store: AgentWorkflowStore
        let instances: [AgentWorkflowInstance]
        let definition: AgentWorkflowDefinition
        let runID: UUID

        func task(_ index: Int) async throws -> AgentWorkflowInvocation {
            let run = try await store.update(runID: runID) {
                let task = try $0.prepareInvocation(nodeID: definition.nodes[index].id, now: .now)
                try $0.beginWriting(invocationID: task.id, instance: instances[index], now: .now)
                try $0.accept(invocationID: task.id, instance: instances[index], nativeTurnID: "turn-\(index)")
            }
            return try #require(run.invocations.first { $0.nodeID == definition.nodes[index].id })
        }

        func peer(_ index: Int = 0) throws -> PluginIngressPeer {
            let pid = instances[index].processID
            return try #require(PluginIngressPeer.capture(peerPID: pid + 100, userID: 501) { current in
                if current == pid + 100 {
                    return .init(processID: current, parentProcessID: pid, userID: 501, startSeconds: 101, startMicroseconds: 0)
                }
                if current == pid {
                    return .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
                }
                return nil
            })
        }

        func request(_ task: AgentWorkflowInvocation, id: UUID, action: String, fields: [String: JSONValue] = [:]) -> JSONRPCRequest {
            .init(id: UUID().uuidString, method: "workflow.artifact", params: fields.merging([
                "invocationId": .string(task.id.uuidString), "uploadId": .string(id.uuidString), "action": .string(action),
            ]) { _, new in new })
        }

        func upload(_ data: Data, task: AgentWorkflowInvocation, id: UUID = UUID(), index: Int = 0, finish: Bool = true) async throws -> UUID {
            let service = AgentWorkflowAgentService(store: store, inspect: { $0 })
            let begin = try await service.handle(request(task, id: id, action: "begin", fields: [
                "name": .string("产物.md"), "mediaType": .string("text/markdown"), "size": .int(data.count),
            ]), peer: peer(index))
            #expect(begin.ok)
            for offset in stride(from: 0, to: data.count, by: AgentWorkflowWire.attachmentChunkBytes) {
                let bytes = data.subdata(in: offset..<min(offset + AgentWorkflowWire.attachmentChunkBytes, data.count))
                let response = try await service.handle(request(task, id: id, action: "append", fields: [
                    "offset": .int(offset), "data": .string(bytes.base64EncodedString()),
                ]), peer: peer(index))
                #expect(response.ok)
                #expect(response.result?["offset"] == .int(offset + bytes.count))
            }
            if finish {
                let response = try await service.handle(request(task, id: id, action: "finish", fields: ["sha256": .string(Self.hash(data))]), peer: peer(index))
                #expect(response.ok)
            }
            return id
        }

        func complete(_ task: AgentWorkflowInvocation, index: Int) async throws -> AgentWorkflowRun {
            try await store.update(runID: runID) {
                try $0.succeed(.init(invocationID: task.id, nativeTurnID: "turn-\(index)", text: "Answer \(index)", completedAt: .now), instance: instances[index], now: .now)
            }
        }

        func file(_ id: UUID) -> URL {
            root.appendingPathComponent("attachments/\(id.uuidString)/content.txt")
        }

        static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-artifact-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let observations = (0..<4).map { index in
            AgentWorkflowObservation(
                pluginID: "codex", processID: Int32(10 + index), processRuntimeID: "501:\(10 + index):100:0",
                workspacePane: .init(serverID: "1:100", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)", conversationID: "conversation-\(index)", displayName: "Agent \(index)", workingDirectory: root.path,
                capabilities: .init(maximumInputBytes: 100_000, mediaTypes: ["text/plain", "text/markdown", "image/png"]), readiness: .ready
            )
        }
        let instances = try await store.reconcile(observations)
        let nodes = instances.map { AgentWorkflowNode(name: $0.displayName, agentInstanceID: $0.id) }
        let definition = try await store.saveDefinition(.init(
            name: "Diamond", hostID: hostID, nodes: nodes,
            edges: [(0, 1), (0, 2), (1, 3), (2, 3)].map { .init(source: nodes[$0.0].id, target: nodes[$0.1].id) },
            entryNodeID: nodes[0].id, initialInput: .init(text: "Build and review"), loop: nil
        ), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: .now, authorizationExpiresAt: .now.addingTimeInterval(3_600))
        return .init(root: root, store: store, instances: instances, definition: definition, runID: run.id)
    }

    @Test
    func snapshotsReachBothBranchesAndJoinOnlyAfterFinalAnswers() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.task(0)
        let bytes = Data(String(repeating: "完整产物\n", count: 12_000).utf8)
        let id = try await f.upload(bytes, task: first)
        let before = try #require(await f.store.snapshot().runs.first)
        #expect(before.invocations.first?.result == nil)
        #expect(before.invocations.first?.sharedAttachmentIDs == [id])
        #expect(before.attachmentIDs.contains(id))
        #expect(try Data(contentsOf: f.file(id)) == bytes)
        await #expect(throws: AgentWorkflowError.self) { try await f.store.discardAttachments([id]) }
        #expect(try AgentWorkflowExecution(validating: before).readyNodeIDs.isEmpty)
        let completed = try await f.complete(first, index: 0)
        #expect(completed.invocations.first?.result?.attachmentIDs == [id])
        let a = try await f.task(1)
        let b = try await f.task(2)
        #expect(a.delivery.input.attachmentIDs == [id])
        #expect(b.delivery.input.attachmentIDs == [id])
        #expect(a.delivery.sources.first?.resultID == b.delivery.sources.first?.resultID)
        let aID = try await f.upload(Data("Review A".utf8), task: a, index: 1)
        let bID = try await f.upload(Data("Review B".utf8), task: b, index: 2)
        let bFinished = try await f.complete(b, index: 2)
        #expect(try AgentWorkflowExecution(validating: bFinished).readyNodeIDs.isEmpty)
        _ = try await f.complete(a, index: 1)
        let joined = try await f.task(3)
        #expect(joined.delivery.input.attachmentIDs == [aID, bID])
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        let read = try await service.handle(.init(id: "read", method: "workflow.attachments", params: ["invocationId": .string(joined.id.uuidString)]), peer: f.peer(3))
        #expect(read.ok)
        let done = try await f.complete(joined, index: 3)
        try await f.store.deleteRun(id: done.id, expectedRevision: done.revision)
        #expect(try await f.store.snapshot().attachments?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: f.file(id).path))
        await f.store.shutdownAttachmentUploads()
    }

    @Test
    func otherCallersCannotCancelOrAdoptAnUpload() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.task(0)
        let data = Data("Keep this upload".utf8)
        let id = try await f.upload(data, task: task, finish: false)
        await #expect(throws: AgentWorkflowError.self) { try await f.store.uploadAttachment(.cancel(id: id)) }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        let denied = try await service.handle(f.request(task, id: id, action: "cancel"), peer: f.peer(1))
        #expect(denied.error?.code == "workflow_denied")
        let finish = f.request(task, id: id, action: "finish", fields: ["sha256": .string(Fixture.hash(data))])
        #expect(try await service.handle(finish, peer: f.peer()).ok)
        let revision = try await f.store.snapshot().runs.first?.revision
        #expect(try await service.handle(finish, peer: f.peer()).ok)
        #expect(try await f.store.snapshot().runs.first?.revision == revision)
        _ = try await f.complete(task, index: 0)
        let next = try await f.task(1)
        #expect(try await service.handle(f.request(next, id: id, action: "finish", fields: ["sha256": .string(Fixture.hash(data))]), peer: f.peer(1)).error?.code == "workflow_denied")
        #expect(try Data(contentsOf: f.file(id)) == data)
        await f.store.shutdownAttachmentUploads()
    }

    @Test
    func pausedTaskCanFinishAndStartUploadsWithoutDispatchingDownstream() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.task(0)
        let bytes = Data("Started before permission prompt".utf8)
        let first = try await f.upload(bytes, task: task, finish: false)
        _ = try await f.store.update(runID: f.runID) { $0.pause(reason: "Permission requires a human response") }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        let response = try await service.handle(f.request(task, id: first, action: "finish", fields: ["sha256": .string(Fixture.hash(bytes))]), peer: f.peer())
        try #require(response.ok)
        let second = try await f.upload(Data("Shared after permission was granted".utf8), task: task)
        let paused = try await f.complete(task, index: 0)
        #expect(paused.status == .paused)
        #expect(paused.invocations.count == 1)
        #expect(paused.invocations[0].result?.attachmentIDs == [first, second])
        #expect(try AgentWorkflowExecution(validating: paused).readyNodeIDs.isEmpty)
        _ = try await f.store.update(runID: f.runID) { try $0.resume(instances: f.instances, now: .now) }
        let a = try await f.task(1)
        let b = try await f.task(2)
        #expect(a.delivery.input.attachmentIDs == [first, second])
        #expect(b.delivery.input.attachmentIDs == [first, second])
        await f.store.shutdownAttachmentUploads()
    }

    @Test(arguments: ["missingPeer", "changedConversation", "expired", "ended", "oldTask"], [false, true])
    func invalidAuthorityCannotCreateArtifacts(_ condition: String, paused: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.task(0)
        if condition == "ended" {
            _ = try await f.store.update(runID: f.runID) { $0.end() }
        }
        if condition == "oldTask" {
            _ = try await f.complete(task, index: 0)
        }
        if paused {
            _ = try await f.store.update(runID: f.runID) { $0.pause(reason: "Human takeover") }
        }
        let service = AgentWorkflowAgentService(store: f.store, inspect: {
            var instance = $0
            if condition == "changedConversation" {
                instance.conversationID = "replacement"
            }
            return instance
        }, now: { condition == "expired" ? .distantFuture : .now })
        let id = UUID()
        let response = try await service.handle(f.request(task, id: id, action: "begin", fields: ["name": .string("output.txt"), "mediaType": .string("text/plain"), "size": .int(1)]), peer: condition == "missingPeer" ? nil : f.peer())
        #expect(response.error?.code == "workflow_denied")
        #expect(!FileManager.default.fileExists(atPath: f.file(id).deletingLastPathComponent().path))
        #expect(try await f.store.snapshot().attachments?.isEmpty != false)
        await f.store.shutdownAttachmentUploads()
    }

    @Test(arguments: [false, true])
    func finishRechecksAuthorizationAndCommitsAtomically(diskFailure: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.task(0)
        let bytes = Data("Pending publication".utf8)
        let id = try await f.upload(bytes, task: task, finish: false)
        actor Verification {
            var calls = 0
            func verify(_ instance: AgentWorkflowInstance, store: AgentWorkflowStore, runID: UUID) async throws -> AgentWorkflowInstance {
                calls += 1
                if calls == 2 {
                    _ = try await store.update(runID: runID) { $0.end() }
                }
                return instance
            }
        }
        let verifier = Verification()
        let service = AgentWorkflowAgentService(store: f.store, inspect: {
            if diskFailure {
                return $0
            }
            return try await verifier.verify($0, store: f.store, runID: f.runID)
        })
        if diskFailure {
            let ledger = f.root.appendingPathComponent("ledger.json")
            try FileManager.default.removeItem(at: ledger)
            try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        }
        let response = try await service.handle(f.request(task, id: id, action: "finish", fields: ["sha256": .string(Fixture.hash(bytes))]), peer: f.peer())
        #expect(!response.ok)
        let archive = try await f.store.snapshot()
        #expect(archive.attachments?.isEmpty != false)
        #expect(archive.runs.first?.invocations.first?.sharedAttachmentIDs == nil)
        #expect(!FileManager.default.fileExists(atPath: f.file(id).path))
        await f.store.shutdownAttachmentUploads()
    }

    @Test
    func parserRejectsPathsExtraIdentityAndOversizedChunks() throws {
        let base: [String: JSONValue] = ["invocationId": .string(UUID().uuidString), "uploadId": .string(UUID().uuidString), "action": .string("cancel")]
        for field in ["path", "pane", "agentId"] {
            var invalid = base
            invalid[field] = .string("untrusted")
            #expect(throws: AgentWorkflowError.self) { try AgentWorkflowArtifactRequest(invalid) }
        }
        var append = base
        append["action"] = .string("append")
        append["offset"] = .int(0)
        append["data"] = .string(Data(repeating: 255, count: AgentWorkflowWire.attachmentChunkBytes).base64EncodedString())
        #expect(try JSONEncoder().encode(JSONRPCRequest(id: "chunk", method: "workflow.artifact", params: append)).count < AgentWorkflowWire.maximumEncodedBytes)
        _ = try AgentWorkflowArtifactRequest(append)
        append["data"] = .string(Data(repeating: 255, count: AgentWorkflowWire.attachmentChunkBytes + 1).base64EncodedString())
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowArtifactRequest(append) }
    }
}
