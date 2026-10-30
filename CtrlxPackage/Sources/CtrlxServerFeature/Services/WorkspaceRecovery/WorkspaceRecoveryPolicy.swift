import Foundation

enum WorkspaceRecoveryPolicy {
    enum Action: Equatable {
        case observe
        case restore
        case offerRestore
        case disabled
    }

    /// Caller must first obtain a successful tmux read. A read error is never an
    /// empty state and must not be passed to this policy as a missing server.
    static func startup(snapshot: WorkspaceRecoverySnapshot?, live: WorkspaceTmuxState, bootID: String, mode: WorkspaceRecoveryMode) -> Action {
        guard mode != .disabled else { return .disabled }
        guard let snapshot, !snapshot.sessions.isEmpty else { return .observe }
        if snapshot.recovery != nil {
            return .restore
        }
        if snapshot.bootID != bootID {
            return .restore
        }
        if snapshot.serverID == live.serverID {
            return .observe
        }
        // A server restart in the same OS boot is not authorization to replay
        // deleted sessions. Keep the snapshot and offer an explicit recovery.
        return .offerRestore
    }

    static func containsSavedStructure(_ sessions: [WorkspaceRecoverySession], live: WorkspaceTmuxState) -> Bool {
        guard live.incompleteSessionIDs.isEmpty, live.incompleteWindowIDs.isEmpty else { return false }
        return sessions.allSatisfy { saved in
            guard let session = live.sessions.first(where: { $0.id == saved.id }) else { return false }
            return saved.windows.allSatisfy { window in
                guard let current = session.windows.first(where: { $0.id == window.id && $0.index == window.index }) else { return false }
                return Set(window.panes.map(\.id)).isSubset(of: Set(current.panes.map(\.id)))
            }
        }
    }
}
