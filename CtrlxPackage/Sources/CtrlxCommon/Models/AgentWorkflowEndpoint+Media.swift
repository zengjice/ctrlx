import CtrlxNetworking
import Foundation
import os

struct AgentWorkflowImportedMedia: Sendable {
    let original: AgentWorkflowAttachment
    let outputs: [AgentWorkflowAttachment]
}

extension AgentWorkflowEndpoint {
    func importMedia(
        source: AgentWorkflowMediaSource, outputs: [AgentWorkflowMediaOutput], hostID: UUID,
        progress: @MainActor (String, Double) -> Void
    ) async throws -> AgentWorkflowImportedMedia {
        guard !outputs.isEmpty, outputs.count < AgentWorkflowWire.maximumAttachments else {
            throw AgentWorkflowError("Choose up to 31 conversion outputs.")
        }
        var imported: [AgentWorkflowAttachment] = []
        do {
            func upload(_ url: URL, type: String) async throws -> AgentWorkflowAttachment {
                try await importAttachment(from: url, mediaType: type, hostID: hostID) { sent, total in
                    progress(url.lastPathComponent, total > 0 ? Double(sent) / Double(total) : 0)
                }
            }
            let original = try await upload(source.url, type: source.mediaType)
            imported.append(original)
            guard original.sha256 == source.sha256 else { throw AgentWorkflowError("The media original changed after conversion. Convert it again.") }
            for output in outputs {
                try Task.checkCancellation()
                try imported.append(await upload(output.url, type: output.mediaType))
            }
            let descriptions = zip(imported.dropFirst(), outputs).map {
                AgentWorkflowConversionOutput(attachmentID: $0.id, description: $1.description)
            }
            let response = try await request(.linkConversion(sourceID: original.id, outputs: descriptions), hostID: hostID)
            let expected = zip(imported.dropFirst(), outputs).map { item, output in
                AgentWorkflowAttachment(
                    id: item.id,
                    name: item.name,
                    mediaType: item.mediaType,
                    byteCount: item.byteCount,
                    sha256: item.sha256,
                    conversion: .init(sourceID: original.id, sourceName: original.name, sourceSHA256: original.sha256, description: output.description)
                )
            }
            guard response.attachments == expected else { throw AgentWorkflowError("The Host returned an invalid conversion receipt.") }
            try Task.checkCancellation()
            return .init(original: original, outputs: expected)
        } catch {
            let ids = imported.map(\.id)
            await Task {
                do {
                    if !ids.isEmpty {
                        _ = try await request(.discardAttachments(ids), hostID: hostID)
                    }
                } catch { Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowUploads").error("Could not clean up converted media: \(error.localizedDescription)") }
            }.value
            throw error
        }
    }
}
