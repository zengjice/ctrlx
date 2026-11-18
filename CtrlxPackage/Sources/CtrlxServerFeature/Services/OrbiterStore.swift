import CtrlxCommon
import CtrlxNetworking
import Foundation

struct OrbiterDraft: Codable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var goal = ""
    var source = ""
    var materials = ""
    var directory = "~/"

    func validate() throws {
        guard
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            title.utf8.count <= 128, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (goal + source + materials).utf8.count <= 32_000 else {
            throw AgentWorkflowError("Enter a short Orbiter name and an initial message. Selected text must fit within 32 KB.")
        }
        guard SessionDirectoryPath.isValid(directory) else { throw AgentWorkflowError("Choose an absolute project directory or ~/… on this Mac.") }
    }
}

struct OrbiterCreation: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let directory: String
    let pluginID: String
    let providerID: String?
    let forkSource: AgentWorkflowInstance?
}

/// A role/source association with an existing Agent, or an unresolved creation
/// intent. It has no independent identity, completion or archive lifecycle.
struct OrbiterRecord: Codable, Equatable, Sendable, Identifiable {
    var agentID: AgentID?
    var creation: OrbiterCreation?
    var binding: AgentWorkflowInstance?
    var pane: WorkspacePaneIdentity?
    var sourceAgentID: AgentID?
    var materialsDirectories: [String] = []
    var messageIDs: [UUID] = []
    var legacyRunIDs: [UUID]? = nil
    var draft = ""

    var id: String {
        if let agentID {
            return "\(agentID.hostID.uuidString)/\(agentID.paneID.uuidString)"
        }
        return "creation/\(creation?.id.uuidString ?? "missing")"
    }

    var title: String {
        binding?.displayName ?? creation?.title ?? "Unavailable Orbiter"
    }

    var directory: String {
        binding?.workingDirectory ?? creation?.directory ?? ""
    }
}

struct OrbiterIndex: Codable, Equatable, Sendable {
    var schemaVersion = 2
    let hostID: UUID
    var draft = OrbiterDraft()
    var agents: [OrbiterRecord] = []
}

actor OrbiterStore {
    let paths: CtrlxPaths
    private let hostID: UUID
    init(paths: CtrlxPaths, hostID: UUID) {
        self.paths = paths
        self.hostID = hostID
    }

    func load() throws -> OrbiterIndex {
        guard FileManager.default.fileExists(atPath: paths.orbiterIndex.path) else { return .init(hostID: hostID) }
        let data = try Data(contentsOf: paths.orbiterIndex)
        let version = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let index: OrbiterIndex
        if version?["schemaVersion"] as? Int == 1 {
            let old = try JSONDecoder().decode(LegacyOrbiterIndex.self, from: data)
            guard old.hostID == hostID else { throw AgentWorkflowError("Orbiters belong to another Host.") }
            var converted = OrbiterIndex(hostID: hostID, draft: old.draft)
            for task in old.tasks {
                let identity = task.agentID(hostID: hostID)
                let record = OrbiterRecord(
                    agentID: identity,
                    creation: .init(id: task.id, title: task.title, directory: task.directory, pluginID: task.pluginID, providerID: task.providerID, forkSource: task.forkSource),
                    binding: task.binding,
                    pane: task.pane,
                    sourceAgentID: task.forkSource?.agentID,
                    materialsDirectories: [paths.orbiterDirectory(task.id).path],
                    legacyRunIDs: task.runIDs + [task.pendingRunID].compactMap { $0 }.filter { !task.runIDs.contains($0) },
                    draft: task.draft
                )
                if let identity, let i = converted.agents.firstIndex(where: { $0.agentID == identity }) {
                    converted.agents[i].materialsDirectories += record.materialsDirectories
                    let previous = converted.agents[i].legacyRunIDs ?? []
                    converted.agents[i].legacyRunIDs = previous + (record.legacyRunIDs ?? []).filter { !previous.contains($0) }
                    if !task.draft.isEmpty {
                        converted.agents[i].draft += "\n\n" + task.draft
                    }
                } else {
                    converted.agents.append(record)
                }
            }
            index = converted
        } else {
            index = try JSONDecoder().decode(OrbiterIndex.self, from: data)
        }
        try validate(index)
        return index
    }

    func save(_ index: OrbiterIndex) throws {
        try validate(index)
        try FileManager.default.createDirectory(at: paths.orbieStateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: paths.orbiterIndex.path) {
            let backup = paths.orbiterIndex.appendingPathExtension("pre-3fix.backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: paths.orbiterIndex, to: backup)
            }
        }
        try JSONEncoder().encode(index).write(to: paths.orbiterIndex, options: .atomic)
    }

    func prepareMaterials(_ creation: OrbiterCreation, text: String) throws -> String {
        let directory = paths.orbiterDirectory(creation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("CONTEXT.md")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        }
        return directory.path
    }

    private func validate(_ index: OrbiterIndex) throws {
        guard
            index.schemaVersion == 2, index.hostID == hostID,
            Set(index.agents.map(\.id)).count == index.agents.count,
            index.agents.allSatisfy({ record in
                (record.agentID != nil || record.creation != nil)
                    && (record.agentID.map { $0.hostID == hostID } ?? true)
                    && (record.binding.map { $0.agentID == record.agentID } ?? true)
            }) else { throw AgentWorkflowError("The Orbiter index is invalid. Its data has been preserved.") }
    }
}
