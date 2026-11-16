import CtrlxNetworking
import Foundation

/// Reentrant copy-then-switch. Only IDs saved by the old product association and
/// the exact generated single-reply shape authorize removal from Workflows.
enum OrbieInteractionMigration {
    static func migrate(orbie: OrbieStore, orbiters: OrbiterStore, workflows: AgentWorkflowStore, messages: AgentMessageStore) async throws {
        var main = try await orbie.load()
        var index = try await orbiters.load()
        if let pending = main.legacyPendingRunID, main.legacyRunIDs?.contains(pending) != true {
            main.legacyRunIDs = (main.legacyRunIDs ?? []) + [pending]
        }
        let ids = Set((main.legacyRunIDs ?? []) + [main.legacyPendingRunID].compactMap { $0 } + index.agents.flatMap { $0.legacyRunIDs ?? [] })
        guard !ids.isEmpty else { return }
        let archive = try await workflows.snapshot()
        try await workflows.backupForInteractionMigration()
        var seen = Set<AgentID>()
        let knownInstances = (archive.instances + [main.binding].compactMap { $0 } + index.agents.compactMap(\.binding))
            .filter { seen.insert($0.agentID).inserted }
        var migrated = Set<UUID>()
        for id in ids {
            if try await messages.message(id) != nil {
                migrated.insert(id)
                continue
            }
            guard let run = archive.runs.first(where: { $0.id == id }) else {
                if
                    let definition = archive.definitions.first(where: { $0.id == id }), isLegacyDefinition(definition),
                    let node = definition.nodes.first,
                    let instance = definition.instance(for: node.agentInstanceID, in: knownInstances) {
                    var message = AgentMessage(id: id, instance: instance, text: definition.initialInput.text)
                    message.status = .cancelled
                    message.issue = "This old message was not started. Its text is retained for an explicit send."
                    message.attachments = try await messages.copyAttachments(workflows.interactionMigrationAttachments(definition.attachmentIDs), messageID: id)
                    try await messages.importMessage(message)
                    migrated.insert(id)
                }
                continue
            }
            guard isLegacyInteraction(run) else { continue }
            let invocation = run.invocations.first
            guard let instance = invocation?.instance ?? run.instances.first else { continue }
            var message = AgentMessage(id: id, instance: instance, text: run.definition.initialInput.text, now: run.createdAt)
            message.prompt = invocation?.submissionText(pluginID: instance.pluginID) ?? message.prompt
            message.status = invocation?.status == .pending || invocation == nil ? .cancelled : (invocation?.status ?? .cancelled)
            message.issue = message.status == .cancelled ? "This old message was never sent. Its draft was retained for an explicit send." : invocation?.issue
            if let nativeTurnID = invocation?.nativeTurnID, let path = invocation?.nativeTranscriptPath {
                message.nativeEvent = .init(
                    kind: invocation?.result == nil ? .submitted : .stopCandidate,
                    nativeTurnID: nativeTurnID,
                    transcriptPath: path,
                    text: invocation?.result?.text ?? message.prompt
                )
            }
            if
                invocation?.status == .succeeded, let result = invocation?.result,
                result.invocationID == invocation?.id, result.nativeTurnID == invocation?.nativeTurnID, result.nativeTurnID != nil {
                message.answer = result.text
                message.completedAt = result.completedAt
            } else if invocation?.status == .succeeded {
                message.status = .uncertain
                message.issue = "The old reply has insufficient native evidence. Check the original conversation."
            }
            message.attachments = try await messages.copyAttachments(workflows.interactionMigrationAttachments(run.attachmentIDs), messageID: id)
            try await messages.importMessage(message)
            migrated.insert(id)
        }
        // Saving the associations comes before detaching any original record.
        // On interruption, immutable message IDs make another pass idempotent.
        for id in main.legacyRunIDs ?? [] where migrated.contains(id) && !main.messageIDs.contains(id) {
            main.messageIDs.append(id)
        }
        try await orbie.save(main)
        for i in index.agents.indices {
            for id in index.agents[i].legacyRunIDs ?? [] where migrated.contains(id) && !index.agents[i].messageIDs.contains(id) {
                index.agents[i].messageIDs.append(id)
            }
        }
        try await orbiters.save(index)
        try await workflows.detachLegacyInteractions(migrated)
        main.legacyRunIDs?.removeAll { migrated.contains($0) }
        if let pending = main.legacyPendingRunID, migrated.contains(pending) {
            main.legacyPendingRunID = nil
        }
        for i in index.agents.indices {
            index.agents[i].legacyRunIDs?.removeAll { migrated.contains($0) }
        }
        try await orbie.save(main)
        try await orbiters.save(index)
    }

    static func isLegacyInteraction(_ run: AgentWorkflowRun) -> Bool {
        isLegacyDefinition(run.definition) && run.id == run.definition.id && run.invocations.count <= 1
            && run.invocations.allSatisfy { $0.nodeID == run.definition.entryNodeID && $0.round == 1 }
    }

    static func isLegacyDefinition(_ definition: AgentWorkflowDefinition) -> Bool {
        guard
            definition.revision == 1, definition.nodes.count == 1,
            definition.edges.isEmpty, definition.loop == nil, definition.creationSession == nil,
            let node = definition.nodes.first, node.kind == .agent,
            node.id == definition.entryNodeID, node.initialTask == nil, node.completion == .replyEnded,
            node.modelSelection == nil,
            node.input.text.isEmpty || node.input.text.hasPrefix("CtrlX provides read-only task lookup for this Orbie process:") else { return false }
        return true
    }
}

extension AgentWorkflowStore {
    func backupForInteractionMigration() throws {
        _ = try load()
        let backup = fileURL.appendingPathExtension("pre-3fix.backup")
        if FileManager.default.fileExists(atPath: fileURL.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    func detachLegacyInteractions(_ ids: Set<UUID>) throws {
        var archive = try load()
        let verified = archive.runs.filter { ids.contains($0.id) && OrbieInteractionMigration.isLegacyInteraction($0) }
        let removed = Set(verified.map(\.id))
        archive.runs.removeAll { removed.contains($0.id) }
        archive.definitions.removeAll { definition in
            (verified.contains { $0.definition == definition }
                || (ids.contains(definition.id) && OrbieInteractionMigration.isLegacyDefinition(definition)))
                && !archive.runs.contains { $0.definition.id == definition.id }
        }
        archive.retainedRunIDs?.removeAll { removed.contains($0) }
        try commit(archive)
    }
}
