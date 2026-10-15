import CtrlxNetworking
import Foundation

/// Selection uses only Host-provided paths. Viewers never resolve those paths
/// against their own filesystem; their caller supplies one Host's repositories.
public struct WorktreeStatusSelection: Sendable {
    public let repositories: [RepositoryWorktreeStatus]
    public let pending: [WorktreeMergeStatus]
    public let hasUnavailableStatus: Bool

    public init(repositories: [RepositoryWorktreeStatus], paths: Set<String>? = nil) {
        self.repositories = repositories.filter { repository in
            paths == nil || repository.worktrees.contains { paths?.contains($0.path) == true }
        }
        let selected = self.repositories.flatMap(\.worktrees).filter { paths == nil || paths?.contains($0.path) == true }
        self.pending = selected.filter { ($0.pendingCommitCount ?? 0) > 0 }
        self.hasUnavailableStatus = selected.contains { $0.pendingCommitCount == nil }
            || self.repositories.contains { $0.unavailableReason != nil }
    }

    public var badgeText: String? {
        if pending.count == 1, let worktree = pending.first, let count = worktree.pendingCommitCount {
            return "\(worktree.branch ?? "Worktree") · \(count) to main"
        }
        if !pending.isEmpty {
            return "\(pending.count) worktrees to merge"
        }
        return hasUnavailableStatus ? "Worktree status unavailable" : nil
    }
}
