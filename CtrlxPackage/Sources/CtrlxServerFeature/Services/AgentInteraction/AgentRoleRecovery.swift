import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Retains only native resume evidence for associated roles. Closing a tab never
/// launches anything; an explicit restore creates a fresh persistent pane.
actor AgentRoleRecovery {
    struct NotLaunched: Error { let reason: String }

    struct Entry: Codable, Equatable, Sendable {
        let agentID: AgentID
        var descriptor: AgentResumeDescriptor?
        var identity: AgentSessionIdentity?
        var issue: String?
        var intent: Intent?
    }

    struct Intent: Codable, Equatable, Sendable {
        let id: UUID
        var attempted = false
        var pane: WorkspacePaneIdentity?
    }

    private let file: URL
    private let paneExists: @Sendable (AgentID) async throws -> Bool
    private let launch: @Sendable (UUID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity
    private let locate: @Sendable (UUID) async throws -> WorkspacePaneIdentity?
    private let inspect: @Sendable (WorkspacePaneIdentity, AgentResumeDescriptor) async throws -> AgentWorkflowInstance?
    private var busy = Set<AgentID>()

    init(
        file: URL,
        paneExists: @escaping @Sendable (AgentID) async throws -> Bool,
        launch: @escaping @Sendable (UUID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity,
        locate: @escaping @Sendable (UUID) async throws -> WorkspacePaneIdentity?,
        inspect: @escaping @Sendable (WorkspacePaneIdentity, AgentResumeDescriptor) async throws -> AgentWorkflowInstance?
    ) {
        self.file = file
        self.paneExists = paneExists
        self.launch = launch
        self.locate = locate
        self.inspect = inspect
    }

    func entry(_ id: AgentID) throws -> Entry? {
        try load().first { $0.agentID == id }
    }

    func isClosed(_ id: AgentID) async throws -> Bool {
        try await !paneExists(id)
    }

    func capture(_ id: AgentID, descriptor: AgentResumeDescriptor?, identity: AgentSessionIdentity? = nil, invalidated: Bool) throws {
        guard descriptor != nil || invalidated else { return }
        var record = try entry(id) ?? Entry(agentID: id)
        if invalidated {
            record.descriptor = nil
            record.identity = nil
            record.issue = "The previous conversation no longer belongs to this Agent. Create a new Agent explicitly."
        } else {
            record.descriptor = descriptor
            record.identity = identity
            record.issue = nil
        }
        try save(record)
    }

    func restore(_ id: AgentID) async throws -> AgentWorkflowInstance {
        guard busy.insert(id).inserted else { throw AgentWorkflowError("Recovery is already being checked.") }
        defer { busy.remove(id) }
        guard try await !paneExists(id) else { throw AgentWorkflowError("The original terminal still exists. Open it and use Resume or Use Shell.") }
        guard var record = try entry(id), let descriptor = record.descriptor else {
            throw AgentWorkflowError("No verified native conversation was retained. Create a new Agent explicitly; the old files and messages are kept.")
        }
        if record.intent == nil {
            record.intent = Intent(id: UUID())
            try save(record)
        }
        guard var intent = record.intent else { throw AgentWorkflowError("Recovery intent was not saved.") }
        if intent.pane == nil {
            intent.pane = try await locate(intent.id)
        }
        if intent.pane == nil, !intent.attempted {
            intent.attempted = true
            record.intent = intent
            try save(record)
            // Persist uncertainty before entering a launch which may lose its reply.
            do { intent.pane = try await launch(intent.id, descriptor) }
            catch let error as NotLaunched {
                intent.attempted = false
                record.intent = intent
                try save(record)
                throw AgentWorkflowError(error.reason)
            }
        }
        record.intent = intent
        try save(record)
        guard let pane = intent.pane else {
            throw AgentWorkflowError("Recovery creation could not be confirmed. Check the terminal list; no second tab was created.")
        }
        guard pane.paneID != id.paneID else { throw AgentWorkflowError("Recovery must create a new Agent identity.") }
        guard
            let live = try await inspect(pane, descriptor), live.hostID == id.hostID,
            live.workspacePane.isSamePane(as: pane), live.pluginID == descriptor.pluginID,
            live.conversationID == descriptor.sessionID else {
            throw AgentWorkflowError("The recovery tab is starting. Check it, then choose Restore Original Conversation again to verify it. No duplicate tab will be created.")
        }
        return live
    }

    private func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }

    private func save(_ entry: Entry) throws {
        var entries = try load()
        if let i = entries.firstIndex(where: { $0.agentID == entry.agentID }) {
            guard entries[i] != entry else { return }
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
