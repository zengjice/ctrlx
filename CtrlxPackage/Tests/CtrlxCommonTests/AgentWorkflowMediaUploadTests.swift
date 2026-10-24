import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowMediaUploadTests {
    @Test(arguments: ["success", "changed-original", "bad-receipt", "lost-receipt"])
    func conversionIsPublishedOnlyAfterItsOriginalAndReceiptAreVerified(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-media-upload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("voice.wav"), notes = root.appendingPathComponent("notes.md")
        let originalData = Data("frozen audio bytes".utf8)
        try originalData.write(to: original)
        try Data("# Reviewed transcript\n中文语音。".utf8).write(to: notes)
        let checksum = SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()
        let source = AgentWorkflowMediaSource(id: UUID(), url: original, mediaType: "audio/wav", sha256: mode == "changed-original" ? "wrong" : checksum, duration: 1, hasAudio: true, hasVideo: false)
        let hostID = UUID()
        var pending: [UUID: (name: String, type: String, data: Data)] = [:]
        var stored: [UUID: AgentWorkflowAttachment] = [:]
        var discardIDs: [UUID] = []
        var didLink = false
        let endpoint = AgentWorkflowEndpoint(id: "local", name: "Local", connected: { true }, supported: { true }) { request in
            #expect(request.expectedHostID == hostID)
            var response = AgentWorkflowResponse(hostID: hostID)
            switch request.operation {
            case let .uploadAttachment(.begin(id, name, type, _)):
                pending[id] = (name, type, Data())
                response.uploadedOffset = 0
            case let .uploadAttachment(.append(id, offset, data)):
                #expect(offset == pending[id]?.data.count)
                pending[id]?.data.append(data)
                response.uploadedOffset = pending[id]?.data.count
            case let .uploadAttachment(.finish(id, sha256)):
                let file = try #require(pending[id])
                let attachment = AgentWorkflowAttachment(id: id, name: file.name, mediaType: file.type, byteCount: Int64(file.data.count), sha256: sha256)
                stored[id] = attachment
                response.attachments = [attachment]
                response.uploadedOffset = file.data.count
            case let .linkConversion(sourceID, outputs):
                didLink = true
                let source = try #require(stored[sourceID])
                let linked = try outputs.map { output in
                    let item = try #require(stored[output.attachmentID])
                    return AgentWorkflowAttachment(
                        id: item.id,
                        name: item.name,
                        mediaType: item.mediaType,
                        byteCount: item.byteCount,
                        sha256: item.sha256,
                        conversion: .init(sourceID: source.id, sourceName: source.name, sourceSHA256: source.sha256, description: output.description)
                    )
                }
                for value in linked {
                    stored[value.id] = value
                }
                if mode == "lost-receipt" {
                    throw AgentWorkflowError("Connection dropped after Host commit")
                }
                response.attachments = mode == "bad-receipt" ? [] : linked
            case let .discardAttachments(ids):
                discardIDs += ids
                for id in ids {
                    stored[id] = nil
                }
            default: Issue.record("Unexpected request")
            }
            return response
        }
        try await withDependencies { $0[FileBrowserUploadReader.self] = .liveValue } operation: {
            let work = {
                try await endpoint.importMedia(source: source, outputs: [.init(url: notes, mediaType: "text/markdown", description: "Reviewed audio transcript")], hostID: hostID, progress: { _, _ in })
            }
            if mode == "success" {
                let result = try await work()
                #expect(result.outputs.count == 1 && result.outputs[0].conversion?.sourceID == result.original.id)
                #expect(result.original.sha256 == checksum && discardIDs.isEmpty)
                #expect(stored.count == 2 && didLink)
            } else {
                await #expect(throws: AgentWorkflowError.self) { try await work() }
                #expect(stored.isEmpty)
                #expect(discardIDs.count == (mode == "changed-original" ? 1 : 2))
                #expect(didLink == (mode != "changed-original"))
            }
        }
    }
}
