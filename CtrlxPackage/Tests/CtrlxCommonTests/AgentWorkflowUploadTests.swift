import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowUploadTests {
    @Test
    func cancelledAfterFinishStillCleansCommittedImport() async throws {
        let hostID = UUID(), id = UUID()
        var discarded = false
        let endpoint = AgentWorkflowEndpoint(id: "local", name: "Local", connected: { true }, supported: { true }) { request in
            var response = AgentWorkflowResponse(hostID: hostID)
            switch request.operation {
            case .uploadAttachment(.begin): response.uploadedOffset = 0
            case .uploadAttachment(.append): response.uploadedOffset = 1
            case .uploadAttachment(.finish):
                response.uploadedOffset = 1
                response.attachments = [.init(id: id, name: "a.txt", mediaType: "text/plain", byteCount: 1, sha256: "hash")]
            case .uploadAttachment(.cancel): response.uploadedOffset = 0
            case .discardAttachments: discarded = true
            default: Issue.record("Unexpected request")
            }
            return response
        }
        let task = Task {
            try await withDependencies {
                $0[FileBrowserUploadReader.self] = .init(
                    open: { _ in .init(id: id, name: "a.txt", size: 1) },
                    read: { _ in Data([1]) }, finish: { _ in "hash" },
                    close: { _ in withUnsafeCurrentTask { $0?.cancel() } }
                )
            } operation: {
                try await endpoint.importAttachment(from: URL(fileURLWithPath: "/test/a.txt"), mediaType: "text/plain", hostID: hostID)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(discarded)
    }

    @Test
    func selectedTypesUseOnlySupportedImportFormats() throws {
        #expect(try AgentWorkflowEndpoint.attachmentMediaType(for: URL(fileURLWithPath: "/task/设计.MD")) == "text/markdown")
        #expect(try AgentWorkflowEndpoint.attachmentMediaType(for: URL(fileURLWithPath: "/task/image.JPEG")) == "image/jpeg")
        #expect(try AgentWorkflowEndpoint.attachmentMediaType(for: URL(fileURLWithPath: "/task/voice.m4a")) == "audio/mp4")
        #expect(try AgentWorkflowEndpoint.attachmentMediaType(for: URL(fileURLWithPath: "/task/recording.MOV")) == "video/quicktime")
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowEndpoint.attachmentMediaType(for: URL(fileURLWithPath: "/task/file.html")) }
    }

    @Test
    func fileSnapshotIsSplitIntoBoundedChunksAndItsReceiptIsVerified() async throws {
        let hostID = UUID(), fileID = UUID()
        let data = Data(repeating: 255, count: FileBrowserLimits.chunkBytes)
        let hash = String(repeating: "a", count: 64)
        var received = Data(), closed = false, progresses: [Int] = []
        let endpoint = AgentWorkflowEndpoint(id: "local", name: "Local", connected: { true }, supported: { true }) { request in
            #expect(request.expectedHostID == hostID)
            let encoded = try JSONEncoder().encode(request)
            #expect(encoded.count <= AgentWorkflowWire.maximumEncodedBytes)
            var response = AgentWorkflowResponse(hostID: hostID)
            switch request.operation {
            case let .uploadAttachment(.begin(id, name, mediaType, size)):
                #expect(id == fileID && name == "a.png" && mediaType == "image/png" && size == data.count)
                response.uploadedOffset = 0
            case let .uploadAttachment(.append(id, offset, chunk)):
                #expect(id == fileID && offset == received.count)
                #expect(chunk.count <= AgentWorkflowWire.attachmentChunkBytes)
                received.append(chunk)
                response.uploadedOffset = received.count
            case let .uploadAttachment(.finish(id, sha256)):
                #expect(id == fileID && sha256 == hash)
                response.uploadedOffset = received.count
                response.attachments = [.init(id: id, name: "a.png", mediaType: "image/png", byteCount: Int64(received.count), sha256: hash)]
            default: Issue.record("Unexpected request")
            }
            return response
        }
        let attachment = try await withDependencies {
            $0[FileBrowserUploadReader.self] = .init(
                open: { _ in .init(id: fileID, name: "a.png", size: data.count) },
                read: { _ in data },
                finish: { _ in hash },
                close: { _ in await MainActor.run { closed = true } }
            )
        } operation: {
            try await endpoint.importAttachment(from: URL(fileURLWithPath: "/test/a.png"), mediaType: "image/png", hostID: hostID) { sent, total in
                #expect(total == data.count)
                progresses.append(sent)
            }
        }
        #expect(attachment.id == fileID && closed && received == data)
        #expect(progresses == [0, AgentWorkflowWire.attachmentChunkBytes, data.count])
    }

    @Test(arguments: ["offset", "receipt", "cancellation"])
    func failedImportClosesSnapshotAndCleansBothPartialAndCommittedFiles(failure: String) async {
        let hostID = UUID(), id = UUID()
        var closed = false, cancelled = false, discarded = false
        let endpoint = AgentWorkflowEndpoint(id: "local", name: "Local", connected: { true }, supported: { true }) { request in
            var response = AgentWorkflowResponse(hostID: hostID)
            switch request.operation {
            case .uploadAttachment(.begin): response.uploadedOffset = 0
            case .uploadAttachment(.append):
                if failure == "cancellation" {
                    throw CancellationError()
                }
                response.uploadedOffset = failure == "offset" ? 2 : 1
            case .uploadAttachment(.finish):
                response.uploadedOffset = 1
                response.attachments = [.init(id: UUID(), name: "wrong", mediaType: "text/plain", byteCount: 1, sha256: "wrong")]
            case .uploadAttachment(.cancel): cancelled = true
                response.uploadedOffset = 0
            case .discardAttachments: discarded = true
            default: Issue.record("Unexpected request")
            }
            return response
        }
        await withDependencies {
            $0[FileBrowserUploadReader.self] = .init(
                open: { _ in .init(id: id, name: "a.txt", size: 1) },
                read: { _ in Data([1]) },
                finish: { _ in "hash" },
                close: { _ in await MainActor.run { closed = true } }
            )
        } operation: {
            await #expect(throws: (any Error).self) {
                try await endpoint.importAttachment(from: URL(fileURLWithPath: "/test/a.txt"), mediaType: "text/plain", hostID: hostID)
            }
        }
        #expect(closed && cancelled && discarded)
    }
}
