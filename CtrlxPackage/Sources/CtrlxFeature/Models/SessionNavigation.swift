import CtrlxCommon
import CtrlxNetworking
import Foundation

struct SessionNavigation: Hashable, Sendable {
    struct PaneSelection: Hashable, Sendable {
        let paneID: String
        let id = UUID()
    }

    let sessionName: String
    let hostId: String
    var reference: ViewerWorkspaceReference? = nil
    var restoresSelection = false
    var paneSelection: PaneSelection? = nil

    static func notification(agentID: AgentID?, hostID: String, catalog: ViewerWorkspaceCatalog?) -> Self? {
        guard let agentID, let catalog, let route = catalog.resolve(agentID: agentID, pairID: hostID).value else { return nil }
        return .init(sessionName: route.sessionName, hostId: hostID, reference: catalog.reference(paneID: route.paneID), paneSelection: .init(paneID: route.paneID))
    }
}
