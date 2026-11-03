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
        let changedConversation = source.map { current in
            if let saved = pane.agent {
                return current.pluginID != saved.pluginID || current.sessionID != saved.sessionID
            }
            if let saved = pane.agentIdentity?.source {
                return current.pluginID != saved.pluginID || current.sessionID != saved.sessionID
            }
            return false
        } ?? false
        let changedPlugin = detected.map { current in
            (pane.agent?.pluginID ?? pane.agentIdentity?.source.pluginID).map { $0 != current.pluginID } ?? false
        } ?? false
        let changedProcess = pane.agentIdentity.map { saved in
            detected.map {
                ($0.processIDs.count == 1 && $0.processIDs != [saved.processID])
                    || ($0.processIDs.contains(saved.processID) && runtimeID(saved.processID).map { $0 != saved.runtimeID } == true)
            } ?? false
        } ?? false
        let ended = scanAvailable && detected == nil && state.agentSession == nil
            && (pane.agentIdentity.map { runtimeID($0.processID) != $0.runtimeID } ?? true)
        guard changedConversation || changedPlugin || changedProcess || ended else { return false }
        pane.savedAgentIdentityInvalidated = true
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
        recordIdentity(identity, in: &pane)
        pane.unavailableAgentReason = nil
    }

    static func recordIdentity(_ identity: AgentSessionIdentity, in pane: inout WorkspaceRecoveryPane) {
        pane.agentIdentity = identity
        pane.savedAgentIdentityInvalidated = nil
    }
}
