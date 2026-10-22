import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct WorktreeStatusSelectionTests {
    private let repository = RepositoryWorktreeStatus(id: "/repo/.git", worktrees: [
        .init(path: "/repo", branch: "main", pendingCommitCount: 0),
        .init(path: "/repo/ux", branch: "ux", pendingCommitCount: 3),
        .init(path: "/repo/other", branch: "other", pendingCommitCount: 2),
    ])

    @Test("A session badge and its detail rows include only the session's worktrees")
    func selection() {
        let selection = WorktreeStatusSelection(repositories: [repository], paths: Set(["/repo/ux", "/repo/ux"]))
        #expect(selection.badgeText == "ux · 3 to main")
        #expect(selection.repositories == [repository])
        #expect(selection.selectedRepositories == [RepositoryWorktreeStatus(
            id: repository.id,
            worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 3)]
        )])
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo"]).badgeText == nil)
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo/ux", "/repo/other"]).badgeText == "2 worktrees to merge")
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo/ux-extra"]).repositories.isEmpty)
        let unknown = RepositoryWorktreeStatus(id: "unknown", worktrees: [.init(path: "/unknown", branch: nil, unavailableReason: "Detached")])
        #expect(WorktreeStatusSelection(repositories: [unknown]).hasUnavailableStatus)
    }

    @Test("Host and Git overviews retain complete repositories; an empty session selects nothing")
    func overviewScope() {
        let overview = WorktreeStatusSelection(repositories: [repository])
        #expect(overview.repositories == [repository])
        #expect(overview.selectedRepositories == [repository])
        #expect(WorktreeStatusSelection(repositories: [repository], paths: []).selectedRepositories.isEmpty)
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo/ux-extra"]).selectedRepositories.isEmpty)
    }

    @Test("Scoped detail rows preserve repository errors and legacy base metadata")
    func scopedMetadata() {
        let unavailable = RepositoryWorktreeStatus(
            id: repository.id, worktrees: repository.worktrees,
            unavailableReason: "No unique local base branch", baseBranch: nil
        )
        let selection = WorktreeStatusSelection(repositories: [unavailable], paths: ["/repo/ux"])
        #expect(selection.selectedRepositories == [RepositoryWorktreeStatus(
            id: unavailable.id, worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 3)],
            unavailableReason: unavailable.unavailableReason, baseBranch: nil
        )])
    }

    @Test("Compact session status distinguishes pending, merged, unavailable and unrelated worktrees")
    func compactStatus() {
        let unknown = RepositoryWorktreeStatus(id: "/unknown/.git", worktrees: [
            .init(path: "/unknown", branch: nil, unavailableReason: "Detached"),
        ])
        let repositories = [repository, unknown]
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/repo/ux"]).status == .pending)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/repo"]).status == .merged)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/unknown"]).status == .unavailable)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/repo", "/unknown"]).status == .unavailable)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/repo/ux", "/unknown"]).status == .pending)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/elsewhere"]).status == nil)
        #expect(WorktreeStatusSelection(repositories: repositories, paths: []).status == nil)

        let merged = RepositoryWorktreeStatus(id: repository.id, worktrees: [
            .init(path: "/repo/ux", branch: "ux", pendingCommitCount: 0),
        ])
        let selection = WorktreeStatusSelection(repositories: [merged], paths: ["/repo/ux"])
        #expect(selection.status == .merged)
        #expect(selection.statusDescription == "No commits pending merge into local main")
    }

    @Test("Multiple repositories use their own bases and preserve mixed pending, merged and unknown results")
    func mixedRepositories() {
        let master = RepositoryWorktreeStatus(id: "/second/.git", worktrees: [
            .init(path: "/second/fix", branch: "fix", pendingCommitCount: 2, baseBranch: "master"),
            .init(path: "/second/merged", branch: "merged", pendingCommitCount: 0, baseBranch: "master"),
            .init(path: "/second/unknown", branch: nil, unavailableReason: "Detached HEAD"),
        ], baseBranch: "master")
        let repositories = [repository, master]
        let single = WorktreeStatusSelection(repositories: repositories, paths: ["/second/fix", "/repo", "/not-git"])
        #expect(single.badgeText == "fix · 2 to master")
        let multiple = WorktreeStatusSelection(repositories: repositories, paths: Set(["/repo/ux", "/second/fix", "/second/fix"]))
        #expect(multiple.pending.count == 2)
        #expect(multiple.badgeText == "2 worktrees to merge")
        #expect(multiple.selectedRepositories.map(\.id) == [repository.id, master.id])
        #expect(multiple.selectedRepositories.map(\.baseBranch) == ["main", "master"])
        #expect(multiple.selectedRepositories.flatMap(\.worktrees).map(\.path) == ["/repo/ux", "/second/fix"])
        let mixed = WorktreeStatusSelection(repositories: repositories, paths: ["/repo/ux", "/second/merged", "/second/unknown"])
        #expect(mixed.status == .pending)
        #expect(mixed.statusDescription == "ux · 3 to main · Some comparisons unavailable")
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/repo", "/second/unknown"]).status == .unavailable)
        let merged = WorktreeStatusSelection(repositories: repositories, paths: ["/repo", "/second/merged"])
        #expect(merged.status == .merged)
        #expect(merged.statusDescription == "No commits pending merge into local main/master")
        #expect(WorktreeStatusSelection(repositories: repositories, paths: ["/not-git"]).status == nil)
        let legacy = RepositoryWorktreeStatus(id: repository.id, worktrees: repository.worktrees, baseBranch: nil)
        #expect(WorktreeStatusSelection(repositories: [legacy], paths: ["/repo/ux"]).badgeText == "ux · 3 to main")
    }

    @Test("Identical paths on different Hosts stay isolated; downgrade and disconnect clear metadata")
    func hostIsolation() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "a", paneStates: [:], worktreeRepositories: [repository]))
        let other = RepositoryWorktreeStatus(id: repository.id, worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 0)])
        store.handleStateUpdate(.init(pairId: "b", paneStates: [:], worktreeRepositories: [other]))
        #expect(store.worktreeRepositoriesByHost["a"] == [repository])
        #expect(store.worktreeRepositoriesByHost["b"] == [other])
        store.handleStateUpdate(.init(pairId: "a", paneStates: [:]))
        #expect(store.worktreeRepositoriesByHost["a"] == nil)
        #expect(store.worktreeRepositoriesByHost["b"] == [other])
        store.clearSessions(for: "b")
        #expect(store.worktreeRepositoriesByHost.isEmpty)
    }
}
