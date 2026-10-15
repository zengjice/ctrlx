import Foundation

/// A Host-owned Git snapshot. Counts compare commit ancestry with a local base branch,
/// not the remote upstream, working copy, or patch equivalence.
public struct RepositoryWorktreeStatus: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let worktrees: [WorktreeMergeStatus]
    public let unavailableReason: String?
    /// Older Hosts omit this field and compare successful counts with main.
    public let baseBranch: String?

    public init(id: String, worktrees: [WorktreeMergeStatus], unavailableReason: String? = nil, baseBranch: String? = "main") {
        self.id = id
        self.worktrees = worktrees
        self.unavailableReason = unavailableReason
        self.baseBranch = baseBranch
    }
}

public struct WorktreeMergeStatus: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let branch: String?
    public let unavailableReason: String?
    // The original wire key means main to older Viewers. Keep other bases in
    // an additive field so those Viewers show unavailable, never a wrong count.
    private let pendingMainCommitCount: Int?
    private let pendingBaseCommitCount: Int?

    public var pendingCommitCount: Int? {
        pendingBaseCommitCount ?? pendingMainCommitCount
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case branch
        case unavailableReason
        case pendingMainCommitCount = "pendingCommitCount"
        case pendingBaseCommitCount
    }

    public var id: String {
        path
    }

    public init(path: String, branch: String?, pendingCommitCount: Int? = nil, unavailableReason: String? = nil, baseBranch: String = "main") {
        self.path = path
        self.branch = branch
        self.pendingMainCommitCount = baseBranch == "main" ? pendingCommitCount : nil
        self.pendingBaseCommitCount = baseBranch == "main" ? nil : pendingCommitCount
        self.unavailableReason = unavailableReason
    }
}
