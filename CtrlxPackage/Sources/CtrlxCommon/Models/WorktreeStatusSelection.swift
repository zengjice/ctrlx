import CtrlxNetworking
import Foundation

/// Selection uses only Host-provided paths. Viewers never resolve those paths
/// against their own filesystem; their caller supplies one Host's repositories.
public struct WorktreeStatusSelection: Sendable {
    public enum Status: Sendable {
        case pending
        case merged
        case unavailable
    }

    public let repositories: [RepositoryWorktreeStatus]
    /// Session details include only worktrees referenced by the session's panes.
    public let selectedRepositories: [RepositoryWorktreeStatus]
    public let pending: [WorktreeMergeStatus]
    public let hasUnavailableStatus: Bool

    public init(repositories: [RepositoryWorktreeStatus], paths: Set<String>? = nil) {
        self.repositories = repositories.filter { repository in
            paths == nil || repository.worktrees.contains { paths?.contains($0.path) == true }
        }
        self.selectedRepositories = self.repositories.map { repository in
            RepositoryWorktreeStatus(
                id: repository.id,
                worktrees: repository.worktrees.filter { paths == nil || paths?.contains($0.path) == true },
                unavailableReason: repository.unavailableReason,
                baseBranch: repository.baseBranch
            )
        }
        let selected = selectedRepositories.flatMap(\.worktrees)
        self.pending = selected.filter { ($0.pendingCommitCount ?? 0) > 0 }
        self.hasUnavailableStatus = selected.contains { $0.pendingCommitCount == nil }
            || self.repositories.contains { $0.unavailableReason != nil }
    }

    public var status: Status? {
        guard !repositories.isEmpty else { return nil }
        if !pending.isEmpty {
            return .pending
        }
        return hasUnavailableStatus ? .unavailable : .merged
    }

    public var statusDescription: String {
        if let badgeText {
            return !pending.isEmpty && hasUnavailableStatus ? "\(badgeText) · Some comparisons unavailable" : badgeText
        }
        guard !repositories.isEmpty else { return "No Git worktrees" }
        let bases = Set(repositories.map { $0.baseBranch ?? "main" }).sorted().joined(separator: "/")
        return "No commits pending merge into local \(bases)"
    }

    public var badgeText: String? {
        if pending.count == 1, let worktree = pending.first, let count = worktree.pendingCommitCount {
            let base = repositories.first { $0.worktrees.contains { $0.path == worktree.path } }?.baseBranch ?? "main"
            return "\(worktree.branch ?? "Worktree") · \(count) to \(base)"
        }
        if !pending.isEmpty {
            return "\(pending.count) worktrees to merge"
        }
        return hasUnavailableStatus ? "Worktree status unavailable" : nil
    }
}
