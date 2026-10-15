import Foundation
import Testing
@testable import CtrlxNetworking

struct WorktreeStatusWireTests {
    @Test("Worktree metadata survives pairing rewrite and old snapshots remain decodable")
    func snapshot() throws {
        let repo = RepositoryWorktreeStatus(id: "/repo/.git", worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 3)])
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
}
