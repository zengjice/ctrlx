import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRoleResumeTests {
    @Test(arguments: ["codex", "claude-code"])
    func shellExitThenCloseLastTabRetainsOriginalConversation(plugin: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let pane = try f.create(UUID(), pluginID: plugin, title: "Orbie", directory: f.root.path)
        let instance = try #require(try await f.catalog.snapshot(refresh: true).first)
        var state = PaneState(paneId: instance.paneID, currentPath: f.root.path, agentSession: .init(paneId: instance.paneID, pluginID: plugin))
        state.workspaceIdentity = pane
        state.claudeSessionID = instance.conversationID
        let identity = try AgentSessionIdentity(source: #require(AgentForkSource(pane: state)), processID: String(instance.processID), runtimeID: instance.processRuntimeID)
        let descriptor = AgentResumeDescriptor(pluginID: plugin, sessionID: instance.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        var snapshot = WorkspaceRecoveryPane(id: pane.paneID, runtimeID: instance.paneID, directory: f.root.path, agent: descriptor, agentIdentity: identity)
        let file = f.root.appendingPathComponent("resume.json")
        func recovery() -> AgentRoleRecovery {
            AgentRoleRecovery(file: file, paneExists: { _ in false }, launch: { id, saved in
                try await MainActor.run {
                    let newPane = try f.create(id, pluginID: saved.pluginID, title: "Restored", directory: saved.projectPath)
                    f.observations[f.observations.count - 1].conversationID = saved.sessionID
                    return newPane
                }
            }, locate: { await f.launches[$0] }, inspect: { pane, _ in
                try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
            })
        }
        let before = recovery()
        try await before.capture(instance.agentID, descriptor: descriptor, identity: identity, invalidated: false)
        state.agentSession = nil
        #expect(WorkspaceAgentCapture.invalidateChangedAgent(&snapshot, state: state, detected: nil, scanAvailable: true, runtimeID: { _ in nil }))
        // The production handoff must not propagate workspace auto-resume invalidation.
        try await before.captureSnapshot(instance.agentID, pane: snapshot, state: state, detected: nil, scanAvailable: true, runtimeID: { _ in nil })
        #expect(try await before.entry(instance.agentID)?.descriptor == descriptor)
        f.observations = [] // Last window/session was closed.
        let afterRestart = recovery()
        let restored = try await afterRestart.restore(instance.agentID)
        #expect(restored.conversationID == instance.conversationID)
        #expect(restored.agentID != instance.agentID)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func replacementAfterShellExitRevokesRetainedRecord() async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        var old = PaneState(paneId: "%1", currentPath: f.root.path, agentSession: .init(paneId: "%1", pluginID: "codex"))
        old.claudeSessionID = UUID().uuidString
        let identity = try AgentSessionIdentity(source: #require(AgentForkSource(pane: old)), processID: "123", runtimeID: "old")
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { _, _ in
            Issue.record("A replacement must not resume the old conversation")
            throw CancellationError()
        }, locate: { _ in nil }, inspect: { _, _ in nil }, recoverDescriptor: { _, _ in
            Issue.record("A known replacement must not use legacy repair")
            return nil
        })
        try await recovery.capture(id, descriptor: .init(pluginID: "codex", sessionID: identity.source.sessionID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), identity: identity, invalidated: false)
        var shell = WorkspaceRecoveryPane(id: id.paneID, runtimeID: "%1", directory: f.root.path)
        let state = PaneState(paneId: "%1", currentPath: f.root.path)
        try await recovery.captureSnapshot(id, pane: shell, state: state, detected: nil, scanAvailable: true, runtimeID: { _ in nil })
        #expect(try await recovery.entry(id)?.descriptor != nil)
        shell.savedAgentIdentityInvalidated = true
        try await recovery.captureSnapshot(id, pane: shell, state: state, detected: .init(path: f.root.path, pluginID: "claude-code", processIDs: ["456"]), scanAvailable: true, runtimeID: { _ in nil })
        #expect(try await recovery.entry(id)?.invalidated == true)
        await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(id) }
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func legacyMissingRecordRechecksExactConversation(invalidatedByOldVersion: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        let file = f.root.appendingPathComponent("resume.json")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        if invalidatedByOldVersion {
            try JSONEncoder().encode([AgentRoleRecovery.Entry(agentID: id, issue: "The previous conversation no longer belongs to this Agent. Create a new Agent explicitly.")]).write(to: file)
        }
        let conversation = UUID().uuidString
        let checks = LockIsolated(0)
        let recovery = AgentRoleRecovery(file: file, paneExists: { _ in false }, launch: { intent, descriptor in
            try await MainActor.run {
                let pane = try f.create(intent, pluginID: descriptor.pluginID, title: "Recovered", directory: descriptor.projectPath)
                f.observations[0].conversationID = descriptor.sessionID
                return pane
            }
        }, locate: { await f.launches[$0] }, inspect: { pane, _ in
            try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
        }, recoverDescriptor: { requested, _ in
            #expect(requested == id)
            checks.withValue { $0 += 1 }
            return .init(pluginID: "codex", sessionID: conversation, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        })
        #expect(checks.value == 0)
        #expect(try await recovery.restore(id).conversationID == conversation)
        #expect(try await recovery.restore(id).conversationID == conversation)
        #expect(checks.value == 1 && f.launches.count == 1)
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func existingPaneResumeAndLostReplyPreserveAgentID(loseReply: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let pane = try f.create(UUID(), pluginID: "codex", title: "Original", directory: f.root.path)
        let original = try #require(try await f.catalog.snapshot(refresh: true).first)
        let attempts = LockIsolated(0)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in true }, launch: { _, _ in
            Issue.record("Must reuse the existing pane")
            throw CancellationError()
        }, locate: { await f.launches[$0] }, inspect: { _, _ in
            original
        }, resumeExisting: { intent, id, descriptor in
            #expect(id == original.agentID && descriptor.sessionID == original.conversationID)
            attempts.withValue { $0 += 1 }
            await MainActor.run { f.launches[intent] = pane }
            if loseReply {
                throw AgentWorkflowError("Lost reply")
            }
            return pane
        })
        try await recovery.capture(original.agentID, descriptor: .init(pluginID: "codex", sessionID: original.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
        if loseReply {
            await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(original.agentID) }
        }
        #expect(try await recovery.restore(original.agentID).agentID == original.agentID)
        #expect(attempts.value == 1)
        #expect(try await recovery.entry(original.agentID)?.intent == nil)
        try await f.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func legacyRepairUsesSavedRoleAndNativeHistory(plugin: String, historyMissing: Bool) async throws {
        let expected = LockIsolated("")
        let calls = LockIsolated(0)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[AgentForkHistoryClient.self].root = { session, _, _ in
                #expect(session == expected.value)
                calls.withValue { $0 += 1 }
                if historyMissing {
                    throw AgentWorkflowError("Native history missing")
                }
                return "/verified/configuration"
            }
        } operation: {
            let f = try await AgentInteractionTestSupport()
            let orbie = await f.orbie()
            try await orbie.create(pluginID: plugin, providerID: nil)
            let instance = try #require(orbie.instance)
            expected.setValue(instance.conversationID)
            f.observations = []
            let main = try await OrbieStore(paths: f.paths, hostID: f.hostID).load()
            let orbiters = try await OrbiterStore(paths: f.paths, hostID: f.hostID).load()
            let recover: (AgentID) async throws -> AgentResumeDescriptor? = { id in
                try await AgentRoleRecovery.descriptorForSavedRole(id, identity: nil, main: main, orbiters: orbiters) { plugin in
                    if plugin == "codex" {
                        return CodexPluginCore()
                    }
                    return ClaudeCodePluginCore()
                }
            }
            if historyMissing {
                await #expect(throws: AgentWorkflowError.self) { try await recover(instance.agentID) }
            } else {
                let descriptor = try await recover(instance.agentID)
                #expect(descriptor?.sessionID == instance.conversationID)
                #expect(descriptor?.configurationRoot == "/verified/configuration")
                #expect(descriptor?.pluginID == plugin)
            }
            #expect(calls.value == 1 && f.writes.isEmpty)
            await #expect(throws: AgentWorkflowError.self) {
                try await recover(.init(hostID: f.hostID, paneID: UUID()))
            }
            #expect(calls.value == 1)
            try await f.cleanup()
        }
    }

    @Test(arguments: ["100\n", "100\n200\n", "", "101\n"])
    func inPlaceResumeRequiresAnUnoccupiedShell(pids: String) throws {
        let snapshot = try AgentRestartTerminal.Snapshot(output: "100\u{1f}/dev/ttys999\u{1f}0\u{1f}zsh\n")
        let result = ProcessResult(exitCode: 0, stdout: Data(pids.utf8), stderr: Data())
        if pids == "100\n" {
            try AgentRestartTerminal.validateStopped(snapshot, occupants: result)
        } else {
            #expect(throws: AgentRestartError.self) { try AgentRestartTerminal.validateStopped(snapshot, occupants: result) }
        }
    }
}
