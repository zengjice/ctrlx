import CtrlxNetworking
import CtrlxPluginProtocol

/// A failed observation is not evidence that the saved conversation ended.
enum WorkspaceAgentCapture {
    static func invalidateChangedAgent(
        _ pane: inout WorkspaceRecoveryPane, state: PaneState,
        detected: TmuxService.DetectedAgentPane?, scanAvailable: Bool,
        runtimeID: (String) -> String?
    ) -> Bool {
        let source = AgentForkSource(pane: state)
        let changedConversation = pane.agent.map { saved in
            source.map { $0.pluginID != saved.pluginID || $0.sessionID != saved.sessionID } ?? false
        } ?? false
        let changedProcess = pane.agentIdentity.map { saved in
            detected.map {
                $0.pluginID != saved.source.pluginID
                    || ($0.processIDs.count == 1 && $0.processIDs != [saved.processID])
                    || ($0.processIDs.contains(saved.processID) && runtimeID(saved.processID).map { $0 != saved.runtimeID } == true)
            } ?? false
        } ?? false
        let ended = scanAvailable && detected == nil && state.agentSession == nil
            && (pane.agentIdentity.map { runtimeID($0.processID) != $0.runtimeID } ?? true)
        guard changedConversation || changedProcess || ended else { return false }
        pane.agent = nil
        pane.agentIdentity = nil
        pane.unavailableAgentReason = nil
        return true
    }

    static func recordFailure(_ reason: String, in pane: inout WorkspaceRecoveryPane) {
        pane.unavailableAgentReason = reason
    }

    static func record(_ descriptor: AgentResumeDescriptor, identity: AgentSessionIdentity, in pane: inout WorkspaceRecoveryPane) {
        pane.agent = descriptor
        pane.agentIdentity = identity
        pane.unavailableAgentReason = nil
    }
}
