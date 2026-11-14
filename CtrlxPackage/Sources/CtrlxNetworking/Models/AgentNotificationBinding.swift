import Foundation

/// Frozen execution evidence for a notification action. Navigation uses only
/// agentID, but an answer must still belong to the original running conversation.
public struct AgentNotificationBinding: Codable, Sendable, Equatable {
    public let agentID: AgentID
    public let pluginID: String
    public let conversationID: String
    public let runtimeID: String

    public init?(agentID: AgentID, pane: PaneState) {
        guard
            let session = pane.agentSession, let runtime = session.processRuntimeID, !runtime.isEmpty,
            let conversation = pane.claudeSessionID, !conversation.isEmpty,
            pane.workspaceIdentity?.paneID == agentID.paneID else { return nil }
        self.agentID = agentID
        self.pluginID = session.pluginID
        self.conversationID = conversation
        self.runtimeID = runtime
    }

    public func matches(agentID: AgentID?, pane: PaneState?) -> Bool {
        guard let pane else { return false }
        return self.agentID == agentID && pane.workspaceIdentity?.paneID == self.agentID.paneID
            && pane.agentSession?.pluginID == pluginID && pane.agentSession?.processRuntimeID == runtimeID
            && pane.claudeSessionID == conversationID
    }
}
