import CtrlxNetworking
import Foundation

/// Conversation ownership is separate from the process allowed to execute now.
struct AgentResourceIdentity: Equatable, Sendable {
    let hostID: UUID
    let serverID: String
    let paneID: UUID
    let pluginID: String
    let conversationID: String
    /// Human grants remain scoped to the session that authorized them.
    let authorizationSessionID: UUID

    init(hostID: UUID, pane: WorkspacePaneIdentity, pluginID: String, conversationID: String) {
        self.hostID = hostID
        self.serverID = pane.serverID
        self.paneID = pane.paneID
        self.pluginID = pluginID
        self.conversationID = conversationID
        self.authorizationSessionID = pane.sessionID
    }

    /// Length prefixes keep the native bridge key unambiguous. Versions, names,
    /// working directories and movable window/session IDs are not identities.
    var key: String {
        [hostID.uuidString, serverID, paneID.uuidString, pluginID, conversationID]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }
}
