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

    var schemaVersion = 2
    let hostID: UUID
    var enabled = false
    var creation: Creation?
    var binding: AgentWorkflowInstance?
    var messageIDs: [UUID] = []
    var legacyRunIDs: [UUID]?
    var pendingMessageID: UUID?
    var legacyPendingRunID: UUID?
    var draft = ""

    init(hostID: UUID) {
        self.hostID = hostID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hostID
        case enabled
        case creation
        case binding
        case messageIDs
        case pendingMessageID
        case draft
        case legacyRunIDs
        case legacyPendingRunID
    }

    private enum LegacyKeys: String, CodingKey { case runIDs, pendingRunID }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...2).contains(version) else { throw AgentWorkflowError("Unsupported Orbie data version.") }
        self.hostID = try values.decode(UUID.self, forKey: .hostID)
        self.enabled = try values.decode(Bool.self, forKey: .enabled)
        self.creation = try values.decodeIfPresent(Creation.self, forKey: .creation)
        self.binding = try values.decodeIfPresent(AgentWorkflowInstance.self, forKey: .binding)
        self.draft = try values.decode(String.self, forKey: .draft)
        self.messageIDs = try values.decodeIfPresent([UUID].self, forKey: .messageIDs) ?? []
        self.pendingMessageID = try values.decodeIfPresent(UUID.self, forKey: .pendingMessageID)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        self.legacyRunIDs = try values.decodeIfPresent([UUID].self, forKey: .legacyRunIDs) ?? legacy.decodeIfPresent([UUID].self, forKey: .runIDs)
        self.legacyPendingRunID = try values.decodeIfPresent(UUID.self, forKey: .legacyPendingRunID) ?? legacy.decodeIfPresent(UUID.self, forKey: .pendingRunID)
    }

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
/// Agent message store, including after an interrupted operation.
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
        if FileManager.default.fileExists(atPath: paths.orbieBinding.path) {
            let backup = paths.orbieBinding.appendingPathExtension("pre-3fix.backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: paths.orbieBinding, to: backup)
            }
        }
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
            record.schemaVersion == 2, record.hostID == hostID,
            record.binding.map({ $0.hostID == hostID && record.creation != nil }) ?? true,
            Set(record.messageIDs).count == record.messageIDs.count,
            record.pendingMessageID.map({ record.messageIDs.contains($0) }) ?? true else {
            throw AgentWorkflowError("The Orbie binding is invalid or belongs to another Host. Its saved data has been preserved.")
        }
    }
}
