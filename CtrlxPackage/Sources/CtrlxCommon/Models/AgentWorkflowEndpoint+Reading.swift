import CtrlxNetworking
import Foundation

public struct AgentWorkflowOverview: Equatable, Sendable {
    public let hostID: UUID
    public let definitions: [AgentWorkflowDefinitionSummary]
    public let runs: [AgentWorkflowRunSummary]
}

public extension AgentWorkflowEndpoint {
    func overview(hostID: UUID? = nil) async throws -> AgentWorkflowOverview {
        let definitions = try await pages(hostID: hostID, operation: { .definitions(offset: $0) }, content: \.definitions)
        let runs = try await pages(hostID: definitions.hostID, operation: { .runs(offset: $0) }, content: \.runs)
        return .init(hostID: definitions.hostID, definitions: definitions.items, runs: runs.items)
    }

    func instances(hostID: UUID) async throws -> [AgentWorkflowInstance] {
        try await pages(hostID: hostID, operation: { .catalog(offset: $0) }, content: \.instances).items
    }

    func currentInstance(_ bound: AgentWorkflowInstance) async throws -> AgentWorkflowInstance {
        guard
            let current = try await instances(hostID: bound.hostID).first(where: { bound.matchesBinding($0) }),
            current.readiness != .unavailable else {
            throw AgentWorkflowError("This Agent instance is no longer available. Its old task will not be routed to a replacement.")
        }
        return current
    }

    func invocations(runID: UUID, hostID: UUID) async throws -> [AgentWorkflowInvocationSummary] {
        try await pages(hostID: hostID, operation: { .invocations(runID: runID, offset: $0) }, content: \.invocations).items
    }

    /// Input and accepted results are immutable for an invocation, so a byte
    /// cursor can span several requests without mixing different revisions.
    func text(runID: UUID, invocationID: UUID, part: ManageAgentWorkflows.TextPart, hostID: UUID) async throws -> String {
        var output = ""
        var offset = 0
        var expectedBytes: Int?
        while true {
            try Task.checkCancellation()
            let response = try await request(.text(runID: runID, invocationID: invocationID, part: part, offset: offset), hostID: hostID)
            guard
                let page = response.text,
                page.totalBytes >= offset,
                expectedBytes == nil || expectedBytes == page.totalBytes,
                page.text.utf8.count <= page.totalBytes - offset else {
                throw AgentWorkflowError("The Host returned inconsistent workflow text. Reload it.")
            }
            expectedBytes = page.totalBytes
            output += page.text
            let next = offset + page.text.utf8.count
            guard let nextOffset = page.nextOffset else {
                guard next == page.totalBytes else { throw AgentWorkflowError("The workflow text is incomplete. Reload it.") }
                return output
            }
            guard nextOffset == next, nextOffset > offset, nextOffset < page.totalBytes else {
                throw AgentWorkflowError("The workflow text cursor is invalid. Reload it.")
            }
            offset = nextOffset
        }
    }

    private func pages<Item>(
        hostID: UUID?, operation: (Int) -> ManageAgentWorkflows.Operation,
        content: KeyPath<AgentWorkflowResponse, AgentWorkflowPage<Item>?>
    ) async throws -> (hostID: UUID, items: [Item]) {
        var expectedHostID = hostID
        var items: [Item] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let response = try await request(operation(offset), hostID: expectedHostID)
            expectedHostID = response.hostID
            guard let page = response[keyPath: content] else { throw AgentWorkflowError("The Host did not return the requested workflow list.") }
            items += page.items
            guard let next = page.nextOffset else { return (response.hostID, items) }
            guard !page.items.isEmpty, next == offset + page.items.count else {
                throw AgentWorkflowError("The workflow list changed. Reload it.")
            }
            offset = next
        }
    }
}
