import CtrlxCommon
import CtrlxNetworking

struct IOSPendingAttention: Identifiable {
    enum Status: String {
        case reply = "Needs reply"
        case approval = "Needs approval"
        case waiting = "Waiting"
        case completed = "Completed"

        init(_ state: AgentState?) {
            switch state {
            case .awaitingReplies: self = .reply
            case .awaitingPermission,
                 .awaitingPlanApproval: self = .approval
            case .doneWorking: self = .completed
            default: self = .waiting
            }
        }
    }

    let id: PaneKey
    let agentID: AgentID?
    let hostName: String
    let sessionName: String
    let tabName: String
    let status: Status

    static func items(
        hosts: [PairedHost], paneStates: [PaneKey: PaneState], catalogs: [String: ViewerWorkspaceCatalog]
    ) -> [Self] {
        let panesByHost = Dictionary(grouping: paneStates, by: \.key.pairId)
        return hosts.flatMap { host in
            let panes = panesByHost[host.id, default: []].map(\.value)
            let catalog = catalogs[host.id]
            let hostName = host.displayName(showUsername: host.hasDuplicateName(in: hosts))
            let windows = TmuxWindow.groupPanes(panes)
            let windowCounts = Dictionary(grouping: windows, by: \.sessionName).mapValues { sessionWindows in
                Dictionary(grouping: sessionWindows, by: \.windowName).mapValues(\.count)
            }
            let splitPaneNumbers = Dictionary(uniqueKeysWithValues: windows.filter { !$0.isSinglePane }.flatMap { window in
                window.panes.enumerated().map { ($0.element.paneId, $0.offset + 1) }
            })
            return panes.pendingAttentionPanes.sorted {
                ($0.sessionName, $0.windowIndex, $0.paneIndex) < ($1.sessionName, $1.windowIndex, $1.paneIndex)
            }.map { pane in
                let agentID: AgentID? = if
                    let catalog, catalog.pairID == host.id, let identity = pane.workspaceIdentity,
                    let route = catalog.routes[identity.paneID], route.identity == identity, route.paneID == pane.paneId {
                    AgentID(hostID: catalog.scope.hostID, paneID: identity.paneID)
                } else {
                    nil
                }
                let tab: String = if pane.windowName.isEmpty {
                    "Window \(pane.windowIndex)"
                } else if (windowCounts[pane.sessionName]?[pane.windowName] ?? 0) > 1 {
                    "\(pane.windowName) · Window \(pane.windowIndex)"
                } else {
                    pane.windowName
                }
                let tabName = splitPaneNumbers[pane.paneId].map { "\(tab) · Pane \($0)" } ?? tab
                return Self(
                    id: PaneKey(pairId: host.id, paneId: pane.paneId), agentID: agentID, hostName: hostName,
                    sessionName: pane.sessionName, tabName: tabName, status: Status(pane.agentSession?.state)
                )
            }
        }
    }

    static func directTarget(in items: [Self], connectedHostIDs: Set<String>) -> Self? {
        guard
            items.count == 1, let item = items.first, item.agentID != nil,
            connectedHostIDs.contains(item.id.pairId) else { return nil }
        return item
    }
}
