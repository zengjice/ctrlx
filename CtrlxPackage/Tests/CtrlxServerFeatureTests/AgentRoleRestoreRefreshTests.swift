import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRoleRestoreRefreshTests {
    @Test(arguments: ["closed", "conversation", "paneLookup"])
    func failedRecoveryDoesNotBlockOtherOrbiters(fault: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let source = await f.orbie()
        try await source.create(pluginID: "codex", providerID: nil)
        let original = try #require(source.instance)
        var service = await f.orbiters()
        let failedKey = try await service.associate(original)
        let healthyPane = try f.create(UUID(), pluginID: "codex", title: "Healthy", directory: f.root.path)
        let healthy = try #require(try await f.catalog.snapshot(refresh: true).first { $0.workspacePane == healthyPane })
        let healthyKey = try await service.associate(healthy)
        f.observations.removeAll { $0.workspacePane == original.workspacePane }
        let token = UUID()
        let destination = try f.create(token, pluginID: "codex", title: "Recovery", directory: f.root.path)
        let fixed = LockIsolated(false)
        let descriptor = AgentResumeDescriptor(pluginID: original.pluginID, sessionID: original.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        let file = f.root.appendingPathComponent("resume.json")
        let entry = AgentRoleRecovery.Entry(agentID: original.agentID, descriptor: descriptor, intent: .init(id: token, attempted: true, pane: destination, inPlace: false))
        try JSONEncoder().encode([entry]).write(to: file)
        let recovery = AgentRoleRecovery(file: file, paneExists: { id in
            if id == original.agentID, fault == "paneLookup", !fixed.value {
                throw AgentWorkflowError("Cannot inspect this recovery terminal")
            }
            return await f.observations.contains { $0.workspacePane.paneID == id.paneID }
        }, launch: { _, _ in
            Issue.record("Refresh must not launch another recovery terminal")
            throw CancellationError()
        }, locate: { _ in destination }, inspect: { pane, saved in
            if fault == "closed", !fixed.value {
                throw AgentWorkflowError("Recovery terminal closed")
            }
            var live = try await f.catalog.snapshot(refresh: true).first { $0.workspacePane == pane }
            if fixed.value {
                live?.conversationID = saved.sessionID
            }
            return live
        })
        service = await f.orbiters(recovery: recovery)
        let failed = try #require(service.agents.first { $0.id == failedKey })
        let issue = try #require(service.recoveryIssues[original.agentID])
        #expect(service.issue == nil)
        #expect(service.availability(failed) == issue && service.currentInstance(failed) == nil)
        #expect(try service.availability(#require(service.agents.first { $0.id == healthyKey })) == nil)
        service.drafts[failedKey] = "Do not send to the failed Agent"
        await #expect(throws: AgentWorkflowError.self) { try await service.send(failedKey) }
        #expect(f.writes.isEmpty && service.drafts[failedKey] == "Do not send to the failed Agent")
        service.drafts[healthyKey] = "Healthy Agent input"
        try await service.send(healthyKey)
        #expect(f.writes.count == 1 && f.writes[0].contains("Healthy Agent input"))
        service.draft = OrbiterDraft(title: "New Orbiter", goal: "Keep as draft", directory: f.root.path)
        let created = try await service.create(pluginID: "codex", providerID: nil)
        #expect(service.agents.contains { $0.id == created })
        let externalPane = try f.create(UUID(), pluginID: "claude-code", title: "External", directory: f.root.path)
        let external = try #require(try await f.catalog.snapshot(refresh: true).first { $0.workspacePane == externalPane })
        let associated = try await service.associate(external)
        #expect(service.agents.contains { $0.id == associated })
        await service.refresh(inspect: false)
        #expect(service.recoveryIssues[original.agentID] == issue)
        #expect(service.issue == nil && f.writes.count == 1)
        #expect(try await recovery.entry(original.agentID) == entry)
        fixed.setValue(true)
        await service.refresh()
        #expect(service.recoveryIssues[original.agentID] == nil)
        #expect(service.agents.contains { $0.agentID?.paneID == destination.paneID })
        #expect(service.drafts[OrbiterRecord(agentID: .init(hostID: f.hostID, paneID: destination.paneID)).id] == "Do not send to the failed Agent")
        #expect(f.launches.count == 5 && f.writes.count == 1)
        try await f.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func delayedRestoreRebindsRolesAfterRefreshAndRestart(plugin: String, loseReply: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        var orbie = await f.orbie()
        try await orbie.create(pluginID: plugin, providerID: nil)
        let original = try #require(orbie.instance)
        orbie.draft = "Retain my draft"
        await orbie.saveDraft()
        var orbiters = await f.orbiters()
        let oldKey = try await orbiters.associate(original)
        orbiters.drafts[oldKey] = "Orbiter draft"
        await orbiters.saveDrafts()
        var message = AgentMessage(instance: original, text: "Old message")
        message.status = .succeeded
        message.answer = "Saved reply"
        try await f.interaction.store.insert(message)
        let mainStore = OrbieStore(paths: f.paths, hostID: f.hostID)
        var main = try await mainStore.load()
        main.messageIDs = [message.id]
        try await mainStore.save(main)
        let orbiterStore = OrbiterStore(paths: f.paths, hostID: f.hostID)
        var index = try await orbiterStore.load()
        index.agents[0].messageIDs = [message.id]
        index.agents[0].materialsDirectories = [f.root.path]
        try await orbiterStore.save(index)
        f.observations = []
        let ready = LockIsolated(false)
        let file = f.root.appendingPathComponent("resume.json")
        func makeRecovery() -> AgentRoleRecovery {
            AgentRoleRecovery(file: file, paneExists: { id in
                await f.observations.contains { $0.workspacePane.paneID == id.paneID }
            }, launch: { token, saved in
                try await MainActor.run {
                    let pane = try f.create(token, pluginID: saved.pluginID, title: "Restored", directory: saved.projectPath)
                    f.observations[0].conversationID = saved.sessionID
                    if loseReply {
                        throw AgentWorkflowError("Lost launch reply")
                    }
                    return pane
                }
            }, locate: { await f.launches[$0] }, inspect: { pane, _ in
                var live = try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
                if !ready.value {
                    if plugin != "codex" {
                        return nil
                    }
                    live?.conversationID = ""
                }
                return live
            })
        }
        var recovery = makeRecovery()
        try await recovery.capture(original.agentID, descriptor: .init(pluginID: plugin, sessionID: original.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
        orbie = await f.orbie(recovery: recovery)
        orbiters = await f.orbiters(recovery: recovery)
        #expect(f.launches.count == 1) // Ordinary refresh must not start recovery.
        await orbie.restoreOriginalConversation()
        #expect(f.launches.count == 2)
        if !loseReply {
            #expect(orbie.isRestoring && orbie.issue == nil && !orbie.canRestore)
            #expect(orbie.availability == "Restoring the original conversation…")
        }
        // A second role requesting the same recovery also reuses the one launch.
        try await orbiters.restoreOriginalConversation(oldKey)
        #expect(orbiters.restoringAgents.contains(original.agentID))
        #expect(orbiters.availability(orbiters.agents[0]) == "Restoring the original conversation…")
        #expect(f.launches.count == 2)
        await orbie.refresh()
        #expect(orbie.isRestoring && orbie.record?.target?.agentID == original.agentID)
        // Reload persisted intent with empty runtime caches, as after App restart.
        try await f.restartInteraction()
        recovery = makeRecovery()
        orbie = await f.orbie(recovery: recovery)
        orbiters = await f.orbiters(recovery: recovery)
        orbiters.historyAgentID = oldKey
        #expect(orbie.isRestoring && orbiters.restoringAgents.contains(original.agentID))
        ready.setValue(true)
        await orbie.refresh(inspect: false)
        await orbiters.refresh(inspect: false)
        #expect(orbie.record?.target?.agentID == original.agentID)
        #expect(orbiters.agents[0].agentID == original.agentID)
        await orbie.refresh()
        await orbiters.refresh()
        let restored = try #require(orbie.instance)
        #expect(restored.agentID != original.agentID && restored.conversationID == original.conversationID)
        #expect(!orbie.isRestoring && !orbie.tabClosed && !orbie.canRestore && orbie.issue == nil)
        #expect(orbiters.agents[0].agentID == restored.agentID && orbiters.restoringAgents.isEmpty)
        #expect(orbiters.historyAgentID == orbiters.agents[0].id)
        #expect(orbiters.drafts[orbiters.agents[0].id] == "Orbiter draft" && orbiters.drafts[oldKey] == nil)
        #expect(orbiters.agents[0].materialsDirectories == [f.root.path])
        #expect(orbie.draft == "Retain my draft")
        #expect(orbie.record?.messageIDs == [message.id] && orbiters.agents[0].messageIDs == [message.id])
        #expect(try await f.interaction.store.message(message.id)?.agentID == original.agentID)
        await orbie.refresh()
        await orbiters.refresh()
        #expect(f.launches.count == 2 && f.writes.isEmpty)
        #expect(try await mainStore.load().target?.agentID == restored.agentID)
        #expect(try await orbiterStore.load().agents[0].agentID == restored.agentID)
        try await f.cleanup()
    }

    @Test(arguments: ["host", "pane", "plugin", "conversation", "invalidated", "closed", "notLaunched", "scan"])
    func refreshDoesNotAdoptInvalidEvidenceOrLaunchAgain(fault: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let oldID = AgentID(hostID: f.hostID, paneID: UUID())
        let token = UUID()
        let pane = try f.create(token, pluginID: "codex", title: "Restoring", directory: f.root.path)
        let live = try #require(try await f.catalog.snapshot(refresh: true).first)
        let descriptor = AgentResumeDescriptor(pluginID: live.pluginID, sessionID: live.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        let record = AgentRoleRecovery.Entry(agentID: oldID, descriptor: descriptor, invalidated: fault == "invalidated", intent: .init(id: token, attempted: fault != "notLaunched", pane: pane, inPlace: false))
        let file = f.root.appendingPathComponent("resume.json")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try JSONEncoder().encode([record]).write(to: file)
        let inspected = LockIsolated(false)
        let recovery = AgentRoleRecovery(file: file, paneExists: { _ in false }, launch: { _, _ in
            Issue.record("Refresh must never launch")
            throw CancellationError()
        }, locate: { _ in nil }, inspect: { _, _ in
            inspected.setValue(true)
            if fault == "closed" {
                throw AgentWorkflowError("Recovery terminal closed")
            }
            if fault == "scan" {
                throw AgentWorkflowInspectionUnavailable()
            }
            return AgentWorkflowInstance(
                id: live.id, hostID: fault == "host" ? UUID() : live.hostID,
                pluginID: fault == "plugin" ? "claude-code" : live.pluginID,
                processID: live.processID, processRuntimeID: live.processRuntimeID,
                workspacePane: fault == "pane" ? .init(serverID: pane.serverID, sessionID: pane.sessionID, windowID: pane.windowID, paneID: UUID()) : pane,
                paneID: live.paneID, conversationID: fault == "conversation" ? UUID().uuidString : live.conversationID,
                displayName: live.displayName, workingDirectory: live.workingDirectory, capabilities: live.capabilities, readiness: .ready
            )
        })
        if fault == "notLaunched" {
            #expect(try await recovery.checkPendingRestore(oldID) == nil)
            #expect(!inspected.value)
        } else if fault == "scan" {
            await #expect(throws: AgentWorkflowInspectionUnavailable.self) { try await recovery.checkPendingRestore(oldID) }
        } else {
            await #expect(throws: AgentWorkflowError.self) { try await recovery.checkPendingRestore(oldID) }
        }
        #expect(try await recovery.entry(oldID) == record)
        #expect(f.launches.count == 1 && f.writes.isEmpty)
        try await f.cleanup()
    }
}
