import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

/// Only identity and routing are shared. A client's directory/preview never drives another client.
@MainActor @Observable
final class HostFileTabService {
    private(set) var tabs: [HostFileTab] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var resolvePane: ((String, String) async throws -> PaneInfo)?
    @ObservationIgnored var projectDirectory: (String) -> String? = { _ in nil }

    func open(sessionName: String, paneID: String, new: Bool = false) async throws -> HostFileTab {
        guard let resolvePane else { throw FileBrowserError.message("Host Files is unavailable.") }
        let pane = try await resolvePane(sessionName, paneID)
        try Task.checkCancellation()
        // There is no await between lookup and insertion: simultaneous opens share one default.
        if !new, let index = tabs.firstIndex(where: { $0.sourcePaneID == paneID && $0.group == .human && $0.isPrimary }) {
            let previous = tabs[index]
            tabs[index].sessionName = pane.sessionName
            tabs[index].windowID = pane.stableWindowId
            if previous != tabs[index] {
                onChange?()
            }
            return tabs[index]
        }
        guard tabs.filter({ $0.sessionName == sessionName }).count < 30 else {
            throw FileBrowserError.message("Close a Files tab before opening another folder.")
        }
        let tab = HostFileTab(
            sessionName: pane.sessionName,
            windowID: pane.stableWindowId,
            sourcePaneID: paneID,
            isPrimary: !new,
            initialDirectory: projectDirectory(paneID) ?? pane.currentPath
        )
        tabs.append(tab)
        onChange?()
        return tab
    }

    func close(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id == id }
        onChange?()
    }

    func updateRoutes(_ panes: [PaneInfo]) {
        let previous = tabs
        let byPane = Dictionary(grouping: panes, by: \.paneId)
        tabs = tabs.compactMap { tab in
            // Linked-session ambiguity must not route a tab into an arbitrary session.
            guard let matches = byPane[tab.sourcePaneID], matches.count == 1, let pane = matches.first else { return nil }
            var routed = tab
            routed.sessionName = pane.sessionName
            routed.windowID = pane.stableWindowId
            return routed
        }
        if tabs != previous {
            onChange?()
        }
    }

    func handle(_ operation: FileBrowserTabOperation, paneID: String) async throws -> FileBrowserResponse {
        switch operation {
        case let .open(sessionName, new):
            return try .tab(await open(sessionName: sessionName, paneID: paneID, new: new))
        case let .close(id):
            close(id)
            return .tabClosed
        }
    }
}
