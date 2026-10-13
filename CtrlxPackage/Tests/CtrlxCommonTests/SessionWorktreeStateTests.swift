import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct SessionWorktreeStateTests {
    private let plan = AgentForkWorktree(repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "abc", relativeDirectory: "", hasUncommittedChanges: true)

    private func query(host: String = "office", path: String = "~/repo", enabled: Bool = true, retry: Int = 0) -> SessionWorktreeState.Query {
        .init(hostID: host, path: path, enabled: enabled, unavailableReason: nil, retry: retry)
    }

    @Test("Changing Host, path or mode cannot launch with the previous preview")
    func stalePreview() throws {
        var state = SessionWorktreeState()
        let id = state.begin(query())
        state.finish(id, plan: plan)
        state.allowUncommittedChanges = true
        for changed in [query(host: "home"), query(path: "~/other"), query(enabled: false), query(retry: 1)] {
            #expect(throws: AgentForkError.self) { try state.request(for: changed, name: "feature") }
        }
        #expect(try state.request(for: query(), name: " feature ").name == "feature")
        #expect(throws: AgentForkError.self) { try state.request(for: query(), name: "../escape") }
    }

    @Test("Late A → B → A replies cannot replace a current preview or acknowledge dirty changes")
    func outdatedReplies() throws {
        var state = SessionWorktreeState()
        let first = state.begin(query())
        _ = state.begin(query(path: "~/other"))
        let current = state.begin(query())
        state.finish(first, plan: plan)
        state.fail(first, message: "Old failure")
        #expect(state.plan == nil)
        #expect(state.error == nil)
        #expect(state.isLoading)
        state.finish(current, plan: plan)
        #expect(throws: AgentForkError.self) { try state.request(for: query(), name: "feature") }
        state.allowUncommittedChanges = true
        #expect(try state.request(for: query(), name: "feature").expectedHead == plan.head)
        let retryQuery = query(retry: 1)
        let retry = state.begin(retryQuery)
        #expect(!state.allowUncommittedChanges)
        #expect(state.plan == nil)
        state.fail(retry, message: "Not a Git repository")
        #expect(!state.isLoading)
        #expect(throws: AgentForkError.self) { try state.request(for: retryQuery, name: "feature") }
    }

    @Test("Worktree capabilities are Host-specific and invalidated on downgrade or disconnect")
    @MainActor
    func capability() async {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsSessionWorktrees: true))
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(store.hostsSupportingSessionWorktrees == ["office"])
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:]))
        #expect(store.hostsSupportingSessionWorktrees.isEmpty)
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:], supportsSessionWorktrees: true))
        store.clearSessions(for: "home")
        #expect(store.hostsSupportingSessionWorktrees.isEmpty)
        let source = SessionDirectorySource.remote(hostID: "home", connection: nil, supportsBrowsing: true, supportsWorktrees: true)
        #expect(source.worktreeUnavailableReason?.contains("offline") == true)
        await #expect(throws: SessionDirectorySource.LookupError.self) { try await source.prepareWorktree?("~/repo") }
    }
}
