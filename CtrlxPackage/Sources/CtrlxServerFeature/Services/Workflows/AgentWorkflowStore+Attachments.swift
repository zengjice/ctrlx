import CtrlxCommon
import CtrlxNetworking
import Foundation
import os

extension AgentWorkflowStore {
    struct PendingAttachment {
        let name: String
        let mediaType: String
        let size: Int
        let owner: ArtifactOwner?
        var activity = ContinuousClock.now
    }

    private static let attachmentLogger = Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowAttachments")

    private var attachmentsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
    }

    private func attachmentDirectory(_ id: UUID) -> URL {
        attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Run once before exposing the service. Unregistered UUID directories are
    /// partial transfers from a previous Host process; committed imports remain.
    func recoverAttachmentStorage() throws {
        guard pendingAttachments.isEmpty, busyAttachmentUploads.isEmpty else {
            throw AgentWorkflowError("Cannot recover attachment storage during an upload.")
        }
        let known = try Set((load().attachments ?? []).map(\.id))
        guard FileManager.default.fileExists(atPath: attachmentsDirectory.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: directory.lastPathComponent), !known.contains(id) else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }

    func attachmentMetadata(_ ids: [UUID]) throws -> [AgentWorkflowAttachment] {
        let archive = try load()
        guard ids.count <= AgentWorkflowWire.maximumAttachments else {
            throw AgentWorkflowError("Read up to 32 attachments at a time.")
        }
        return try ids.map { id in
            guard let item = archive.attachments?.first(where: { $0.id == id }) else {
                throw AgentWorkflowError("A workflow attachment is missing. Import it again before continuing.")
            }
            return item
        }
    }

    func validateAttachments(_ ids: Set<UUID>, in archive: AgentWorkflowArchive) throws {
        let available = Set((archive.attachments ?? []).map(\.id))
        guard ids.count <= AgentWorkflowWire.maximumAttachments, ids.isSubset(of: available) else {
            throw AgentWorkflowError("A workflow supports up to 32 imported attachments. Import missing files again before saving or starting.")
        }
    }

    func invocationAttachments(
        _ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance,
        status: AgentWorkflowInvocationStatus, now: Date
    ) throws -> [AgentWorkflowAttachmentFile] {
        let archive = try load()
        guard
            let run = archive.runs.first(where: { $0.id == invocation.delivery.runID }),
            !run.status.isTerminal,
            run.status == .running || status == .running,
            run.authorizationExpiresAt > now,
            let saved = run.invocations.first(where: { $0.id == invocation.id }),
            saved.status == status, saved.round == run.round, saved.delivery == invocation.delivery,
            let bound = run.instances.first(where: { $0.id == saved.delivery.toAgentID }),
            bound.matchesBinding(instance) else {
            throw AgentWorkflowError("This invocation is no longer authorized to read workflow attachments.")
        }
        return try attachmentFiles(saved.delivery.input.attachmentIDs, instance: instance)
    }

    func definitionAttachments(id: UUID, revision: Int) throws -> [AgentWorkflowAttachmentFile] {
        let archive = try load()
        guard let definition = archive.definitions.first(where: { $0.id == id && $0.revision == revision }) else {
            throw AgentWorkflowError("The workflow changed. Reload before starting.")
        }
        var files: [AgentWorkflowAttachmentFile] = []
        for node in definition.nodes {
            guard let instance = archive.instances.first(where: { $0.id == node.agentInstanceID }) else {
                throw AgentWorkflowError("An Agent is no longer available.")
            }
            let ids = node.input.attachmentIDs + (node.id == definition.entryNodeID ? definition.initialInput.attachmentIDs : [])
            files += try attachmentFiles(Array(Set(ids)), instance: instance)
        }
        var seen: Set<UUID> = []
        return files.filter { seen.insert($0.attachment.id).inserted }
    }

    private func attachmentFiles(_ ids: [UUID], instance: AgentWorkflowInstance) throws -> [AgentWorkflowAttachmentFile] {
        try attachmentMetadata(ids).map { attachment in
            guard
                let ext = Self.fileExtension(for: attachment.mediaType),
                instance.capabilities?.mediaTypes.contains(attachment.mediaType) == true else {
                throw AgentWorkflowError("\(instance.displayName) cannot read \(attachment.name) in its current format. Convert it before starting.")
            }
            return .init(attachment: attachment, url: attachmentDirectory(attachment.id).appendingPathComponent("content.\(ext)"))
        }
    }

    /// Paired operators can import files, but cannot choose a Host destination.
    /// Agents only receive the attachments named by their authorized invocation.
    func uploadAttachment(
        _ operation: AgentWorkflowAttachmentUpload, artifact: ArtifactUpload? = nil
    ) async throws -> (offset: Int, attachment: AgentWorkflowAttachment?) {
        try Task.checkCancellation()
        guard !attachmentUploadsClosed else { throw AgentWorkflowError("Workflow uploads are shutting down.") }
        let id = operation.id
        guard busyAttachmentUploads.insert(id).inserted else {
            throw AgentWorkflowError("An operation for this attachment is already in progress.")
        }
        defer { busyAttachmentUploads.remove(id) }
        // Reject another invocation (or an operator) before the cleanup scope.
        // Knowing an upload UUID must not let a caller cancel someone else's I/O.
        if let pending = pendingAttachments[id], pending.owner != artifact?.owner {
            throw AgentWorkflowError("This upload belongs to another caller.")
        }

        do {
            _ = try await authorizeArtifactUpload(artifact)
            if let existing = try load().attachments?.first(where: { $0.id == id }) {
                if let artifact, try !ownsArtifact(id, owner: artifact.owner) {
                    throw AgentWorkflowError("This invocation did not share that artifact.")
                }
                // A lost finish reply may be retried, but never overwrite a snapshot.
                if case let .finish(_, hash) = operation, hash == existing.sha256 {
                    return (Int(existing.byteCount), existing)
                }
                if case .cancel = operation {
                    return (0, nil)
                }
                throw AgentWorkflowError("This attachment has already been imported.")
            }
            switch operation {
            case let .begin(_, name, mediaType, size):
                guard
                    pendingAttachments[id] == nil, pendingAttachments.count < 4,
                    SessionDirectoryName.isValid(name), name.utf8.count <= 256,
                    !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                    let ext = Self.fileExtension(for: mediaType),
                    size > 0, size <= FileBrowserLimits.maximumUploadBytes else {
                    throw AgentWorkflowError("Choose a supported image, audio, video or text file up to 1 GiB. Wait for other uploads to finish.")
                }
                let directory = attachmentDirectory(id)
                // A caller-supplied UUID must not adopt a leftover partial file.
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw AgentWorkflowError("This upload identity was already used. Import the file again.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                pendingAttachments[id] = .init(name: name, mediaType: mediaType, size: size, owner: artifact?.owner)
                _ = try await attachmentUploads.request(.begin(id: id, directory: directory.path, name: "content.\(ext)", size: size))
                guard !attachmentUploadsClosed else { throw CancellationError() }
                _ = try await authorizeArtifactUpload(artifact)
                startAttachmentExpiry()
                return (0, nil)
            case let .append(_, offset, data):
                guard pendingAttachments[id] != nil, data.count <= AgentWorkflowWire.attachmentChunkBytes else {
                    throw AgentWorkflowError("The attachment upload expired or its chunk is too large.")
                }
                guard case let .uploaded(next, _) = try await attachmentUploads.request(.append(id: id, offset: offset, data: data)) else {
                    throw AgentWorkflowError("The Host could not acknowledge the attachment chunk.")
                }
                guard !attachmentUploadsClosed else { throw CancellationError() }
                _ = try await authorizeArtifactUpload(artifact)
                pendingAttachments[id]?.activity = .now
                return (next, nil)
            case let .finish(_, checksum):
                guard let pending = pendingAttachments[id] else {
                    throw AgentWorkflowError("The attachment upload expired. Import it again.")
                }
                _ = try await attachmentUploads.request(.finish(id: id, sha256: checksum))
                try Task.checkCancellation()
                guard !attachmentUploadsClosed else { throw CancellationError() }
                let timestamp = try await authorizeArtifactUpload(artifact)
                let attachment = AgentWorkflowAttachment(
                    id: id,
                    name: pending.name,
                    mediaType: pending.mediaType,
                    byteCount: Int64(pending.size),
                    sha256: checksum
                )
                // Reload after the I/O await; never overwrite concurrent run edits.
                var archive = try load()
                archive.attachments = (archive.attachments ?? []) + [attachment]
                if let artifact {
                    try recordArtifact(id, artifact: artifact, in: &archive, now: timestamp)
                }
                try commit(archive)
                pendingAttachments.removeValue(forKey: id)
                return (pending.size, attachment)
            case .cancel:
                await cancelAttachmentUpload(id)
                return (0, nil)
            }
        } catch {
            // Only delete a directory this upload created, never an existing file.
            await cancelAttachmentUpload(id)
            throw error
        }
    }

    func discardAttachments(_ ids: [UUID]) throws {
        guard ids.count <= AgentWorkflowWire.maximumAttachments else {
            throw AgentWorkflowError("Remove up to 32 unused attachments at a time.")
        }
        let archive = try load()
        let available = Set((archive.attachments ?? []).map(\.id))
        guard Set(ids).intersection(available).isSubset(of: removableAttachments(Set(ids), in: archive)) else {
            throw AgentWorkflowError("An attachment is still used by a workflow or run. Remove that reference first.")
        }
        try removeUnreferencedAttachments(Set(ids))
    }

    /// Persist removal of references first. A disk cleanup error must not undo a
    /// completed edit; retain its descriptor so cleanup can be retried explicitly.
    func cleanUnreferencedAttachments(_ candidates: Set<UUID>) {
        do { try removeUnreferencedAttachments(candidates) }
        catch { Self.attachmentLogger.error("Could not remove unused workflow attachments: \(error.localizedDescription)") }
    }

    func referencedAttachments(in archive: AgentWorkflowArchive) -> Set<UUID> {
        let direct = archive.definitions.reduce(into: Set<UUID>()) { $0.formUnion($1.attachmentIDs) }
            .union(archive.runs.reduce(into: Set<UUID>()) { $0.formUnion($1.attachmentIDs) })
        return direct.union((archive.attachments ?? []).filter { direct.contains($0.id) }.compactMap { $0.conversion?.sourceID })
    }

    private func removableAttachments(_ candidates: Set<UUID>, in archive: AgentWorkflowArchive) -> Set<UUID> {
        let items = archive.attachments ?? []
        let originals = items.filter { candidates.contains($0.id) }.compactMap { $0.conversion?.sourceID }
        let unused = candidates.union(originals).subtracting(referencedAttachments(in: archive))
        // Other imported conversions may belong to unsaved drafts. Preserve
        // their original even when no saved workflow currently references them.
        let retainedSources = items.filter { !unused.contains($0.id) }.compactMap { $0.conversion?.sourceID }
        return unused.subtracting(retainedSources)
    }

    private func removeUnreferencedAttachments(_ candidates: Set<UUID>) throws {
        var archive = try load()
        let unused = removableAttachments(candidates, in: archive)
        for attachment in archive.attachments ?? [] where unused.contains(attachment.id) {
            let directory = attachmentDirectory(attachment.id)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        archive.attachments?.removeAll { unused.contains($0.id) }
        try commit(archive)
    }

    private func startAttachmentExpiry() {
        guard attachmentExpiry == nil else { return }
        attachmentExpiry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let active = await self?.expireAttachmentUploads(), active else { return }
            }
        }
    }

    @discardableResult
    func expireAttachmentUploads(now: ContinuousClock.Instant = .now) async -> Bool {
        let expired = pendingAttachments.filter { now - $0.value.activity >= .seconds(60) && !busyAttachmentUploads.contains($0.key) }.map(\.key)
        for id in expired {
            busyAttachmentUploads.insert(id)
            await cancelAttachmentUpload(id)
            busyAttachmentUploads.remove(id)
        }
        if pendingAttachments.isEmpty {
            attachmentExpiry = nil
        }
        return !pendingAttachments.isEmpty
    }

    private func cancelAttachmentUpload(_ id: UUID) async {
        guard pendingAttachments.removeValue(forKey: id) != nil else { return }
        do {
            _ = try await attachmentUploads.request(.cancel(id: id))
        } catch { Self.attachmentLogger.error("Could not close an incomplete workflow upload: \(error.localizedDescription)") }
        do { try FileManager.default.removeItem(at: attachmentDirectory(id)) }
        catch { Self.attachmentLogger.error("Could not discard an incomplete workflow attachment: \(error.localizedDescription)") }
    }

    func shutdownAttachmentUploads() async {
        attachmentUploadsClosed = true
        attachmentExpiry?.cancel()
        attachmentExpiry = nil
        for id in Array(pendingAttachments.keys) where !busyAttachmentUploads.contains(id) {
            await cancelAttachmentUpload(id)
        }
        await attachmentUploads.shutdown()
    }

    private static func fileExtension(for mediaType: String) -> String? {
        switch mediaType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "audio/wav",
             "audio/x-wav": "wav"
        case "audio/mpeg": "mp3"
        case "audio/mp4",
             "audio/x-m4a": "m4a"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "text/plain",
             "text/markdown": "txt"
        default: nil
        }
    }
}
