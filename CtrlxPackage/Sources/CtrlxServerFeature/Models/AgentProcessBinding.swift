import CtrlxNetworking
import Foundation

/// A live process in a persistent terminal. Window placement and display names
/// are not identity; a restarted process in the same pane is a new binding.
struct AgentProcessBinding: Sendable {
    let paneID: String
    let workspacePane: WorkspacePaneIdentity
    let pluginID: String
    let processID: String
    let runtimeID: String

    init?(paneID: String, workspacePane: WorkspacePaneIdentity, detected: TmuxService.DetectedAgentPane, runtimeID: (String) -> String?) {
        guard
            detected.processIDs.count == 1, let pid = detected.processIDs.first,
            let runtime = runtimeID(pid) else { return nil }
        self.paneID = paneID
        self.workspacePane = workspacePane
        self.pluginID = detected.pluginID
        self.processID = pid
        self.runtimeID = runtime
    }

    func matches(_ instance: AgentWorkflowInstance) -> Bool {
        paneID == instance.paneID && workspacePane.isSamePane(as: instance.workspacePane)
            && pluginID == instance.pluginID && processID == String(instance.processID)
            && runtimeID == instance.processRuntimeID
    }

    func matches(_ identity: AgentSessionIdentity) -> Bool {
        paneID == identity.source.paneID && workspacePane.isSamePane(as: identity.source.workspaceIdentity)
            && pluginID == identity.source.pluginID && processID == identity.processID
            && runtimeID == identity.runtimeID
    }
}
