#if os(macOS)
    import CtrlxNetworking
    import Foundation

    /// Builds the Host→Viewer pane snapshot without refreshing tmux or mutating
    /// either observable Host model. Topology refresh and UI publication belong
    /// to the existing discovery paths; a Viewer read must stay a read.
    @MainActor
    enum HostSessionStateSnapshot {
        nonisolated static func workspaceIdentity(hostID: UUID?, panes: [String: PaneState]) -> WorkspaceIdentityScope? {
            guard let hostID else { return nil }
            let servers = Set(panes.values.compactMap { $0.workspaceIdentity?.serverID })
            guard servers.count <= 1 else { return nil }
            if servers.isEmpty && !panes.isEmpty {
                return nil
            }
            return .init(hostID: hostID, serverID: servers.first)
        }

        static func make(
            windowManager: MirrorWindowManager,
            editorManager: EditorSessionManager
        ) -> [String: PaneState] {
            var paneStates = windowManager.paneStates
            for (paneId, var state) in paneStates {
                state.editorSession = editorManager.editorSessionInfo(for: paneId)
                paneStates[paneId] = state
            }
            return paneStates
        }
    }
#endif
