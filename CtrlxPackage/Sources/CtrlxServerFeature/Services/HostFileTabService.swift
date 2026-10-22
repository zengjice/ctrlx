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
    @ObservationIgnored private var sourceIdentities: [UUID: WorkspacePaneIdentity] = [:]
    @ObservationIgnored private var routes: [String: [PaneInfo]] = [:]
    @ObservationIgnored private var routeRevision: UInt64 = 0

    func open(sessionName: String, paneID: String, new: Bool = false, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> HostFileTab {
        guard let resolvePane else { throw FileBrowserError.message("Host Files is unavailable.") }
        let revision = routeRevision
        let pane = try await resolvePane(sessionName, paneID)
        try Task.checkCancellation()
        if let expectedWorkspacePane, !expectedWorkspacePane.isSamePane(as: pane.workspaceIdentity) {
            throw FileBrowserError.message("The source terminal changed. Select it again to open Files.")
        }
        // A newer published snapshot wins over an earlier, suspended source query.
        if revision != routeRevision {
            guard
                let matches = routes[paneID], matches.count == 1, let current = matches.first,
                current.workspaceIdentity == pane.workspaceIdentity,
                current.sessionName == pane.sessionName, current.stableWindowId == pane.stableWindowId else {
                throw FileBrowserError.message("The source terminal changed while opening Files. Try again.")
            }
        }
        tabs.removeAll { tab in
            tab.sourcePaneID == paneID && sourceIdentities[tab.id].map { !$0.isSamePane(as: pane.workspaceIdentity) } == true
        }
        let retainedIDs = Set(tabs.map(\.id))
        sourceIdentities = sourceIdentities.filter { retainedIDs.contains($0.key) }
        // There is no await between lookup and insertion: simultaneous opens share one default.
        if !new, let index = tabs.firstIndex(where: { $0.sourcePaneID == paneID && $0.group == .human && $0.isPrimary }) {
            let previous = tabs[index]
            tabs[index].sessionName = pane.sessionName
            tabs[index].windowID = pane.stableWindowId
            sourceIdentities[previous.id] = pane.workspaceIdentity
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
        sourceIdentities[tab.id] = pane.workspaceIdentity
        onChange?()
        return tab
    }

    func close(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id == id }
        sourceIdentities.removeValue(forKey: id)
        onChange?()
    }

    /// Only the Host's recovery coordinator may rebuild shared Files identities.
    /// Viewer layout seeding still cannot recreate a Host-owned tab.
    func restore(_ saved: [WorkspaceRecoveryFileTab], sessions: [WorkspaceRecoverySession], serverID: String?) {
        guard let serverID else { return }
        var changed = false
        for record in saved where !tabs.contains(where: { $0.id == record.id }) {
            guard
                let session = sessions.first(where: { $0.id == record.sessionID }),
                let window = session.windows.first(where: { $0.id == record.windowID }),
                let pane = window.panes.first(where: { $0.id == record.paneID }) else { continue }
            tabs.append(HostFileTab(
                id: record.id,
                sessionName: session.name,
                windowID: window.runtimeID,
                sourcePaneID: pane.runtimeID,
                group: record.group,
                isPrimary: record.isPrimary,
                initialDirectory: record.initialDirectory
            ))
            sourceIdentities[record.id] = .init(serverID: serverID, sessionID: session.id, windowID: window.id, paneID: pane.id)
            changed = true
        }
        if changed {
            onChange?()
        }
    }

    func updateRoutes(_ panes: [PaneInfo]) {
        let previous = tabs
        let byPane = Dictionary(grouping: panes, by: \.paneId)
        routes = byPane
        routeRevision &+= 1
        tabs = tabs.compactMap { tab in
            // Linked-session ambiguity must not route a tab into an arbitrary session.
            guard let matches = byPane[tab.sourcePaneID], matches.count == 1, let pane = matches.first else { return nil }
            if let identity = sourceIdentities[tab.id], !identity.isSamePane(as: pane.workspaceIdentity) {
                return nil
            }
            sourceIdentities[tab.id] = pane.workspaceIdentity
            var routed = tab
            routed.sessionName = pane.sessionName
            routed.windowID = pane.stableWindowId
            return routed
        }
        let retainedIDs = Set(tabs.map(\.id))
        sourceIdentities = sourceIdentities.filter { retainedIDs.contains($0.key) }
        if tabs != previous {
            onChange?()
        }
    }

    func handle(_ operation: FileBrowserTabOperation, paneID: String, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> FileBrowserResponse {
        switch operation {
        case let .open(sessionName, new):
            return try .tab(await open(sessionName: sessionName, paneID: paneID, new: new, expectedWorkspacePane: expectedWorkspacePane))
        case let .close(id):
            close(id)
            return .tabClosed
        }
    }
}
