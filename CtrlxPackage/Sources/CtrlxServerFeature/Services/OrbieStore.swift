import CtrlxNetworking
import Foundation

struct OrbieRecord: Codable, Equatable, Sendable {
    struct Creation: Codable, Equatable, Sendable {
        let id: UUID
        let pluginID: String
        let providerID: String?
        let directory: String
        var pane: WorkspacePaneIdentity?
    }

    var schemaVersion = 1
    let hostID: UUID
    var enabled = false
    var creation: Creation?
    var binding: AgentWorkflowInstance?
    var runIDs: [UUID] = []
    var pendingRunID: UUID?
    var draft = ""

    var target: AgentWorkflowTarget? {
        binding?.target ?? creation?.pane.map {
            AgentWorkflowTarget(hostID: hostID, windowID: $0.windowID, paneID: $0.paneID)
        }
    }

    func currentInstance(in instances: [AgentWorkflowInstance]) -> AgentWorkflowInstance? {
        guard let target else { return nil }
        return target.agentID.resolve(in: instances, identity: { $0.agentID }).value
    }
}

/// Product associations only. Delivery, acceptance and results belong to the
/// workflow ledger, including after an interrupted Orbie operation.
actor OrbieStore {
    let paths: CtrlxPaths
    private let hostID: UUID

    init(paths: CtrlxPaths, hostID: UUID) {
        self.paths = paths
        self.hostID = hostID
    }

    func load() throws -> OrbieRecord {
        guard FileManager.default.fileExists(atPath: paths.orbieBinding.path) else {
            return OrbieRecord(hostID: hostID)
        }
        let record = try JSONDecoder().decode(OrbieRecord.self, from: Data(contentsOf: paths.orbieBinding))
        try validate(record)
        return record
    }

    func save(_ record: OrbieRecord) throws {
        try validate(record)
        try FileManager.default.createDirectory(at: paths.orbieStateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: paths.orbieBinding, options: .atomic)
    }

    func prepareDirectory() throws -> String {
        try FileManager.default.createDirectory(at: paths.orbieDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let instructions = """
        # Orbie

        You are Orbie, the user's assistant in CtrlX. Discuss the user's tasks and
        return concise answers with evidence when available. Use the ordinary
        terminal for questions and approvals. Do not claim access to task search,
        shared memory or task delegation features that have not been provided.
        This directory is your working directory, not a permissions sandbox.
        """
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let file = paths.orbieDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data(instructions.utf8).write(to: file, options: .withoutOverwriting)
            }
        }
        return paths.orbieDirectory.path
    }

    private func validate(_ record: OrbieRecord) throws {
        guard
            record.schemaVersion == 1, record.hostID == hostID,
            record.binding.map({ $0.hostID == hostID && record.creation != nil }) ?? true,
            Set(record.runIDs).count == record.runIDs.count,
            record.pendingRunID.map({ record.runIDs.contains($0) }) ?? true else {
            throw AgentWorkflowError("The Orbie binding is invalid or belongs to another Host. Its saved data has been preserved.")
        }
    }
}
