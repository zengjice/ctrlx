import CtrlxCommon
import CtrlxNetworking
import SwiftUI

struct TerminalContentMenuTarget: Equatable, Sendable {
    let hostID: String?
    let paneID: String
    let sessionName: String
    let windowID: String
    let directory: String?
    let workspacePane: WorkspacePaneIdentity?

    init?(hostID: String?, pane: PaneState) {
        guard !pane.sessionName.isEmpty else { return nil }
        self.hostID = hostID
        self.paneID = pane.paneId
        self.sessionName = pane.sessionName
        self.windowID = pane.stableWindowId
        self.directory = pane.currentPath
        self.workspacePane = pane.workspaceIdentity
    }

    func matches(hostID: String?, pane: PaneState?) -> Bool {
        self.hostID == hostID && pane?.paneId == paneID && pane?.sessionName == sessionName
            && pane?.stableWindowId == windowID && pane?.workspaceIdentity == workspacePane
    }
}

private struct TerminalContentMenuKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String?, String) -> [ContextMenuItem])? = nil
}

extension EnvironmentValues {
    var terminalContentMenu: (@MainActor (String?, String) -> [ContextMenuItem])? {
        get { self[TerminalContentMenuKey.self] }
        set { self[TerminalContentMenuKey.self] = newValue }
    }
}
