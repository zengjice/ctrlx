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

    static func notification(paneID: String, hostID: String, paneStates: [PaneKey: PaneState]) -> Self? {
        guard let pane = paneStates[PaneKey(pairId: hostID, paneId: paneID)], !pane.sessionName.isEmpty else { return nil }
        return .init(sessionName: pane.sessionName, hostId: hostID, paneSelection: .init(paneID: paneID))
    }
}
