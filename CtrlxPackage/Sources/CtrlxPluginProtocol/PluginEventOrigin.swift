import CtrlxNetworking
import Foundation

/// A Host observation retained by a native monitor before process exit. This
/// value is deliberately not Codable; sidecar JSON cannot assert this origin.
public struct PluginEventOrigin: Sendable {
    public let pluginID: String
    public let paneID: String
    public let workspacePane: WorkspacePaneIdentity
    public let conversationID: String
    public let processID: String
    public let runtimeID: String

    public init(pluginID: String, paneID: String, workspacePane: WorkspacePaneIdentity, conversationID: String, processID: String, runtimeID: String) {
        self.pluginID = pluginID
        self.paneID = paneID
        self.workspacePane = workspacePane
        self.conversationID = conversationID
        self.processID = processID
        self.runtimeID = runtimeID
    }
}
