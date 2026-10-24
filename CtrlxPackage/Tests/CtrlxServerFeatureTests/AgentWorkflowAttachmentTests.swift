import CryptoKit
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowAttachmentTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-attachments-\(UUID())")
        let hostID = UUID()
        var file: URL {
            root.appendingPathComponent("ledger.json")
        }

        func store() -> AgentWorkflowStore {
            .init(fileURL: file, hostID: hostID)
        }

        func directory(_ id: UUID) -> URL {
            root.appendingPathComponent("attachments/\(id.uuidString)")
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func upload(_ data: Data, to store: AgentWorkflowStore, id: UUID = UUID()) async throws -> AgentWorkflowAttachment {
        _ = try await store.uploadAttachment(.begin(id: id, name: "任务.txt", mediaType: "text/plain", size: data.count))
        for offset in stride(from: 0, to: data.count, by: AgentWorkflowWire.attachmentChunkBytes) {
            let end = min(offset + AgentWorkflowWire.attachmentChunkBytes, data.count)
            let result = try await store.uploadAttachment(.append(id: id, offset: offset, data: data.subdata(in: offset..<end)))
            #expect(result.offset == end)
        }
        return try #require(await store.uploadAttachment(.finish(id: id, sha256: hash(data))).attachment)
    }

    @Test
    func completeSnapshotSurvivesRestartAndFinishRetry() async throws {
        let f = Fixture(), data = Data(String(repeating: "附件中文\n", count: 20_000).utf8)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store(), id = UUID()
        let attachment = try await upload(data, to: store, id: id)
        let file = f.directory(id).appendingPathComponent("content.txt")
        #expect(try Data(contentsOf: file) == data)
        #expect(attachment.sha256 == hash(data))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try await store.uploadAttachment(.finish(id: id, sha256: hash(data))).attachment == attachment)
        #expect(try await store.snapshot().attachments?.count == 1)
        await store.shutdownAttachmentUploads()
        let restored = f.store()
        try await restored.recoverAttachmentStorage()
        #expect(try await restored.attachmentMetadata([id]) == [attachment])
        #expect(try Data(contentsOf: file) == data)
    }

    @Test(arguments: ["checksum", "offset", "oversize", "cancel"])
    func incompleteUploadsNeverBecomeAttachments(failure: String) async throws {
        let f = Fixture(), id = UUID(), data = Data("original".utf8)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        _ = try await store.uploadAttachment(.begin(id: id, name: "a.txt", mediaType: "text/plain", size: data.count))
        #expect(try await store.snapshot().attachments == nil)
        if failure == "cancel" {
            _ = try await store.uploadAttachment(.cancel(id: id))
        } else {
            let operation: AgentWorkflowAttachmentUpload
            switch failure {
            case "offset": operation = .append(id: id, offset: 1, data: data)
            case "oversize": operation = .append(id: id, offset: 0, data: Data(count: AgentWorkflowWire.attachmentChunkBytes + 1))
            default:
                _ = try await store.uploadAttachment(.append(id: id, offset: 0, data: data))
                operation = .finish(id: id, sha256: String(repeating: "0", count: 64))
            }
            await #expect(throws: (any Error).self) { try await store.uploadAttachment(operation) }
        }
        #expect(try await store.snapshot().attachments == nil)
        #expect(!FileManager.default.fileExists(atPath: f.directory(id).path))
        await store.shutdownAttachmentUploads()
    }

    @Test
    func expiredUploadsAndHostRestartCleanOnlyPartialTransfers() async throws {
        let f = Fixture(), id = UUID()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        let saved = try await upload(Data("saved".utf8), to: store)
        _ = try await store.uploadAttachment(.begin(id: id, name: "lost.txt", mediaType: "text/plain", size: 10))
        #expect(await store.expireAttachmentUploads(now: .now.advanced(by: .seconds(61))) == false)
        #expect(!FileManager.default.fileExists(atPath: f.directory(id).path))
        let crashed = f.directory(UUID())
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: crashed.appendingPathComponent("partial"))
        await store.shutdownAttachmentUploads()
        let restored = f.store()
        try await restored.recoverAttachmentStorage()
        #expect(!FileManager.default.fileExists(atPath: crashed.path))
        #expect(FileManager.default.fileExists(atPath: f.directory(saved.id).path))
    }

    @Test
    func invalidNameOrExistingDirectoryCannotOverwriteFiles() async throws {
        let f = Fixture(), id = UUID()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        for name in ["../a.txt", "a\nb.txt", ".", String(repeating: "x", count: 257)] {
            await #expect(throws: AgentWorkflowError.self) {
                try await store.uploadAttachment(.begin(id: id, name: name, mediaType: "text/plain", size: 10))
            }
        }
        try FileManager.default.createDirectory(at: f.directory(id), withIntermediateDirectories: true)
        let existing = f.directory(id).appendingPathComponent("keep")
        try Data("keep".utf8).write(to: existing)
        await #expect(throws: AgentWorkflowError.self) {
            try await store.uploadAttachment(.begin(id: id, name: "a.txt", mediaType: "text/plain", size: 10))
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        await store.shutdownAttachmentUploads()
    }

    @Test
    func deletingTemplatesRetainsFilesUntilTheirLastRunIsDeleted() async throws {
        let f = Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        let attachment = try await upload(Data("Keep through history".utf8), to: store)
        let instances = try await store.reconcile([.init(
            pluginID: "codex", processID: 100, processRuntimeID: "start",
            workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Dev", workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 100_000, mediaTypes: ["text/plain"]), readiness: .ready
        )])
        let node = AgentWorkflowNode(name: "Dev", agentInstanceID: instances[0].id)
        func definition() -> AgentWorkflowDefinition {
            .init(
                name: "Workflow",
                hostID: f.hostID,
                nodes: [node],
                edges: [],
                entryNodeID: node.id,
                initialInput: .init(text: "Task", attachmentIDs: [attachment.id])
            )
        }
        let a = try await store.saveDefinition(definition(), expectedRevision: nil)
        let b = try await store.saveDefinition(definition(), expectedRevision: nil)
        let run = try await store.start(
            definitionID: a.id,
            expectedRevision: a.revision,
            requestID: UUID(),
            now: .now,
            authorizationExpiresAt: .now.addingTimeInterval(3_600)
        )
        await #expect(throws: AgentWorkflowError.self) { try await store.discardAttachments([attachment.id]) }
        try await store.deleteDefinition(id: a.id, expectedRevision: a.revision)
        try await store.deleteDefinition(id: b.id, expectedRevision: b.revision)
        #expect(FileManager.default.fileExists(atPath: f.directory(attachment.id).path))
        let ended = try await store.update(runID: run.id) { $0.end() }
        try await store.deleteRun(id: run.id, expectedRevision: ended.revision)
        #expect(!FileManager.default.fileExists(atPath: f.directory(attachment.id).path))
        #expect(try await store.snapshot().attachments == [])
        await store.shutdownAttachmentUploads()
    }

    @Test
    func unsavedImportCanBeDiscardedAndMissingIDsCannotBeSaved() async throws {
        let f = Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        let attachment = try await upload(Data("unsaved".utf8), to: store)
        try await store.discardAttachments([attachment.id])
        let node = AgentWorkflowNode(name: "Role", agentInstanceID: UUID())
        let definition = AgentWorkflowDefinition(
            name: "Missing",
            hostID: f.hostID,
            nodes: [node],
            edges: [],
            entryNodeID: node.id,
            initialInput: .init(attachmentIDs: [attachment.id])
        )
        await #expect(throws: AgentWorkflowError.self) { try await store.saveDefinition(definition, expectedRevision: nil) }
        #expect(try await store.snapshot().definitions.isEmpty)
        await store.shutdownAttachmentUploads()
        await #expect(throws: AgentWorkflowError.self) {
            try await store.uploadAttachment(.begin(id: UUID(), name: "a.txt", mediaType: "text/plain", size: 1))
        }
    }

    @Test
    func operatorWireRequiresHostIdentityAndReturnsVerifiedMetadata() async throws {
        let f = Fixture(), id = UUID(), data = Data("wire upload".utf8)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        let service = AgentWorkflowService(store: store, scan: { _ in [] }, schedule: { _ in })
        let begin = ManageAgentWorkflows.Operation.uploadAttachment(.begin(id: id, name: "wire.txt", mediaType: "text/plain", size: data.count))
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(begin)) }
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(begin, expectedHostID: UUID())) }
        #expect(!FileManager.default.fileExists(atPath: f.directory(id).path))
        for operation in [begin, .uploadAttachment(.append(id: id, offset: 0, data: data)), .uploadAttachment(.finish(id: id, sha256: hash(data)))] {
            let wire = try JSONEncoder().encode(ManageAgentWorkflows(operation, expectedHostID: f.hostID))
            let response = try await service.handle(JSONDecoder().decode(ManageAgentWorkflows.self, from: wire))
            #expect(response.hostID == f.hostID)
            #expect(try JSONDecoder().decode(AgentWorkflowResponse.self, from: JSONEncoder().encode(response)) == response)
        }
        let saved = try await service.handle(.init(.attachments([id]), expectedHostID: f.hostID))
        #expect(saved.attachments?.first?.sha256 == hash(data))
        #expect(saved.attachments?.first?.byteCount == Int64(data.count))
        _ = try await service.handle(.init(.discardAttachments([id]), expectedHostID: f.hostID))
        #expect(!FileManager.default.fileExists(atPath: f.directory(id).path))
        await service.shutdown()
    }

    @Test
    func failedLedgerCommitDoesNotPublishOrLeakAnAttachment() async throws {
        let f = Fixture(), id = UUID(), data = Data("content".utf8)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.store()
        _ = try await store.snapshot()
        _ = try await store.uploadAttachment(.begin(id: id, name: "a.txt", mediaType: "text/plain", size: data.count))
        _ = try await store.uploadAttachment(.append(id: id, offset: 0, data: data))
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.uploadAttachment(.finish(id: id, sha256: hash(data))) }
        #expect(try await store.snapshot().attachments == nil)
        #expect(!FileManager.default.fileExists(atPath: f.directory(id).path))
        await store.shutdownAttachmentUploads()
    }
}
