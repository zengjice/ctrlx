import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Host and Viewers share read-only work; cancellation of one reader does not cancel the others.
@MainActor
final class AgentModelReadRequests {
    private struct Pending {
        let id = UUID()
        let identity: WorkspacePaneIdentity
        let refresh: Bool
        let task: Task<AgentModelSnapshot, Error>
    }

    private var pending: [String: Pending] = [:]

    func read(
        paneID: String, identity: WorkspacePaneIdentity, refresh: Bool,
        operation: @escaping @MainActor () async throws -> AgentModelSnapshot
    ) async throws -> AgentModelSnapshot {
        if let current = pending[paneID] {
            guard current.identity.isSamePane(as: identity) else { throw AgentModelError("The terminal changed. Reopen its model controls.") }
            let result = await current.task.result
            if pending[paneID]?.id == current.id {
                pending[paneID] = nil
            }
            try Task.checkCancellation()
            if !refresh || current.refresh {
                return try result.get()
            }
            // An explicit catalog refresh cannot be satisfied by a state-only read.
            return try await read(paneID: paneID, identity: identity, refresh: true, operation: operation)
        }
        let current = Pending(identity: identity, refresh: refresh, task: Task { try await operation() })
        pending[paneID] = current
        defer {
            if pending[paneID]?.id == current.id {
                pending[paneID] = nil
            }
        }
        let value = try await current.task.value
        try Task.checkCancellation()
        return value
    }
}
