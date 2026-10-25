import CryptoKit
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowConversionTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-conversions-\(UUID())")
        let hostID = UUID()
        var ledger: URL {
            root.appendingPathComponent("ledger.json")
        }

        func store() -> AgentWorkflowStore {
            .init(fileURL: ledger, hostID: hostID)
        }

        func file(_ id: UUID) -> URL {
            root.appendingPathComponent("attachments/\(id.uuidString)")
        }
    }

    private func upload(_ store: AgentWorkflowStore, name: String, type: String) async throws -> AgentWorkflowAttachment {
        let id = UUID(), data = Data("snapshot \(name)".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        _ = try await store.uploadAttachment(.begin(id: id, name: name, mediaType: type, size: data.count))
        _ = try await store.uploadAttachment(.append(id: id, offset: 0, data: data))
        return try #require(await store.uploadAttachment(.finish(id: id, sha256: hash)).attachment)
    }

    @Test
    func conversionKeepsTheOriginalUntilItsLastOutputIsRemoved() async throws {
        let f = Fixture(), store = f.store()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await upload(store, name: "recording.mp4", type: "video/mp4")
        let a = try await upload(store, name: "notes.md", type: "text/markdown")
        let b = try await upload(store, name: "frame.jpg", type: "image/jpeg")
        let outputs = [AgentWorkflowConversionOutput(attachmentID: a.id, description: "Reviewed transcript"), .init(attachmentID: b.id, description: "Sample at 1.0 s")]
        let linked = try await store.linkConversion(sourceID: original.id, outputs: outputs)
        #expect(linked.map { $0.conversion?.sourceSHA256 } == [original.sha256, original.sha256])
        #expect(try await store.linkConversion(sourceID: original.id, outputs: outputs) == linked)
        await #expect(throws: AgentWorkflowError.self) { try await store.discardAttachments([original.id]) }
        try await store.discardAttachments([a.id])
        #expect(FileManager.default.fileExists(atPath: f.file(original.id).path))
        #expect(try await f.store().snapshot().attachments?.count == 2)
        try await store.discardAttachments([b.id])
        #expect(try await store.snapshot().attachments == [])
        #expect(!FileManager.default.fileExists(atPath: f.file(original.id).path))
        await store.shutdownAttachmentUploads()
    }

    @Test
    func savedConvertedOutputProtectsItsOriginalAcrossRestart() async throws {
        let f = Fixture(), store = f.store()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try await upload(store, name: "speech.wav", type: "audio/wav")
        let text = try await upload(store, name: "transcript.md", type: "text/markdown")
        _ = try await store.linkConversion(sourceID: source.id, outputs: [.init(attachmentID: text.id, description: "Reviewed audio")])
        let node = AgentWorkflowNode(name: "Dev", agentInstanceID: UUID())
        let definition = try await store.saveDefinition(.init(name: "Media", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(attachmentIDs: [text.id])), expectedRevision: nil)
        await store.shutdownAttachmentUploads()
        let restored = f.store()
        await #expect(throws: AgentWorkflowError.self) { try await restored.discardAttachments([source.id, text.id]) }
        #expect(FileManager.default.fileExists(atPath: f.file(source.id).path))
        try await restored.deleteDefinition(id: definition.id, expectedRevision: definition.revision)
        #expect(try await restored.snapshot().attachments == [])
        #expect(!FileManager.default.fileExists(atPath: f.file(source.id).path))
    }

    @Test
    func invalidBatchDoesNotPartiallyAttachSourcesAndExistingSourcesCannotChange() async throws {
        let f = Fixture(), store = f.store()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try await upload(store, name: "speech.wav", type: "audio/wav")
        let output = try await upload(store, name: "notes.md", type: "text/markdown")
        await #expect(throws: AgentWorkflowError.self) {
            try await store.linkConversion(sourceID: source.id, outputs: [.init(attachmentID: output.id, description: "Valid"), .init(attachmentID: UUID(), description: "Missing")])
        }
        #expect(try await store.snapshot().attachments?.first(where: { $0.id == output.id })?.conversion == nil)
        _ = try await store.linkConversion(sourceID: source.id, outputs: [.init(attachmentID: output.id, description: "Reviewed")])
        let other = try await upload(store, name: "other.wav", type: "audio/wav")
        await #expect(throws: AgentWorkflowError.self) {
            try await store.linkConversion(sourceID: other.id, outputs: [.init(attachmentID: output.id, description: "Reviewed")])
        }
        #expect(try await store.snapshot().attachments?.first(where: { $0.id == output.id })?.conversion?.sourceID == source.id)
        await store.shutdownAttachmentUploads()
    }

    @Test
    func linkingRequiresOperatorHostIdentityAndLedgerSuccess() async throws {
        let f = Fixture(), store = f.store()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try await upload(store, name: "speech.wav", type: "audio/wav")
        let output = try await upload(store, name: "notes.md", type: "text/markdown")
        let service = AgentWorkflowService(store: store, scan: { _ in [] }, schedule: { _ in })
        let operation = ManageAgentWorkflows.Operation.linkConversion(sourceID: source.id, outputs: [.init(attachmentID: output.id, description: "Reviewed")])
        await #expect(throws: AgentWorkflowError.self) { try await service.handle(.init(operation, expectedHostID: UUID())) }
        try FileManager.default.removeItem(at: f.ledger)
        try FileManager.default.createDirectory(at: f.ledger, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await service.handle(.init(operation, expectedHostID: f.hostID)) }
        #expect(try await store.snapshot().attachments?.first(where: { $0.id == output.id })?.conversion == nil)
        try FileManager.default.removeItem(at: f.ledger)
        let result = try await service.handle(.init(operation, expectedHostID: f.hostID))
        #expect(result.attachments?.first?.conversion?.sourceID == source.id)
        #expect(try JSONDecoder().decode(AgentWorkflowResponse.self, from: JSONEncoder().encode(result)) == result)
        await service.shutdown()
    }
}
