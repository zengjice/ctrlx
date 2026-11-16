import CtrlxNetworking
import Foundation

/// Read only migration formats; never used for live Agent interaction.
struct LegacyOrbiterTask: Codable, Equatable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable { case newAgent, fork, associated }
    let id: UUID
    let title: String
    let createdAt: Date
    let goal: String
    let source: String
    let materials: String
    var directory: String
    let origin: Origin
    let pluginID: String
    let providerID: String?
    let forkSource: AgentWorkflowInstance?
    var pane: WorkspacePaneIdentity?
    var binding: AgentWorkflowInstance?
    var runIDs: [UUID] = []
    var pendingRunID: UUID?
    var draft: String
    var archived = false

    func agentID(hostID: UUID) -> AgentID? {
        if let binding {
            guard binding.hostID == hostID else { return nil }
            return binding.agentID
        }
        return pane.map { AgentID(hostID: hostID, paneID: $0.paneID) }
    }

    var initialInput: String {
        """
        Goal:
        \(goal)

        Source supplied by the user:
        \(source.isEmpty ? "None" : source)

        Selected materials:
        \(materials.isEmpty ? "None" : materials)

        Return a concise Agent report with Summary, Evidence, Artifacts and Next steps.
        State incomplete work and uncertainty. A finished reply does not establish that the goal was verified.
        """
    }
}

struct LegacyOrbiterIndex: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let hostID: UUID
    var draft = OrbiterDraft()
    var tasks: [LegacyOrbiterTask] = []
}
