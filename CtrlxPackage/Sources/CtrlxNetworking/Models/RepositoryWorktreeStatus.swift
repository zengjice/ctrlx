import Foundation

/// A Host-owned Git snapshot. Counts compare commit ancestry with local main,
/// not the remote upstream, working copy, or patch equivalence.
public struct RepositoryWorktreeStatus: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let worktrees: [WorktreeMergeStatus]
    public let unavailableReason: String?

    public init(id: String, worktrees: [WorktreeMergeStatus], unavailableReason: String? = nil) {
        self.id = id
        self.worktrees = worktrees
        self.unavailableReason = unavailableReason
    }
}

public struct WorktreeMergeStatus: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let branch: String?
    public let pendingCommitCount: Int?
    public let unavailableReason: String?

    public var id: String {
        path
    }

    public init(path: String, branch: String?, pendingCommitCount: Int? = nil, unavailableReason: String? = nil) {
        self.path = path
        self.branch = branch
        self.pendingCommitCount = pendingCommitCount
        self.unavailableReason = unavailableReason
    }
}
