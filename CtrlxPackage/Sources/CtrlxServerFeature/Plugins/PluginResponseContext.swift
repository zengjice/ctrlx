import CtrlxNetworking
import Foundation

/// A response keeps its original destination while the core translates it and
/// awaits text/key delivery. Native actor calls inherit this task-local value;
/// the sidecar adapter carries it across its ordered RPC notification stream.
struct PluginResponseContext: Sendable {
    @TaskLocal static var current: PluginResponseContext?

    let pluginID: String
    let paneID: String
    let workspaceIdentity: WorkspacePaneIdentity?
    let agentPluginID: String?
    let conversationID: String?
    let requestID: String?

    init(pluginID: String, pane: PaneState, requestID: String?, expectedWorkspacePane: WorkspacePaneIdentity? = nil) throws {
        self.pluginID = pluginID
        self.paneID = pane.paneId
        self.workspaceIdentity = expectedWorkspacePane ?? pane.workspaceIdentity
        self.agentPluginID = pane.agentSession?.pluginID
        self.conversationID = pane.claudeSessionID
        self.requestID = requestID
        guard agentPluginID == nil || agentPluginID == pluginID else { throw Failure.changed }
        try validate(pluginID: pluginID, paneID: paneID, pane: pane)
    }

    func validate(pluginID: String, paneID: String, pane: PaneState?) throws {
        try Task.checkCancellation()
        guard
            let pane,
            self.pluginID == pluginID, self.paneID == paneID,
            workspaceIdentity?.isSamePane(as: pane.workspaceIdentity) ?? (pane.workspaceIdentity == nil),
            agentPluginID == pane.agentSession?.pluginID,
            conversationID == pane.claudeSessionID,
            requestID == nil || requestID == pane.agentSession?.state.openForm?.requestID else {
            throw Failure.changed
        }
    }

    enum Failure: LocalizedError {
        case changed
        var errorDescription: String? {
            "The Agent request or terminal changed before the response was delivered."
        }
    }
}
