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

    @Test("A session badge counts each worktree once and opens the full repository")
    func selection() {
        let selection = WorktreeStatusSelection(repositories: [repository], paths: Set(["/repo/ux", "/repo/ux"]))
        #expect(selection.badgeText == "ux · 3 to main")
        #expect(selection.repositories == [repository])
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo"]).badgeText == nil)
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo/ux", "/repo/other"]).badgeText == "2 worktrees to merge")
        #expect(WorktreeStatusSelection(repositories: [repository], paths: ["/repo/ux-extra"]).repositories.isEmpty)
        let unknown = RepositoryWorktreeStatus(id: "unknown", worktrees: [.init(path: "/unknown", branch: nil, unavailableReason: "Detached")])
        #expect(WorktreeStatusSelection(repositories: [unknown]).hasUnavailableStatus)
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
