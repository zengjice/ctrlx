import CtrlxNetworking
import Dependencies
import Foundation
import os

public extension AgentWorkflowEndpoint {
    /// The reader owns a coordinated file snapshot. Chunks stay small enough
    /// for the workflow envelope even when JSON escapes every Base64 slash.
    func importAttachment(
        from url: URL, mediaType: String, hostID: UUID,
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> AgentWorkflowAttachment {
        @Dependency(FileBrowserUploadReader.self) var reader
        let file = try await reader.open(url)
        var result: Result<AgentWorkflowAttachment, any Error>
        do {
            try Task.checkCancellation()
            try await uploadAcknowledgement(.begin(id: file.id, name: file.name, mediaType: mediaType, size: file.size), offset: 0, hostID: hostID)
            var offset = 0
            onProgress(0, file.size)
            while offset < file.size {
                try Task.checkCancellation()
                let chunk = try await reader.read(file.id)
                guard !chunk.isEmpty, chunk.count <= FileBrowserLimits.chunkBytes, chunk.count <= file.size - offset else {
                    throw AgentWorkflowError("The source file returned an invalid chunk.")
                }
                for start in stride(from: 0, to: chunk.count, by: AgentWorkflowWire.attachmentChunkBytes) {
                    try Task.checkCancellation()
                    let end = min(chunk.count, start + AgentWorkflowWire.attachmentChunkBytes)
                    let data = chunk.subdata(in: start..<end)
                    try await uploadAcknowledgement(.append(id: file.id, offset: offset, data: data), offset: offset + data.count, hostID: hostID)
                    offset += data.count
                    onProgress(offset, file.size)
                }
            }
            let checksum = try await reader.finish(file.id)
            let response = try await request(.uploadAttachment(.finish(id: file.id, sha256: checksum)), hostID: hostID)
            guard
                response.uploadedOffset == file.size,
                let attachment = response.attachments?.first, response.attachments?.count == 1,
                attachment.id == file.id, attachment.name == file.name, attachment.mediaType == mediaType,
                attachment.byteCount == file.size, attachment.sha256 == checksum else {
                throw AgentWorkflowError("The Host returned an invalid attachment receipt.")
            }
            try Task.checkCancellation()
            result = .success(attachment)
        } catch { result = .failure(error) }
        await reader.close(file.id)
        if Task.isCancelled {
            result = .failure(CancellationError())
        }
        if case .failure = result {
            // Cleanup must run even when the view's task was cancelled. A lost
            // finish reply may leave a committed import, so also remove that
            // unused import. The Host refuses to remove any referenced file.
            await Task {
                let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowUploads")
                do {
                    _ = try await request(.uploadAttachment(.cancel(id: file.id)), hostID: hostID)
                    _ = try await request(.discardAttachments([file.id]), hostID: hostID)
                } catch { logger.debug("Could not clean up a workflow import: \(error.localizedDescription)") }
            }.value
        }
        return try result.get()
    }

    static func attachmentMediaType(for url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg",
             "jpeg": "image/jpeg"
        case "txt": "text/plain"
        case "md",
             "markdown": "text/markdown"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: throw AgentWorkflowError("Choose PNG, JPEG, TXT, Markdown, WAV, MP3, M4A, MP4 or MOV files.")
        }
    }

    func attachments(_ ids: [UUID], hostID: UUID) async throws -> [AgentWorkflowAttachment] {
        guard !ids.isEmpty else { return [] }
        let response = try await request(.attachments(ids), hostID: hostID)
        guard let attachments = response.attachments, attachments.map(\.id) == ids else {
            throw AgentWorkflowError("The Host returned incomplete attachment information.")
        }
        return attachments
    }

    private func uploadAcknowledgement(_ operation: AgentWorkflowAttachmentUpload, offset: Int, hostID: UUID) async throws {
        let response = try await request(.uploadAttachment(operation), hostID: hostID)
        guard response.uploadedOffset == offset, response.attachments == nil else {
            throw AgentWorkflowError("The Host returned an invalid attachment offset.")
        }
    }
}
