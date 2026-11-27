import Foundation

/// A small run presentation carried in pane snapshots; it does not grant task authority.
public struct AgentWorkflowPaneStatus: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let runID: UUID
    public let name: String
    public let status: AgentWorkflowRunStatus
    public let round: Int
    public let nodeName: String?
    public let issue: String?
    public let verifying: Bool
    public let needsAttention: Bool

    public init(run: AgentWorkflowRun, hostID: UUID, needsAttention: Bool = false) {
        self.hostID = hostID
        self.runID = run.id
        self.name = run.definition.name
        self.status = run.status
        self.round = run.round
        self.issue = run.issue
        self.needsAttention = needsAttention
        let current = run.invocations.filter { $0.round == run.round }
        let active = current.filter { [.writing, .running, .awaitingAcceptance, .uncertain].contains($0.status) }
        let calls = active.isEmpty ? Array(current.suffix(1)) : active
        let names = calls.compactMap { call in run.definition.nodes.first { $0.id == call.nodeID }?.name }
        self.nodeName = names.isEmpty ? nil : names.joined(separator: ", ")
        self.verifying = active.contains { [.awaitingAcceptance, .uncertain].contains($0.status) }
    }

    public var title: String {
        switch status {
        case .running: verifying ? "Verifying" : "Running"
        case .finishing: "Finishing"
        case .paused: needsAttention ? "Needs attention" : "Paused"
        case .completed: "Completed"
        case .ended: "Ended"
        }
    }

    public var detail: String {
        ([name, "Round \(round)"] + (nodeName.map { [$0] } ?? [])).joined(separator: " · ")
    }

    public static func presentations(runs: [AgentWorkflowRun], hostID: UUID, attentionRunIDs: Set<UUID>) -> [WorkspacePaneIdentity: Self] {
        var statuses: [WorkspacePaneIdentity: Self] = [:]
        for run in runs.sorted(by: { $0.createdAt > $1.createdAt }) {
            for instance in run.instances {
                guard !statuses.keys.contains(where: { $0.isSamePane(as: instance.workspacePane) }) else { continue }
                statuses[instance.workspacePane] = .init(run: run, hostID: hostID, needsAttention: attentionRunIDs.contains(run.id))
            }
        }
        return statuses
    }
}
