import CtrlxNetworking
import Foundation

extension AgentWorkflowStore {
    /// Only paired operator requests can confirm a conversion. Its source is
    /// retained, but is not silently added to an Agent's readable input.
    func linkConversion(sourceID: UUID, outputs: [AgentWorkflowConversionOutput]) throws -> [AgentWorkflowAttachment] {
        var archive = try load()
        guard
            !outputs.isEmpty, outputs.count <= AgentWorkflowWire.maximumAttachments,
            Set(outputs.map(\.attachmentID)).count == outputs.count,
            let source = archive.attachments?.first(where: { $0.id == sourceID }), source.conversion == nil,
            source.mediaType.hasPrefix("audio/") || source.mediaType.hasPrefix("video/"),
            outputs.allSatisfy({ $0.attachmentID != sourceID && !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.description.utf8.count <= 512 }) else {
            throw AgentWorkflowError("Choose an imported audio/video source and up to 32 distinct conversion outputs with descriptions up to 512 UTF-8 bytes.")
        }
        let referenced = referencedAttachments(in: archive)
        var linked: [AgentWorkflowAttachment] = []
        for output in outputs {
            guard
                let index = archive.attachments?.firstIndex(where: { $0.id == output.attachmentID }),
                let item = archive.attachments?[index],
                ["image/png", "image/jpeg", "text/plain", "text/markdown"].contains(item.mediaType) else {
                throw AgentWorkflowError("A conversion output is missing or is not an image or text file.")
            }
            let conversion = AgentWorkflowAttachmentConversion(
                sourceID: sourceID, sourceName: source.name, sourceSHA256: source.sha256,
                description: output.description
            )
            if let existing = item.conversion {
                guard existing == conversion else { throw AgentWorkflowError("An attachment's conversion source cannot be replaced.") }
                linked.append(item)
                continue
            }
            guard !referenced.contains(item.id) else {
                throw AgentWorkflowError("This output is already used by a workflow. Import a new conversion before changing its source.")
            }
            let updated = AgentWorkflowAttachment(
                id: item.id, name: item.name, mediaType: item.mediaType,
                byteCount: item.byteCount, sha256: item.sha256, conversion: conversion
            )
            archive.attachments?[index] = updated
            linked.append(updated)
        }
        try commit(archive)
        return linked
    }

    func validateConversions(in archive: AgentWorkflowArchive) throws {
        let items = archive.attachments ?? []
        for item in items {
            guard let conversion = item.conversion else { continue }
            guard
                ["image/png", "image/jpeg", "text/plain", "text/markdown"].contains(item.mediaType),
                !conversion.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                conversion.description.utf8.count <= 512,
                let source = items.first(where: { $0.id == conversion.sourceID }), source.id != item.id,
                source.conversion == nil, source.sha256 == conversion.sourceSHA256, source.name == conversion.sourceName,
                source.mediaType.hasPrefix("audio/") || source.mediaType.hasPrefix("video/") else {
                throw AgentWorkflowError("A saved media conversion has lost its original source.")
            }
        }
    }
}
