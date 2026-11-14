import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentBindingTests {
    private func pane() -> PaneState {
        var pane = PaneState(paneId: "%5", agentSession: .init(paneId: "%5", pluginID: "codex", state: .idle), workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
        pane.agentSession?.processRuntimeID = "501:101:100:0"
        pane.sessionName = "work"
        pane.tmuxWindowId = "@7"
        pane.currentPath = "/repo"
        pane.claudeSessionID = UUID().uuidString
        return pane
    }

    private let detected = TmuxService.DetectedAgentPane(path: "/repo", pluginID: "codex", processIDs: ["101"])

    @Test("Stable pane binding survives renaming and moving; recovery receives current routing metadata")
    func followsPane() throws {
        let original = pane()
        let identity = try AgentSessionIdentity(source: #require(AgentForkSource(pane: original)), processID: "101", runtimeID: "start")
        var moved = original
        moved.sessionName = "renamed"
        moved.tmuxWindowId = "@9"
        moved.workspaceIdentity?.sessionID = UUID()
        moved.workspaceIdentity?.windowID = UUID()
        moved.currentPath = "/new-directory"
        let current = try #require(identity.current(in: moved, detected: detected, runtimeID: "start"))
        #expect(current.source == AgentForkSource(pane: moved))
        #expect(current.source.sessionID == identity.source.sessionID)
        let workspacePane = try #require(moved.workspaceIdentity)
        let binding = try #require(AgentProcessBinding(paneID: moved.paneId, workspacePane: workspacePane, detected: detected, runtimeID: { _ in "start" }))
        #expect(binding.matches(identity))
        #expect(binding.matches(current))
    }

    @Test("Pane reuse, server restart and conversation replacement cannot reuse native identity", arguments: ["server", "pane", "missing-pane", "plugin", "conversation", "runtime", "missing-runtime", "ambiguous-process", "new-process"])
    func rejectsReplacement(change: String) throws {
        var current = pane()
        let saved = try AgentSessionIdentity(source: #require(AgentForkSource(pane: current)), processID: "101", runtimeID: "start")
        var runtime: String? = "start"
        var process = detected
        switch change {
        case "server": current.workspaceIdentity?.serverID = "another-server"
        case "pane": current.workspaceIdentity?.paneID = UUID()
        case "missing-pane": current.workspaceIdentity = nil
        case "plugin": current.agentSession?.pluginID = "claude-code"
        case "conversation": current.claudeSessionID = UUID().uuidString
        case "runtime": runtime = "restarted"
        case "missing-runtime": runtime = nil
        case "ambiguous-process": process = .init(path: "/repo", pluginID: "codex", processIDs: ["101", "102"])
        default: process = .init(path: "/repo", pluginID: "codex", processIDs: ["102"])
        }
        #expect(saved.current(in: current, detected: process, runtimeID: runtime) == nil)
    }

    @Test("Native identity reads recheck process incarnation after loading")
    func restartDuringLoad() async throws {
        let current = pane()
        let saved = try AgentSessionIdentity(source: #require(AgentForkSource(pane: current)), processID: "101", runtimeID: "start")
        let runtime = LockIsolated("start")
        var client = AgentSessionIdentityClient.previewValue
        client.load = { _ in runtime.setValue("restarted")
            return saved
        }
        client.runtimeID = { _ in runtime.value }
        #expect(await client.currentIdentity(in: current, detected: detected) == nil)
    }

    @Test("Model and workflow process binding does not require a native conversation")
    func freshProcess() throws {
        var current = pane()
        current.claudeSessionID = nil
        let workspacePane = try #require(current.workspaceIdentity)
        let binding = try #require(AgentProcessBinding(paneID: current.paneId, workspacePane: workspacePane, detected: detected, runtimeID: { _ in "start" }))
        var instance = AgentWorkflowInstance(hostID: UUID(), pluginID: "codex", processID: 101, processRuntimeID: "start", workspacePane: binding.workspacePane, paneID: "%5", conversationID: "", displayName: "work", workingDirectory: "/repo", capabilities: nil, readiness: .ready)
        #expect(binding.matches(instance))
        instance.workspacePane.windowID = UUID()
        #expect(binding.matches(instance))
        let restarted = try #require(AgentProcessBinding(paneID: current.paneId, workspacePane: binding.workspacePane, detected: detected, runtimeID: { _ in "restarted" }))
        #expect(!restarted.matches(instance))
    }

    @Test("Delayed end cannot remove a successor plugin, conversation or terminal", arguments: ["plugin", "conversation", "pane", "server", "ended"])
    func staleEnd(change: String) throws {
        let original = pane()
        let event = try PluginEvent(pluginID: "codex", sessionID: #require(original.claudeSessionID), tmuxPane: "%5")
        let context = try #require(AgentSessionEndContext(event: event, pane: original))
        var current = original
        switch change {
        case "plugin": current.agentSession?.pluginID = "claude-code"
        case "conversation": current.claudeSessionID = UUID().uuidString
        case "pane": current.workspaceIdentity?.paneID = UUID()
        case "server": current.workspaceIdentity?.serverID = "another-server"
        default: current.agentSession = nil
        }
        #expect(!context.matches(current))
        #expect(AgentSessionEndContext(event: event, pane: current) == nil || change == "pane" || change == "server")
    }

    @Test("Synthetic ends reject a live successor; native ends verify the kernel process incarnation")
    func endProcessEvidence() throws {
        let current = pane()
        let event = try PluginEvent(pluginID: "codex", sessionID: #require(current.claudeSessionID), tmuxPane: "%5")
        let context = try #require(AgentSessionEndContext(event: event, pane: current))
        let process = PluginIngressPeer.Process(processID: 101, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        let peer = try #require(PluginIngressPeer.capture(peerPID: 101, userID: 501, inspect: { $0 == 101 ? process : nil }))
        #expect(context.accepts(detected: nil, peer: nil, runtimeID: { _ in nil }))
        #expect(context.accepts(detected: nil, peer: peer, runtimeID: { _ in nil }))
        #expect(!context.accepts(detected: detected, peer: nil, runtimeID: { _ in process.runtimeID }))
        #expect(context.accepts(detected: detected, peer: peer, runtimeID: { _ in process.runtimeID }))
        #expect(!context.accepts(detected: detected, peer: peer, runtimeID: { _ in "restarted" }))
        let successor = PluginIngressPeer.Process(processID: 101, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0)
        let successorPeer = try #require(PluginIngressPeer.capture(peerPID: 101, userID: 501, inspect: { $0 == 101 ? successor : nil }))
        #expect(!context.accepts(detected: detected, peer: successorPeer, runtimeID: { _ in successor.runtimeID }))
        #expect(!context.accepts(detected: nil, peer: successorPeer, runtimeID: { _ in nil }))
        #expect(!context.accepts(detected: .init(path: "/repo", pluginID: "claude-code", processIDs: ["101"]), peer: peer, runtimeID: { _ in process.runtimeID }))
    }
}
