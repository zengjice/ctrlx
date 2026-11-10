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
    var schemaVersion = 6
    let hostID: UUID
    var definitions: [AgentWorkflowDefinition] = []
    var instances: [AgentWorkflowInstance] = []
    var runs: [AgentWorkflowRun] = []
    var attachments: [AgentWorkflowAttachment]?
    var bridgeEvidence: [AgentWorkflowBridgeEvidence]?
}

struct AgentWorkflowCatalogChanged: LocalizedError, Sendable {
    var errorDescription: String? {
        "An Agent's conversation was confirmed during inspection. Refresh the Agent list."
    }
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

    func hasAskedQuestion(for instance: AgentWorkflowInstance) throws -> Bool {
        try load().runs.contains { $0.hasAskedQuestion(for: instance) }
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
                !observation.conversationID.isEmpty || observation.pluginID == "codex",
                paneIDs.insert(observation.workspacePane.paneID).inserted,
                processIDs.insert(observation.processID).inserted else {
                throw AgentWorkflowError("Cannot register ambiguous or unverified Agent processes.")
            }
        }
        updated.instances = try observations.map { observation in
            let existing = previous.instances.first { observation.matchesProcess($0) }
            // Readiness was checked against the old join key. Reinspect instead
            // of combining a confirmed conversation with that stale result.
            if observation.conversationID.isEmpty, let existing, !existing.conversationID.isEmpty {
                throw AgentWorkflowCatalogChanged()
            }
            return observation.instance(hostID: hostID, id: existing?.id ?? UUID())
        }
        for index in updated.runs.indices where !updated.runs[index].status.isTerminal {
            let run = updated.runs[index]
            let execution = try AgentWorkflowExecution(validating: run)
            let changed = run.instances.contains { bound in
                !updated.instances.contains {
                    (bound.matchesBinding($0) || execution.canBindFirstConversation($0)) && $0.readiness != .unavailable
                }
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
    func start(definitionID: UUID, expectedRevision: Int, requestID: UUID, now: Date, authorizationExpiresAt: Date, initialInput: AgentWorkflowInput? = nil) throws -> AgentWorkflowRun {
        var updated = try load()
        if let existing = updated.runs.first(where: { $0.id == requestID }) {
            guard
                existing.definition.id == definitionID, existing.definition.revision == expectedRevision,
                initialInput == nil || initialInput == existing.definition.initialInput else {
                throw AgentWorkflowError("This request ID already belongs to a different workflow start.")
            }
            return existing
        }
        guard var definition = updated.definitions.first(where: { $0.id == definitionID }), definition.revision == expectedRevision else {
            throw AgentWorkflowError("The workflow changed. Reload before starting.")
        }
        if let initialInput {
            definition.initialInput = initialInput
        }
        try AgentWorkflowWire.validate(definition)
        try validateAttachments(definition.attachmentIDs, in: updated)
        let instanceIDs = definition.agentInstanceIDs
        let conflicts = updated.runs.compactMap { run -> AgentWorkflowStartRejection.Conflict? in
            guard !run.status.isTerminal else { return nil }
            let agents = run.instances.filter { instanceIDs.contains($0.id) }
            guard !agents.isEmpty else { return nil }
            return .init(run: .init(run), agentNames: agents.map(\.displayName))
        }
        guard conflicts.isEmpty else {
            throw AgentWorkflowStartRejection("These Agents already belong to an unfinished workflow.", conflicts: conflicts)
        }
        let instances = definition.agents.compactMap { participant in
            instanceIDs.contains(participant.id) ? updated.instances.first { $0.id == participant.id } : nil
        }
        let execution = try AgentWorkflowExecution(
            definition: definition,
            instances: instances,
            id: requestID,
            now: now,
            authorizationExpiresAt: authorizationExpiresAt
        )
        // Check Agent support after readiness so a missing capability is not
        // misreported as an unsupported image. No run has been committed yet.
        try validateStartAttachments(definition, instances: instances)
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

    func authorizeWrite(_ invocation: AgentWorkflowInvocation, numberOfWrites: Int = 1) throws -> AgentWorkflowWriteAuthorization {
        let archive = try load()
        guard
            let run = archive.runs.first(where: { $0.id == invocation.delivery.runID }),
            run.status == .running, run.authorizationExpiresAt > Date(),
            run.invocations.contains(where: { $0.id == invocation.id && $0.status == .writing }),
            writeAuthorizations[invocation.id] == nil,
            (1...(AgentWorkflowWire.maximumAttachments + 1)).contains(numberOfWrites) else {
            throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
        }
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: run.authorizationExpiresAt, numberOfWrites: numberOfWrites)
        writeAuthorizations[invocation.id] = authorization
        return authorization
    }

    func modelSelection(for invocation: AgentWorkflowInvocation) throws -> AgentModelSelection? {
        guard
            let run = try load().runs.first(where: { $0.id == invocation.delivery.runID }),
            let stored = run.invocations.first(where: { $0.id == invocation.id }), stored.delivery == invocation.delivery,
            let node = run.definition.nodes.first(where: { $0.id == stored.nodeID }) else {
            throw AgentWorkflowError("The workflow step no longer exists.")
        }
        return node.modelSelection
    }

    func isStagingInput(for instance: AgentWorkflowInstance) throws -> Bool {
        try load().runs.contains { run in
            guard run.status == .running else { return false }
            let execution = try AgentWorkflowExecution(validating: run)
            return run.instances.contains { $0.matchesBinding(instance) || execution.canBindFirstConversation(instance) }
                && run.invocations.contains { $0.delivery.toAgentID == instance.id && $0.status == .writing && writeAuthorizations[$0.id]?.isStaging == true }
        }
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

    func allowsInitialConversationBinding(for instance: AgentWorkflowInstance) throws -> Bool {
        try !load().runs.contains { run in
            !run.status.isTerminal && run.instances.contains(where: { $0.matchesProcess(instance) })
                && run.invocations.contains { $0.delivery.toAgentID == instance.id && $0.nativeTurnID != nil }
        }
    }

    /// Commit the verified first receipt and its catalog join key together.
    func accept(runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, transcriptPath: String?, bindFirstConversation: Bool) throws {
        var updated = try load()
        guard let index = updated.runs.firstIndex(where: { $0.id == runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        try execution.accept(invocationID: invocationID, instance: instance, nativeTurnID: nativeTurnID, transcriptPath: transcriptPath, bindFirstConversation: bindFirstConversation)
        updated.runs[index] = execution.run
        if bindFirstConversation, let catalog = updated.instances.firstIndex(where: { $0.matchesProcess(instance) }) {
            updated.instances[catalog].conversationID = instance.conversationID
        }
        try commit(updated)
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
            (1...6).contains(loaded.schemaVersion), loaded.hostID == hostID,
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
            if loaded.schemaVersion < 4 {
                // Agent output sharing was removed. Discard its old references,
                // preserving input images, content outputs and native turn evidence.
                for invocationIndex in loaded.runs[index].invocations.indices {
                    let invocation = loaded.runs[index].invocations[invocationIndex]
                    guard
                        loaded.runs[index].definition.nodes.first(where: { $0.id == invocation.nodeID })?.kind == .agent,
                        let result = invocation.result, !result.attachmentIDs.isEmpty else { continue }
                    loaded.runs[index].invocations[invocationIndex].result = .init(
                        id: result.id, invocationID: result.invocationID, nativeTurnID: result.nativeTurnID,
                        text: result.text, completedAt: result.completedAt
                    )
                }
            }
            loaded.runs[index] = try AgentWorkflowExecution(restoring: loaded.runs[index]).run
        }
        loaded.schemaVersion = 6
        try commit(loaded)
        return loaded
    }

    func commit(_ updated: AgentWorkflowArchive) throws {
        var updated = updated
        updated.schemaVersion = 6
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

extension AgentWorkflowRun {
    func hasAskedQuestion(for instance: AgentWorkflowInstance) -> Bool {
        !status.isTerminal && instances.contains { $0.matchesBinding(instance) }
            && invocations.contains {
                $0.delivery.toAgentID == instance.id && $0.hasAskedQuestion == true
                    && [.writing, .awaitingAcceptance, .running].contains($0.status)
            }
    }
}
