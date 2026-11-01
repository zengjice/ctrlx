import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceAgentCaptureTests {
    private func fixture() throws -> (WorkspaceRecoveryPane, PaneState, AgentSessionIdentity) {
        let conversation = UUID().uuidString
        var state = PaneState(paneId: "%1", currentPath: "/project", agentSession: .init(paneId: "%1", pluginID: "codex"))
        state.claudeSessionID = conversation
        let source = try #require(AgentForkSource(pane: state))
        let identity = AgentSessionIdentity(source: source, processID: "123", runtimeID: "instance-one")
        let descriptor = AgentResumeDescriptor(pluginID: "codex", sessionID: conversation, projectPath: "/project", configurationRoot: "/account/codex", usesDefaultConfiguration: false, executable: "/old/codex", cliVersion: "codex-cli 0.166.0", automaticResumeUnavailableReason: nil)
        var pane = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%1", directory: "/project")
        WorkspaceAgentCapture.record(descriptor, identity: identity, in: &pane)
        return (pane, state, identity)
    }

    @Test("Transient discovery or identity failures retain a durable resume record", arguments: [false, true])
    func retainsLastVerifiedRecord(afterReload: Bool) throws {
        let (original, state, _) = try fixture()
        var pane = afterReload ? try JSONDecoder().decode(WorkspaceRecoveryPane.self, from: JSONEncoder().encode(original)) : original
        #expect(!WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: nil, scanAvailable: false, runtimeID: { _ in "instance-one" }))
        WorkspaceAgentCapture.recordFailure("Identity unavailable", in: &pane)
        let persisted = try JSONDecoder().decode(WorkspaceRecoveryPane.self, from: JSONEncoder().encode(pane))
        #expect(persisted.agent == original.agent)
        #expect(persisted.agentIdentity == original.agentIdentity)
        #expect(persisted.unavailableAgentReason == "Identity unavailable")
    }

    @Test("A confirmed new conversation, process, or process instance invalidates the previous record", arguments: ["conversation", "process", "runtime", "plugin"])
    func replacement(kind: String) throws {
        var (pane, state, _) = try fixture()
        if kind == "conversation" {
            state.claudeSessionID = UUID().uuidString
        }
        let detected = TmuxService.DetectedAgentPane(path: "/project", pluginID: kind == "plugin" ? "claude-code" : "codex", processIDs: [kind == "process" ? "456" : "123"])
        #expect(WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: detected, scanAvailable: true, runtimeID: { _ in kind == "runtime" ? "instance-two" : "instance-one" }))
        #expect(pane.agent == nil && pane.agentIdentity == nil)
    }

    @Test("A missing UI classification alone does not clear recovery; a confirmed exit does")
    func ended() throws {
        var (pane, state, _) = try fixture()
        state.agentSession = nil
        #expect(!WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: nil, scanAvailable: false, runtimeID: { _ in nil }))
        #expect(!WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: nil, scanAvailable: true, runtimeID: { _ in "instance-one" }))
        #expect(pane.agent != nil)
        #expect(WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: nil, scanAvailable: true, runtimeID: { _ in nil }))
        #expect(pane.agent == nil && pane.agentIdentity == nil && pane.unavailableAgentReason == nil)
    }

    @Test("An ambiguous process scan does not discard a still-running recorded process")
    func ambiguousScan() throws {
        var (pane, state, _) = try fixture()
        let detected = TmuxService.DetectedAgentPane(path: "/project", pluginID: "codex", processIDs: ["123", "456"])
        #expect(!WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: detected, scanAvailable: true, runtimeID: { _ in "instance-one" }))
        #expect(pane.agent != nil)
    }

    @Test("An unreadable process instance is not evidence that the process was replaced")
    func unreadableRuntime() throws {
        var (pane, state, _) = try fixture()
        let detected = TmuxService.DetectedAgentPane(path: "/project", pluginID: "codex", processIDs: ["123"])
        #expect(!WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: detected, scanAvailable: true, runtimeID: { _ in nil }))
        #expect(pane.agent != nil && pane.agentIdentity != nil)
    }

    @Test("A new tmux topology capture retains persisted Agent provenance")
    func checkpointRetainsProvenance() async throws {
        let (pane, _, _) = try fixture()
        var source = WorkspaceRecoveryStoreTests.snapshot()
        source.sessions[0].windows[0].panes[0].agent = pane.agent
        source.sessions[0].windows[0].panes[0].agentIdentity = pane.agentIdentity
        let store = WorkspaceRecoveryStore.inMemory(source)
        var live = WorkspaceTmuxState(serverID: source.serverID, sessions: source.sessions)
        live.sessions[0].windows[0].panes[0].agent = nil
        live.sessions[0].windows[0].panes[0].agentIdentity = nil
        let captured = live
        let boot = source.bootID
        let recovery = WorkspaceRecoveryController(
            store: store, tmux: .init(capture: { captured }, restore: { _ in throw WorkspaceRecoveryError("Unexpected restore") }),
            system: .init(bootID: { boot }, directoryExists: { _ in true }, pathExists: { _ in true }),
            mode: { .layoutAndAgents }, captureExtras: { $0 }, present: { _, _ in },
            resumeAgents: { snapshot, _, _, _ in (snapshot, []) }
        )
        await recovery.start(periodic: false)
        let saved = try #require(try await store.load()?.sessions[0].windows[0].panes[0])
        #expect(saved.agent == pane.agent && saved.agentIdentity == pane.agentIdentity)
        #expect(recovery.phase == .ready)
        await recovery.stop()
    }

    @Test("Successful verification clears the warning; legacy records without provenance still decode")
    func recoversAfterFailure() throws {
        var (pane, _, identity) = try fixture()
        let descriptor = try #require(pane.agent)
        WorkspaceAgentCapture.recordFailure("Transient read failed", in: &pane)
        WorkspaceAgentCapture.record(descriptor, identity: identity, in: &pane)
        #expect(pane.unavailableAgentReason == nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as? [String: Any])
        json.removeValue(forKey: "agentIdentity")
        let legacy = try JSONDecoder().decode(WorkspaceRecoveryPane.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.agent == descriptor && legacy.agentIdentity == nil)
    }
}
