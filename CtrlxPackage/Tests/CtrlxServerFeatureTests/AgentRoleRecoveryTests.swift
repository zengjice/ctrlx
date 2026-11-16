import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRoleRecoveryTests {
    @Test(arguments: ["codex", "claude-code"], [false, true])
    func explicitRestoreUsesNewPaneAndReconcilesLostReply(plugin: String, loseReply: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let oldID = AgentID(hostID: f.hostID, paneID: UUID())
        let conversation = UUID().uuidString
        let descriptor = AgentResumeDescriptor(pluginID: plugin, sessionID: conversation, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { id, saved in
            try await MainActor.run {
                let pane = try f.create(id, pluginID: saved.pluginID, title: "Restored", directory: saved.projectPath)
                f.observations[f.observations.count - 1].conversationID = saved.sessionID
                if loseReply {
                    throw AgentWorkflowError("Lost reply")
                }
                return pane
            }
        }, locate: { id in await f.launches[id] }, inspect: { pane, _ in
            try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
        })
        try await recovery.capture(oldID, descriptor: descriptor, invalidated: false)
        #expect(f.launches.isEmpty)
        if loseReply {
            await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(oldID) }
        }
        let result = try await recovery.restore(oldID)
        let again = try await recovery.restore(oldID)
        #expect(result.agentID != oldID && result.conversationID == conversation)
        #expect(again.agentID == result.agentID && f.launches.count == 1)
        #expect(try await recovery.entry(oldID)?.descriptor == descriptor)
        try await f.cleanup()
    }

    @Test
    func retainedRuntimeEvidenceSurvivesCloseCaptureAndInvalidation() async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        var state = PaneState(paneId: "%1", currentPath: f.root.path, agentSession: .init(paneId: "%1", pluginID: "codex"))
        let conversation = UUID().uuidString
        state.claudeSessionID = conversation
        state.currentPath = f.root.path
        let identity = try AgentSessionIdentity(source: #require(AgentForkSource(pane: state)), processID: "123", runtimeID: "runtime-one")
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { _, _ in throw CancellationError() }, locate: { _ in nil }, inspect: { _, _ in nil })
        try await recovery.capture(id, descriptor: .init(pluginID: "codex", sessionID: conversation, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), identity: identity, invalidated: false)
        #expect(try await recovery.entry(id)?.identity == identity)
        try await recovery.capture(id, descriptor: nil, invalidated: true)
        #expect(try await recovery.entry(id)?.identity == nil)
        #expect(try await recovery.entry(id)?.descriptor == nil)
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func livePaneOrUnavailableInspectionNeverCreatesAnotherAgent(unavailable: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in
            if unavailable {
                throw AgentWorkflowError("Offline")
            }
            return true
        }, launch: { _, _ in Issue.record("Must not launch")
            throw CancellationError()
        }, locate: { _ in nil }, inspect: { _, _ in nil })
        await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(id) }
        try await f.cleanup()
    }

    @Test
    func invalidatedConversationCannotFallBackToOldHistory() async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        let recovery = AgentRoleRecovery(
            file: f.root.appendingPathComponent("resume.json"),
            paneExists: { _ in false },
            launch: { _, _ in Issue.record("Must not launch")
                throw CancellationError()
            },
            locate: { _ in nil },
            inspect: { _, _ in nil }
        )
        try await recovery.capture(id, descriptor: .init(pluginID: "codex", sessionID: UUID().uuidString, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
        try await recovery.capture(id, descriptor: nil, invalidated: true)
        await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(id) }
        try await f.cleanup()
    }

    @Test
    func knownPrelaunchFailureCanBeRetriedWithoutChangingOriginalEvidence() async throws {
        let f = try await AgentInteractionTestSupport()
        let id = AgentID(hostID: f.hostID, paneID: UUID())
        let descriptor = AgentResumeDescriptor(pluginID: "codex", sessionID: UUID().uuidString, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true)
        f.lostCreateReply = true
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { intent, saved in
            try await MainActor.run {
                if f.lostCreateReply {
                    f.lostCreateReply = false
                    throw AgentRoleRecovery.NotLaunched(reason: "History unavailable")
                }
                let pane = try f.create(intent, pluginID: saved.pluginID, title: "Restored", directory: saved.projectPath)
                f.observations[0].conversationID = saved.sessionID
                return pane
            }
        }, locate: { await f.launches[$0] }, inspect: { pane, _ in
            try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
        })
        try await recovery.capture(id, descriptor: descriptor, invalidated: false)
        await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(id) }
        #expect(try await recovery.entry(id)?.intent?.attempted == false)
        #expect(f.launches.isEmpty)
        #expect(try await recovery.restore(id).conversationID == descriptor.sessionID)
        #expect(f.launches.count == 1)
        try await f.cleanup()
    }
}
