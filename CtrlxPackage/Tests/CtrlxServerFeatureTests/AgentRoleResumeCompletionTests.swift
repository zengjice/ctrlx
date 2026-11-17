import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRoleResumeCompletionTests {
    @Test(arguments: ["orbie", "orbiter", "capture"])
    func delayedConfirmationAllowsAnotherResume(route: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let original = await f.orbie()
        try await original.create(pluginID: "codex", providerID: nil)
        let live = try #require(original.instance)
        let associated = await f.orbiters()
        _ = try await associated.associate(live)
        let observations = f.observations
        f.observations = []
        let launches = LockIsolated(0)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in true }, launch: { _, _ in
            Issue.record("Must keep the original pane")
            throw CancellationError()
        }, locate: { _ in nil }, inspect: { _, _ in try await f.catalog.snapshot(refresh: true).first }, resumeExisting: { _, _, _ in
            launches.withValue { $0 += 1 }
            return live.workspacePane
        })
        let descriptor = descriptor(live)
        let proof = try proof(live)
        try await recovery.capture(live.agentID, descriptor: descriptor, identity: proof.identity, invalidated: false)
        await #expect(throws: AgentRoleRecovery.Starting.self) { try await recovery.restore(live.agentID) }
        let firstIntent = try #require(try await recovery.entry(live.agentID)?.intent)
        #expect(firstIntent.attempted && launches.value == 1)

        // A saved snapshot without a matching live process must not confirm startup.
        try await recovery.captureSnapshot(live.agentID, pane: proof.snapshot, state: proof.state, detected: nil, scanAvailable: false, runtimeID: { _ in nil })
        #expect(try await recovery.entry(live.agentID)?.intent?.id == firstIntent.id)
        f.observations = observations
        switch route {
        case "orbie":
            let service = OrbieService(store: .init(paths: f.paths, hostID: f.hostID), interaction: f.interaction, recovery: recovery, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await service.refresh(inspect: false)
            #expect(try await recovery.entry(live.agentID)?.intent != nil)
            await service.refresh()
            #expect(service.instance?.agentID == live.agentID && !service.canRestore)
        case "orbiter":
            let service = OrbiterService(store: .init(paths: f.paths, hostID: f.hostID), interaction: f.interaction, recovery: recovery, enabled: { true }, forkSource: { throw CancellationError() }, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await service.refresh(inspect: false)
            #expect(try await recovery.entry(live.agentID)?.intent != nil)
            await service.refresh()
            #expect(service.currentInstance(service.agents[0])?.agentID == live.agentID)
        default:
            try await confirm(recovery, live: live)
        }
        #expect(try await recovery.entry(live.agentID)?.intent == nil)
        f.observations = []
        var shell = proof.state
        shell.agentSession = nil
        try await recovery.captureSnapshot(live.agentID, pane: .init(id: live.agentID.paneID, runtimeID: live.paneID, directory: f.root.path), state: shell, detected: nil, scanAvailable: true, runtimeID: { _ in nil })
        await #expect(throws: AgentRoleRecovery.Starting.self) { try await recovery.restore(live.agentID) }
        #expect(launches.value == 2)
        #expect(try await recovery.entry(live.agentID)?.intent?.id != firstIntent.id)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test(arguments: ["launch", "inspect"])
    func concurrentConfirmationIsNotOverwritten(phase: String) async throws {
        let f = try await AgentInteractionTestSupport()
        _ = try f.create(UUID(), pluginID: "claude-code", title: "Original", directory: f.root.path)
        let live = try #require(try await f.catalog.snapshot(refresh: true).first)
        let reference = LockIsolated<AgentRoleRecovery?>(nil)
        let launches = LockIsolated(0)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in true }, launch: { _, _ in throw CancellationError() }, locate: { _ in nil }, inspect: { _, _ in
            if phase == "inspect" {
                try await confirm(#require(reference.value), live: live)
            }
            return nil
        }, resumeExisting: { _, _, _ in
            launches.withValue { $0 += 1 }
            if phase == "launch" {
                try await confirm(#require(reference.value), live: live)
            }
            return live.workspacePane
        })
        reference.setValue(recovery)
        try await recovery.capture(live.agentID, descriptor: descriptor(live), invalidated: false)
        for expectedCount in 1...2 {
            await #expect(throws: AgentRoleRecovery.Starting.self) { try await recovery.restore(live.agentID) }
            #expect(try await recovery.entry(live.agentID)?.intent == nil)
            #expect(launches.value == expectedCount)
        }
        reference.setValue(nil)
        try await f.cleanup()
    }

    private func descriptor(_ live: AgentWorkflowInstance) -> AgentResumeDescriptor {
        .init(pluginID: live.pluginID, sessionID: live.conversationID, projectPath: live.workingDirectory, configurationRoot: live.workingDirectory, usesDefaultConfiguration: true)
    }

    private func proof(_ live: AgentWorkflowInstance) throws -> (state: PaneState, snapshot: WorkspaceRecoveryPane, identity: AgentSessionIdentity) {
        var state = PaneState(paneId: live.paneID, currentPath: live.workingDirectory, agentSession: .init(paneId: live.paneID, pluginID: live.pluginID))
        state.workspaceIdentity = live.workspacePane
        state.claudeSessionID = live.conversationID
        let identity = try AgentSessionIdentity(source: #require(AgentForkSource(pane: state)), processID: String(live.processID), runtimeID: live.processRuntimeID)
        return (state, .init(id: live.agentID.paneID, runtimeID: live.paneID, directory: live.workingDirectory, agent: descriptor(live), agentIdentity: identity), identity)
    }

    private func confirm(_ recovery: AgentRoleRecovery, live: AgentWorkflowInstance) async throws {
        let proof = try proof(live)
        try await recovery.captureSnapshot(live.agentID, pane: proof.snapshot, state: proof.state, detected: .init(path: live.workingDirectory, pluginID: live.pluginID, processIDs: [String(live.processID)]), scanAvailable: true, runtimeID: { _ in live.processRuntimeID })
    }
}
