import Foundation
import Testing
@testable import CtrlxNetworking

struct WorktreeStatusWireTests {
    @Test("Worktree metadata survives pairing rewrite and old snapshots remain decodable", arguments: ["main", "master"])
    func snapshot(baseBranch: String) throws {
        let repo = RepositoryWorktreeStatus(id: "/repo/.git", worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 3, baseBranch: baseBranch)], baseBranch: baseBranch)
        let pane = PaneState(paneId: "%1", gitWorktreePath: "/repo/ux")
        let state = SessionStateMessage(pairId: "a", paneStates: [pane.id: pane], worktreeRepositories: [repo])
        let data = try JSONEncoder().encode(state.withPairId("b"))
        let copy = try JSONDecoder().decode(SessionStateMessage.self, from: data)
        #expect(copy.pairId == "b")
        #expect(copy.worktreeRepositories == [repo])
        #expect(copy.paneStates["%1"]?.gitWorktreePath == "/repo/ux")

        var oldJSON = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldJSON.removeValue(forKey: "worktreeRepositories")
        var panes = try #require(oldJSON["paneStates"] as? [String: [String: Any]])
        panes["%1"]?.removeValue(forKey: "gitWorktreePath")
        oldJSON["paneStates"] = panes
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(old.worktreeRepositories == nil)
        #expect(old.paneStates["%1"]?.gitWorktreePath == nil)
    }

    @Test("Older Hosts omit the base branch; unavailable comparisons remain unavailable")
    func legacyBaseBranch() throws {
        let data = Data(#"{"id":"repo","worktrees":[{"path":"/repo/ux","branch":"ux","pendingCommitCount":3}]}"#.utf8)
        let legacy = try JSONDecoder().decode(RepositoryWorktreeStatus.self, from: data)
        #expect(legacy.baseBranch == nil)
        #expect(legacy.worktrees.first?.pendingCommitCount == 3)
        let ambiguous = RepositoryWorktreeStatus(id: "repo", worktrees: [
            .init(path: "/repo/ux", branch: "ux", unavailableReason: "Both main and master exist"),
        ], unavailableReason: "Both main and master exist", baseBranch: nil)
        #expect(try JSONDecoder().decode(RepositoryWorktreeStatus.self, from: JSONEncoder().encode(ambiguous)) == ambiguous)
    }

    @Test("Older Viewers cannot mistake master comparisons for main comparisons", arguments: [0, 3])
    func legacyViewer(count: Int) throws {
        struct LegacyWorktree: Decodable {
            let pendingCommitCount: Int?
        }
        for base in ["main", "master"] {
            let worktree = WorktreeMergeStatus(path: "/repo/feature", branch: "feature", pendingCommitCount: count, baseBranch: base)
            let data = try JSONEncoder().encode(worktree)
            let old = try JSONDecoder().decode(LegacyWorktree.self, from: data)
            #expect(old.pendingCommitCount == (base == "main" ? count : nil))
            #expect(try JSONDecoder().decode(WorktreeMergeStatus.self, from: data).pendingCommitCount == count)
        }
    }
}
