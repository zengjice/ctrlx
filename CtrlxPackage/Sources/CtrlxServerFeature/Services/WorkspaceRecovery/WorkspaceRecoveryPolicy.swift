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
}
