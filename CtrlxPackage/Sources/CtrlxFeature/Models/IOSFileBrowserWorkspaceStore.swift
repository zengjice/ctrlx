import CtrlxCommon
import CtrlxNetworking
import Observation

/// Client presentation cache. Only Host descriptors decide identity and lifetime.
@MainActor @Observable
final class IOSFileBrowserWorkspaceStore {
    private struct Key: Hashable {
        let hostID: String
        let sessionName: String
    }

    private var workspaces: [Key: IOSFileBrowserWorkspace] = [:]
    @ObservationIgnored private var clients: [String: ViewerRelayClient] = [:]

    func workspace(hostID: String, sessionName: String) -> IOSFileBrowserWorkspace? {
        workspaces[Key(hostID: hostID, sessionName: sessionName)]
    }

    func update(_ state: SessionStateMessage, client: ViewerRelayClient) {
        clients[state.pairId] = client
        let retained = Dictionary(
            workspaces.filter { $0.key.hostID == state.pairId }.values
                .flatMap(\.tabs).filter { $0.hostTab != nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessions = Dictionary(grouping: TmuxWindow.groupPanes(Array(state.paneStates.values)), by: \.sessionName)
        for (sessionName, windows) in sessions where !sessionName.isEmpty {
            let key = Key(hostID: state.pairId, sessionName: sessionName)
            let workspace: IOSFileBrowserWorkspace
            if let existing = workspaces[key] {
                workspace = existing
            } else {
                workspace = IOSFileBrowserWorkspace()
                workspaces[key] = workspace
            }
            workspace.syncHostTabs((state.fileTabs ?? []).filter { $0.sessionName == sessionName }, retained: retained)
            for tab in workspace.tabs where tab.hostTab == nil {
                tab.reconcileSource(windows: windows)
            }
        }
        for key in workspaces.keys.filter({ $0.hostID == state.pairId && sessions[$0.sessionName] == nil }) {
            remove(key)
        }
    }

    func suspendHost(_ hostID: String) {
        for (key, workspace) in workspaces where key.hostID == hostID {
            workspace.selectedID = nil
            for tab in workspace.tabs {
                tab.releasePreview()
            }
        }
    }

    func removeHost(_ hostID: String) {
        for key in workspaces.keys.filter({ $0.hostID == hostID }) {
            remove(key)
        }
        clients.removeValue(forKey: hostID)
    }

    func retainHosts(_ hostIDs: Set<String>) {
        for hostID in clients.keys.filter({ !hostIDs.contains($0) }) {
            removeHost(hostID)
        }
    }

    private func remove(_ key: Key) {
        guard let workspace = workspaces.removeValue(forKey: key) else { return }
        workspace.save()
        for tab in workspace.tabs {
            if tab.hostTab == nil {
                tab.reconcileSource(windows: [])
            }
            tab.releasePreview()
        }
    }
}
