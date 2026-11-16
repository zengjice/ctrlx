import CryptoKit
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieInteractionMigrationTests {
    @Test(arguments: [false, true], [false, true])
    func referencedSingleReplyMigratesOnceAndKeepsEditedDefinitions(edited: Bool, prepared: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let ledger = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("ledger.json"), hostID: f.hostID)
        let instance = try #require(await ledger.reconcile(f.observations).first)
        let id = UUID()
        let node = AgentWorkflowNode(name: "Reply", agentInstanceID: instance.id)
        let definition = try await ledger.saveDefinition(.init(id: id, name: "Orbie", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "original")), expectedRevision: nil)
        _ = try await ledger.start(definitionID: id, expectedRevision: 1, requestID: id, now: Date(), authorizationExpiresAt: Date().addingTimeInterval(300))
        if prepared {
            _ = try await ledger.update(runID: id) { execution in _ = try execution.prepareInvocation(nodeID: node.id, now: Date()) }
        }
        if edited {
            var changed = definition
            changed.name = "My edited workflow"
            _ = try await ledger.saveDefinition(changed, expectedRevision: 1)
        }
        let ordinaryID = UUID()
        _ = try await ledger.saveDefinition(.init(id: ordinaryID, name: "Orbie", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id), expectedRevision: nil)
        let store = OrbieStore(paths: f.paths, hostID: f.hostID)
        var record = try await store.load()
        record.legacyRunIDs = [id]
        record.legacyPendingRunID = id
        try await store.save(record)
        let orbiters = OrbiterStore(paths: f.paths, hostID: f.hostID)
        try await OrbieInteractionMigration.migrate(orbie: store, orbiters: orbiters, workflows: ledger, messages: f.interaction.store)
        try await OrbieInteractionMigration.migrate(orbie: store, orbiters: orbiters, workflows: ledger, messages: f.interaction.store)
        #expect(try await store.load().messageIDs == [id])
        #expect(try await f.interaction.store.message(id)?.status == .cancelled)
        #expect(try await ledger.snapshot().runs.isEmpty)
        #expect(try await ledger.snapshot().definitions.count == (edited ? 2 : 1))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("ledger.json.pre-3fix.backup").path))
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test(arguments: [AgentWorkflowInvocationStatus.writing, .awaitingAcceptance, .running, .succeeded])
    func interruptedMigrationRetainsNativeEvidenceWithoutReplaying(status: AgentWorkflowInvocationStatus) async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let ledger = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("ledger.json"), hostID: f.hostID)
        let instance = try #require(await ledger.reconcile(f.observations).first)
        let id = UUID(), node = AgentWorkflowNode(name: "Reply", agentInstanceID: instance.id)
        _ = try await ledger.saveDefinition(.init(id: id, name: "Orbie", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "old input")), expectedRevision: nil)
        _ = try await ledger.start(definitionID: id, expectedRevision: 1, requestID: id, now: Date(), authorizationExpiresAt: Date().addingTimeInterval(300))
        _ = try await ledger.update(runID: id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: node.id, now: Date())
            try execution.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            if status != .writing {
                try execution.didWrite(invocationID: invocation.id)
            }
            if status == .running || status == .succeeded {
                try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "native-turn", transcriptPath: "/verified/native/transcript")
            }
            if status == .succeeded {
                _ = try execution.succeed(.init(invocationID: invocation.id, nativeTurnID: "native-turn", text: "Verified answer", completedAt: Date()), instance: instance, now: Date())
            }
        }
        let store = OrbieStore(paths: f.paths, hostID: f.hostID)
        var record = try await store.load()
        record.legacyRunIDs = [id]
        try await store.save(record)
        let orbiters = OrbiterStore(paths: f.paths, hostID: f.hostID)
        let blocked = f.root.appendingPathComponent("blocked-messages")
        try Data("not a directory".utf8).write(to: blocked)
        await #expect(throws: (any Error).self) {
            try await OrbieInteractionMigration.migrate(orbie: store, orbiters: orbiters, workflows: ledger, messages: AgentMessageStore(directory: blocked))
        }
        #expect(try await ledger.snapshot().runs.count == 1)
        #expect(try await store.load().legacyRunIDs == [id])
        for _ in 0..<2 {
            try await OrbieInteractionMigration.migrate(orbie: store, orbiters: orbiters, workflows: ledger, messages: f.interaction.store)
        }
        let message = try #require(await f.interaction.store.message(id))
        #expect(message.status == status && message.instance == instance)
        #expect(message.answer == (status == .succeeded ? "Verified answer" : nil))
        #expect(message.nativeEvent?.nativeTurnID == ((status == .running || status == .succeeded) ? "native-turn" : nil))
        #expect(try await store.load().messageIDs == [id])
        #expect(try await ledger.snapshot().runs.isEmpty && f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func legacyTasksMergeOnlyTheSameAgentAndRetainDraftsMaterialsAndCreationIntent() async throws {
        let f = try await AgentInteractionTestSupport()
        _ = try f.create(UUID(), pluginID: "codex", title: "Expert", directory: f.root.path)
        let instance = try #require(await f.catalog.snapshot(refresh: true).first)
        var old = LegacyOrbiterIndex(hostID: f.hostID)
        for index in 0..<3 {
            old.tasks.append(.init(id: UUID(), title: "Same title", createdAt: Date(), goal: "Goal", source: "Source", materials: "Materials", directory: f.root.path, origin: .newAgent, pluginID: "codex", providerID: nil, forkSource: nil, pane: index < 2 ? instance.workspacePane : nil, binding: index < 2 ? instance : nil, runIDs: [UUID()], draft: "draft \(index)", archived: index == 1))
        }
        try FileManager.default.createDirectory(at: f.paths.orbieStateRoot, withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(old)
        try original.write(to: f.paths.orbiterIndex)
        let store = OrbiterStore(paths: f.paths, hostID: f.hostID)
        let converted = try await store.load()
        #expect(converted.agents.count == 2)
        let merged = try #require(converted.agents.first { $0.agentID == instance.agentID })
        #expect(merged.materialsDirectories.count == 2 && merged.legacyRunIDs?.count == 2)
        #expect(merged.draft.contains("draft 0") && merged.draft.contains("draft 1"))
        #expect(converted.agents.last?.creation?.id == old.tasks[2].id && converted.agents.last?.agentID == nil)
        try await store.save(converted)
        #expect(try await store.load() == converted)
        #expect(try Data(contentsOf: f.paths.orbiterIndex.appendingPathExtension("pre-3fix.backup")) == original)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func pendingAssociationWithoutStartedRunKeepsAttachmentAfterOriginalDeletion() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let ledger = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("ledger.json"), hostID: f.hostID)
        let instance = try #require(await ledger.reconcile(f.observations).first)
        let data = Data([1, 2, 3]), attachmentID = UUID(), id = UUID()
        _ = try await ledger.uploadAttachment(.begin(id: attachmentID, name: "selected.png", mediaType: "image/png", size: data.count))
        _ = try await ledger.uploadAttachment(.append(id: attachmentID, offset: 0, data: data))
        _ = try await ledger.uploadAttachment(.finish(id: attachmentID, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let node = AgentWorkflowNode(name: "Reply", agentInstanceID: instance.id)
        _ = try await ledger.saveDefinition(.init(
            id: id,
            name: "Original",
            hostID: f.hostID,
            nodes: [node],
            edges: [],
            entryNodeID: node.id,
            initialInput: .init(text: "Never submitted", attachmentIDs: [attachmentID])
        ), expectedRevision: nil)
        let store = OrbieStore(paths: f.paths, hostID: f.hostID)
        var record = try await store.load()
        record.legacyPendingRunID = id
        record.draft = "Newer draft"
        try await store.save(record)
        let orbiters = OrbiterStore(paths: f.paths, hostID: f.hostID)
        for _ in 0..<2 {
            try await OrbieInteractionMigration.migrate(orbie: store, orbiters: orbiters, workflows: ledger, messages: f.interaction.store)
        }
        let message = try #require(await f.interaction.store.message(id))
        #expect(message.status == .cancelled && message.text == "Never submitted")
        #expect(try await store.load().draft == "Newer draft")
        #expect(try await store.load().messageIDs == [id])
        try await ledger.discardAttachments([attachmentID])
        let copy = try #require(message.attachments?.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.path)) == data)
        #expect(try await ledger.snapshot().definitions.isEmpty)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }
}
