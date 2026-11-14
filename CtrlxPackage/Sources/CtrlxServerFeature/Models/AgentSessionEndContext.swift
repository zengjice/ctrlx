import CtrlxNetworking
import CtrlxPluginProtocol

/// An end event belongs to a conversation, not to whichever Agent happens to
/// occupy its old pane when the event is delivered.
struct AgentSessionEndContext: Sendable {
    let pane: PaneState
    let pluginID: String
    let conversationID: String

    init?(event: PluginEvent, pane: PaneState) {
        guard
            event.tmuxPane == pane.paneId,
            event.pluginID == pane.agentSession?.pluginID,
            event.sessionID == pane.claudeSessionID else { return nil }
        self.pane = pane
        self.pluginID = event.pluginID
        self.conversationID = event.sessionID
    }

    func matches(_ current: PaneState?) -> Bool {
        guard
            let current, current.paneId == pane.paneId,
            current.agentSession?.pluginID == pluginID,
            current.claudeSessionID == conversationID,
            current.agentSession?.processRuntimeID == pane.agentSession?.processRuntimeID else { return false }
        if let identity = pane.workspaceIdentity {
            return identity.isSamePane(as: current.workspaceIdentity)
        }
        return current.workspaceIdentity == nil && current.sessionName == pane.sessionName && current.stableWindowId == pane.stableWindowId
    }

    func matches(origin: PluginEventOrigin) -> Bool {
        origin.pluginID == pluginID && origin.paneID == pane.paneId
            && origin.conversationID == conversationID
            && origin.workspacePane.isSamePane(as: pane.workspaceIdentity)
            && origin.runtimeID == pane.agentSession?.processRuntimeID
    }

    func accepts(detected: TmuxService.DetectedAgentPane?, peer: PluginIngressPeer?, runtimeID: (String) -> String?) -> Bool {
        guard let detected else {
            // The kernel snapshot survives exit. A late hook from a predecessor
            // cannot end a newer incarnation that has also just stopped.
            guard let peer else { return true } // Native monitors supply a separately checked origin.
            guard let runtime = pane.agentSession?.processRuntimeID else { return false }
            return peer.processes.contains { $0.runtimeID == runtime }
        }
        // A synthetic end is emitted only after process exit. A native end hook
        // can run before exit, but must come from that exact process incarnation.
        guard
            let peer, detected.pluginID == pluginID, detected.processIDs.count == 1,
            let pid = detected.processIDs.first, let number = Int32(pid), let runtime = runtimeID(pid),
            runtime == pane.agentSession?.processRuntimeID else { return false }
        return peer.contains(processID: number, runtimeID: runtime)
    }
}
