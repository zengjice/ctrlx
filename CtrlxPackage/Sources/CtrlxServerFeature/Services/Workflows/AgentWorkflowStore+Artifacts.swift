import CtrlxNetworking
import Foundation

extension AgentWorkflowStore {
    struct ArtifactOwner: Equatable, Sendable {
        let runID: UUID
        let invocationID: UUID
        let instanceID: UUID
    }

    struct ArtifactUpload: Sendable {
        let owner: ArtifactOwner
        let instance: AgentWorkflowInstance
        /// Reinspect the live process after disk I/O, then return the current time.
        let verifyInstance: @Sendable () async throws -> Date
    }

    func authorizeArtifactUpload(_ artifact: ArtifactUpload?) async throws -> Date {
        guard let artifact else { return .now }
        let now = try await artifact.verifyInstance()
        guard !attachmentUploadsClosed, artifact.owner.instanceID == artifact.instance.id else {
            throw AgentWorkflowError("The artifact upload is no longer available.")
        }
        let archive = try load()
        guard let run = archive.runs.first(where: { $0.id == artifact.owner.runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        try AgentWorkflowExecution(validating: run).authorizeArtifact(
            invocationID: artifact.owner.invocationID, instance: artifact.instance, now: now
        )
        return now
    }

    func recordArtifact(_ id: UUID, artifact: ArtifactUpload, in archive: inout AgentWorkflowArchive, now: Date) throws {
        guard let index = archive.runs.firstIndex(where: { $0.id == artifact.owner.runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        var execution = try AgentWorkflowExecution(validating: archive.runs[index])
        try execution.shareArtifact(id, invocationID: artifact.owner.invocationID, instance: artifact.instance, now: now)
        archive.runs[index] = execution.run
    }

    func ownsArtifact(_ id: UUID, owner: ArtifactOwner) throws -> Bool {
        try load().runs.first(where: { $0.id == owner.runID })?
            .invocations.first(where: { $0.id == owner.invocationID })?
            .sharedAttachmentIDs?.contains(id) == true
    }
}
