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
            throw AgentWorkflowError("Enter a short task name and a goal. Selected task text must fit within 32 KB.")
        }
        guard SessionDirectoryPath.isValid(directory) else { throw AgentWorkflowError("Choose an absolute project directory or ~/… on this Mac.") }
    }
}

struct OrbiterTask: Codable, Equatable, Sendable, Identifiable {
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

struct OrbiterIndex: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let hostID: UUID
    var draft = OrbiterDraft()
    var tasks: [OrbiterTask] = []
}

/// Only product metadata lives here. Native turn and delivery truth stays in the workflow ledger.
actor OrbiterStore {
    let paths: CtrlxPaths
    private let hostID: UUID

    init(paths: CtrlxPaths, hostID: UUID) {
        self.paths = paths
        self.hostID = hostID
    }

    func load() throws -> OrbiterIndex {
        guard FileManager.default.fileExists(atPath: paths.orbiterIndex.path) else { return .init(hostID: hostID) }
        let index = try JSONDecoder().decode(OrbiterIndex.self, from: Data(contentsOf: paths.orbiterIndex))
        try validate(index)
        return index
    }

    func save(_ index: OrbiterIndex) throws {
        try validate(index)
        try FileManager.default.createDirectory(at: paths.orbieStateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(index).write(to: paths.orbiterIndex, options: .atomic)
    }

    func saveMaterials(_ task: OrbiterTask, runs: [AgentWorkflowRun]) throws {
        let directory = paths.orbiterDirectory(task.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let instructions = """
        # \(task.title)

        Task: \(task.id)
        Created: \(task.createdAt.ISO8601Format())
        Working directory: \(task.directory)
        Context: \(task.origin.rawValue)
        \(task.forkSource.map { "Fork source conversation: \($0.conversationID)" } ?? "")

        \(task.initialInput)
        """
        try writeIfChanged(instructions, to: directory.appendingPathComponent("TASK.md"))
        let reports = runs.flatMap { run in
            Self.reports(in: run).map { invocation, result in
                """
                ## Agent report — \(result.completedAt.ISO8601Format())

                Workflow: \(run.id)
                Invocation: \(invocation.id)
                Native turn: \(result.nativeTurnID ?? "")

                \(result.text)
                """
            }
        }
        if !reports.isEmpty {
            try writeIfChanged("# Agent reports\n\nThese are Agent reports, not independent verification of the business goal.\n\n" + reports.joined(separator: "\n\n"), to: directory.appendingPathComponent("RESULT.md"))
        }
    }

    static func reports(in run: AgentWorkflowRun) -> [(AgentWorkflowInvocation, AgentWorkflowResult)] {
        run.invocations.compactMap { invocation in
            guard
                invocation.status == .succeeded, let result = invocation.result,
                result.invocationID == invocation.id, let turn = result.nativeTurnID,
                turn == invocation.nativeTurnID else { return nil }
            return (invocation, result)
        }
    }

    private func writeIfChanged(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if FileManager.default.fileExists(atPath: url.path), try Data(contentsOf: url) == data {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func validate(_ index: OrbiterIndex) throws {
        guard
            index.schemaVersion == 1, index.hostID == hostID,
            Set(index.tasks.map(\.id)).count == index.tasks.count,
            index.tasks.allSatisfy({ task in
                Set(task.runIDs).count == task.runIDs.count
                    && (task.pendingRunID.map { task.runIDs.contains($0) } ?? true)
                    && (task.binding.map { $0.hostID == hostID && $0.pluginID == task.pluginID } ?? true)
            }) else { throw AgentWorkflowError("The Orbiter task index is invalid or belongs to another Host. Saved data was preserved.") }
    }
}
