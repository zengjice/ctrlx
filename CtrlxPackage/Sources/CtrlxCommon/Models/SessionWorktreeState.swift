import CtrlxNetworking
import Foundation

/// A preview and its acknowledgement belong to one Host/path inspection.
struct SessionWorktreeState {
    struct Query: Equatable {
        let hostID: String
        let path: String
        let enabled: Bool
        let unavailableReason: String?
        var retry = 0
    }

    private(set) var query: Query?
    private(set) var requestID: UUID?
    private(set) var plan: AgentForkWorktree?
    private(set) var error: String?
    private(set) var isLoading = false
    var allowUncommittedChanges = false

    mutating func begin(_ query: Query) -> UUID {
        let id = UUID()
        self.query = query
        requestID = id
        plan = nil
        error = nil
        allowUncommittedChanges = false
        isLoading = query.enabled && query.unavailableReason == nil && SessionDirectoryPath.isValid(query.path)
        return id
    }

    mutating func finish(_ id: UUID, plan: AgentForkWorktree) {
        guard requestID == id else { return }
        self.plan = plan
        isLoading = false
    }

    mutating func fail(_ id: UUID, message: String) {
        guard requestID == id else { return }
        error = message
        isLoading = false
    }

    func request(for query: Query, name: String) throws -> ForkAgentSession.Worktree {
        guard
            query.enabled, query.unavailableReason == nil,
            self.query == query, !isLoading, let plan else {
            throw AgentForkError("Check the selected directory before creating a worktree.")
        }
        return try plan.request(name: name.trimmingCharacters(in: .whitespacesAndNewlines), allowUncommittedChanges: allowUncommittedChanges)
    }
}
