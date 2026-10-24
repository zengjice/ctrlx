import CtrlxNetworking
import Foundation

struct AgentWorkflowObservation: Sendable {
    var pluginID: String
    var processID: Int32
    var processRuntimeID: String
    var workspacePane: WorkspacePaneIdentity
    var paneID: String
    var conversationID: String
    var displayName: String
    var workingDirectory: String
    var capabilities: AgentWorkflowCapabilities?
    var readiness: AgentWorkflowReadiness
    var capabilityIssue: String? = nil

    func matchesProcess(_ instance: AgentWorkflowInstance) -> Bool {
        pluginID == instance.pluginID && processID == instance.processID
            && processRuntimeID == instance.processRuntimeID
            && workspacePane.isSamePane(as: instance.workspacePane)
    }

    func instance(hostID: UUID, id: UUID) -> AgentWorkflowInstance {
        .init(
            id: id,
            hostID: hostID,
            pluginID: pluginID,
            processID: processID,
            processRuntimeID: processRuntimeID,
            workspacePane: workspacePane,
            paneID: paneID,
            conversationID: conversationID,
            displayName: displayName,
            workingDirectory: workingDirectory,
            capabilities: capabilities,
            readiness: readiness,
            capabilityIssue: capabilityIssue
        )
    }
}

extension AgentWorkflowObservation {
    init(_ instance: AgentWorkflowInstance) {
        self.pluginID = instance.pluginID
        self.processID = instance.processID
        self.processRuntimeID = instance.processRuntimeID
        self.workspacePane = instance.workspacePane
        self.paneID = instance.paneID
        self.conversationID = instance.conversationID
        self.displayName = instance.displayName
        self.workingDirectory = instance.workingDirectory
        self.capabilities = instance.capabilities
        self.readiness = instance.readiness
        self.capabilityIssue = instance.capabilityIssue
    }
}

struct AgentWorkflowArchive: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let hostID: UUID
    var definitions: [AgentWorkflowDefinition] = []
    var instances: [AgentWorkflowInstance] = []
    var runs: [AgentWorkflowRun] = []
    var attachments: [AgentWorkflowAttachment]?
    var bridgeEvidence: [AgentWorkflowBridgeEvidence]?
}

/// Owns the single-Host ledger. Each mutation writes a complete atomic snapshot
/// before exposing it; no await can interleave a check and its committed change.
/// Terminal writes happen outside this actor, after the writing intent is saved.
actor AgentWorkflowStore {
    let fileURL: URL
    private let hostID: UUID
    private var archive: AgentWorkflowArchive?
    private var writeAuthorizations: [UUID: AgentWorkflowWriteAuthorization] = [:]
    let attachmentUploads = HostFileUploads()
    var pendingAttachments: [UUID: PendingAttachment] = [:]
    var busyAttachmentUploads: Set<UUID> = []
    var attachmentExpiry: Task<Void, Never>?
    var attachmentUploadsClosed = false

    init(fileURL: URL, hostID: UUID) {
        self.fileURL = fileURL
        self.hostID = hostID
    }

    func snapshot() throws -> AgentWorkflowArchive {
        try load()
    }

    /// Call only with a complete, verified process snapshot. Failed inspection
    /// must not be passed as an empty list (which means confirmed process exit).
    @discardableResult
    func reconcile(_ observations: [AgentWorkflowObservation]) throws -> [AgentWorkflowInstance] {
        let previous = try load()
        var updated = previous
        var paneIDs: Set<UUID> = []
        var processIDs: Set<Int32> = []
        for observation in observations {
            guard
                observation.processID > 1, !observation.processRuntimeID.isEmpty,
                !observation.pluginID.isEmpty, !observation.paneID.isEmpty,
                !observation.conversationID.isEmpty,
                paneIDs.insert(observation.workspacePane.paneID).inserted,
                processIDs.insert(observation.processID).inserted else {
                throw AgentWorkflowError("Cannot register ambiguous or unverified Agent processes.")
            }
        }
        updated.instances = observations.map { observation in
            let existing = updated.instances.first { observation.matchesProcess($0) }
            return observation.instance(hostID: hostID, id: existing?.id ?? UUID())
        }
        for index in updated.runs.indices where !updated.runs[index].status.isTerminal {
            let run = updated.runs[index]
            let changed = run.instances.contains { bound in
                !updated.instances.contains { bound.matchesBinding($0) && $0.readiness != .unavailable }
            }
            if changed {
                var execution = try AgentWorkflowExecution(validating: run)
                let unsupported = updated.instances.first { live in
                    live.capabilityIssue != nil && run.instances.contains { $0.matchesBinding(live) }
                }
                execution.pause(reason: unsupported?.capabilityIssue
                    ?? "An Agent's current identity is unavailable or changed. Verify it before continuing; bind replacements in a new run.")
                updated.runs[index] = execution.run
            }
        }
        if updated != previous {
            try commit(updated)
        }
        return updated.instances
    }

    @discardableResult
    func saveDefinition(_ definition: AgentWorkflowDefinition, expectedRevision: Int?) throws -> AgentWorkflowDefinition {
        var updated = try load()
        guard definition.hostID == hostID else { throw AgentWorkflowError("This workflow belongs to a different Host.") }
        try validateAttachments(definition.attachmentIDs, in: updated)
        let previousAttachments = updated.definitions.first { $0.id == definition.id }?.attachmentIDs ?? []
        var saved = definition
        if let index = updated.definitions.firstIndex(where: { $0.id == definition.id }) {
            guard expectedRevision == updated.definitions[index].revision else {
                throw AgentWorkflowError("Another Viewer changed this workflow. Reload before saving.")
            }
            saved.revision = updated.definitions[index].revision + 1
            try saved.validate()
            updated.definitions[index] = saved
        } else {
            guard expectedRevision == nil else { throw AgentWorkflowError("The workflow was deleted. Reload before saving.") }
            saved.revision = 1
            try saved.validate()
            updated.definitions.append(saved)
        }
        try commit(updated)
        cleanUnreferencedAttachments(previousAttachments.subtracting(saved.attachmentIDs))
        return saved
    }

    func deleteDefinition(id: UUID, expectedRevision: Int) throws {
        var updated = try load()
        guard
            let index = updated.definitions.firstIndex(where: { $0.id == id }),
            updated.definitions[index].revision == expectedRevision else {
            throw AgentWorkflowError("The workflow changed. Reload before deleting.")
        }
        let removed = updated.definitions.remove(at: index)
        try commit(updated)
        cleanUnreferencedAttachments(removed.attachmentIDs)
    }

    @discardableResult
    func start(definitionID: UUID, expectedRevision: Int, requestID: UUID, now: Date, authorizationExpiresAt: Date) throws -> AgentWorkflowRun {
        var updated = try load()
        if let existing = updated.runs.first(where: { $0.id == requestID }) {
            guard existing.definition.id == definitionID, existing.definition.revision == expectedRevision else {
                throw AgentWorkflowError("This request ID already belongs to a different workflow start.")
            }
            return existing
        }
        guard let definition = updated.definitions.first(where: { $0.id == definitionID }), definition.revision == expectedRevision else {
            throw AgentWorkflowError("The workflow changed. Reload before starting.")
        }
        try validateAttachments(definition.attachmentIDs, in: updated)
        let instanceIDs = Set(definition.nodes.map(\.agentInstanceID))
        let occupied = updated.runs.contains { run in
            !run.status.isTerminal && run.instances.contains { instanceIDs.contains($0.id) }
        }
        guard !occupied else { throw AgentWorkflowError("An Agent is already reserved by another active workflow.") }
        let instances = definition.nodes.compactMap { node in updated.instances.first { $0.id == node.agentInstanceID } }
        let execution = try AgentWorkflowExecution(
            definition: definition,
            instances: instances,
            id: requestID,
            now: now,
            authorizationExpiresAt: authorizationExpiresAt
        )
        updated.runs.append(execution.run)
        try commit(updated)
        return execution.run
    }

    @discardableResult
    func update(
        runID: UUID,
        expectedRevision: Int? = nil,
        _ transition: @Sendable (inout AgentWorkflowExecution) throws -> Void
    ) throws -> AgentWorkflowRun {
        var updated = try load()
        guard let index = updated.runs.firstIndex(where: { $0.id == runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        guard expectedRevision == nil || expectedRevision == updated.runs[index].revision else {
            throw AgentWorkflowError("The workflow run changed. Reload before applying this action.")
        }
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        try transition(&execution)
        let knownAttachments = Set((updated.attachments ?? []).map(\.id))
        guard execution.run.attachmentIDs.isSubset(of: knownAttachments) else {
            throw AgentWorkflowError("The workflow result references an attachment that was not imported.")
        }
        updated.runs[index] = execution.run
        try commit(updated)
        return execution.run
    }

    func authorizeWrite(_ invocation: AgentWorkflowInvocation) throws -> AgentWorkflowWriteAuthorization {
        let archive = try load()
        guard
            let run = archive.runs.first(where: { $0.id == invocation.delivery.runID }),
            run.status == .running, run.authorizationExpiresAt > Date(),
            run.invocations.contains(where: { $0.id == invocation.id && $0.status == .writing }),
            writeAuthorizations[invocation.id] == nil else {
            throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
        }
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: run.authorizationExpiresAt)
        writeAuthorizations[invocation.id] = authorization
        return authorization
    }

    func deleteRun(id: UUID, expectedRevision: Int) throws {
        var updated = try load()
        guard let index = updated.runs.firstIndex(where: { $0.id == id }), updated.runs[index].revision == expectedRevision else {
            throw AgentWorkflowError("The workflow run changed. Reload before deleting.")
        }
        guard updated.runs[index].status.isTerminal else { throw AgentWorkflowError("End the workflow before deleting its history.") }
        let removed = updated.runs.remove(at: index)
        try commit(updated)
        cleanUnreferencedAttachments(removed.attachmentIDs)
    }

    func load() throws -> AgentWorkflowArchive {
        if let archive {
            return archive
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = AgentWorkflowArchive(hostID: hostID)
            archive = empty
            return empty
        }
        var loaded = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fileURL))
        guard
            loaded.schemaVersion == 1, loaded.hostID == hostID,
            Set(loaded.definitions.map(\.id)).count == loaded.definitions.count,
            Set(loaded.runs.map(\.id)).count == loaded.runs.count,
            Set(loaded.instances.map(\.id)).count == loaded.instances.count else {
            throw AgentWorkflowError("The saved workflows belong to another Host or use an unsupported format.")
        }
        let attachments = loaded.attachments ?? []
        guard Set(attachments.map(\.id)).count == attachments.count else {
            throw AgentWorkflowError("The saved workflow attachments contain duplicate identities.")
        }
        try validateConversions(in: loaded)
        for definition in loaded.definitions {
            try definition.validate()
            guard definition.hostID == hostID else { throw AgentWorkflowError("A saved workflow belongs to another Host.") }
        }
        for index in loaded.instances.indices {
            guard loaded.instances[index].hostID == hostID else { throw AgentWorkflowError("A saved Agent belongs to another Host.") }
            loaded.instances[index].readiness = .unavailable
        }
        for index in loaded.runs.indices {
            guard loaded.runs[index].definition.hostID == hostID else { throw AgentWorkflowError("A saved run belongs to another Host.") }
            loaded.runs[index] = try AgentWorkflowExecution(restoring: loaded.runs[index]).run
        }
        try commit(loaded)
        return loaded
    }

    func commit(_ updated: AgentWorkflowArchive) throws {
        guard updated != archive else { return }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        archive = updated
        let writable = Set(updated.runs.filter { $0.status == .running }.flatMap {
            $0.invocations.filter { $0.status == .writing }.map(\.id)
        })
        for (id, authorization) in writeAuthorizations where !writable.contains(id) {
            authorization.revoke()
            writeAuthorizations.removeValue(forKey: id)
        }
    }
}
