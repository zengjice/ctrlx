import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Retains only native resume evidence for associated roles. Closing a tab never
/// launches anything. Explicit Resume reuses a stopped terminal or creates a new pane.
actor AgentRoleRecovery {
    struct NotLaunched: Error { let reason: String }
    struct Starting: Error { }
    static let launchTokenOption = "@ctrlx-role-resume-id"

    struct Entry: Codable, Equatable, Sendable {
        let agentID: AgentID
        var descriptor: AgentResumeDescriptor?
        var identity: AgentSessionIdentity?
        var issue: String?
        // Older releases erased both replacements and normal exits. Only new,
        // confirmed replacements prohibit rebuilding evidence from a saved role.
        var invalidated: Bool?
        var intent: Intent?
    }

    struct Intent: Codable, Equatable, Sendable {
        let id: UUID
        var attempted = false
        var pane: WorkspacePaneIdentity?
        var inPlace: Bool?
    }

    private let file: URL
    private let paneExists: @Sendable (AgentID) async throws -> Bool
    private let launch: @Sendable (UUID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity
    private let locate: @Sendable (UUID) async throws -> WorkspacePaneIdentity?
    private let inspect: @Sendable (WorkspacePaneIdentity, AgentResumeDescriptor) async throws -> AgentWorkflowInstance?
    private let recoverDescriptor: @Sendable (AgentID, AgentSessionIdentity?) async throws -> AgentResumeDescriptor?
    private let resumeExisting: @Sendable (UUID, AgentID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity
    private var busy = Set<AgentID>()

    init(
        file: URL,
        paneExists: @escaping @Sendable (AgentID) async throws -> Bool,
        launch: @escaping @Sendable (UUID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity,
        locate: @escaping @Sendable (UUID) async throws -> WorkspacePaneIdentity?,
        inspect: @escaping @Sendable (WorkspacePaneIdentity, AgentResumeDescriptor) async throws -> AgentWorkflowInstance?,
        recoverDescriptor: @escaping @Sendable (AgentID, AgentSessionIdentity?) async throws -> AgentResumeDescriptor? = { _, _ in nil },
        resumeExisting: @escaping @Sendable (UUID, AgentID, AgentResumeDescriptor) async throws -> WorkspacePaneIdentity = { _, _, _ in
            throw NotLaunched(reason: "The original terminal still exists. Open it and resume the saved conversation.")
        }
    ) {
        self.file = file
        self.paneExists = paneExists
        self.launch = launch
        self.locate = locate
        self.inspect = inspect
        self.recoverDescriptor = recoverDescriptor
        self.resumeExisting = resumeExisting
    }

    func entry(_ id: AgentID) throws -> Entry? {
        try load().first { $0.agentID == id }
    }

    func isClosed(_ id: AgentID) async throws -> Bool {
        try await !paneExists(id)
    }

    /// Observe an explicitly requested launch. Refresh never launches or retries input.
    func checkPendingRestore(_ id: AgentID) async throws -> AgentWorkflowInstance? {
        guard var record = try entry(id), var intent = record.intent, intent.attempted else { return nil }
        guard busy.insert(id).inserted else { throw Starting() }
        defer { busy.remove(id) }
        guard record.invalidated != true, let descriptor = record.descriptor else {
            throw AgentWorkflowError(record.issue ?? "The saved conversation changed during recovery. Check its terminal.")
        }
        if intent.pane == nil {
            intent.pane = try await locate(intent.id)
            guard try entry(id) == record else { throw AgentWorkflowError("The recovery request changed. Check its terminal.") }
            record.intent = intent
            try save(record)
        }
        return try await verifyRestore(id, intent: intent, descriptor: descriptor)
    }

    func captureSnapshot(_ id: AgentID, pane: WorkspaceRecoveryPane, state: PaneState?, detected: TmuxService.DetectedAgentPane?, scanAvailable: Bool, runtimeID: @Sendable (String) -> String?) throws {
        let retained = try entry(id)
        var prior = pane
        prior.agent = retained?.descriptor ?? pane.agent
        prior.agentIdentity = retained?.identity ?? pane.agentIdentity
        let replaced = state.map {
            WorkspaceAgentCapture.invalidation(prior, state: $0, detected: detected, scanAvailable: scanAvailable, runtimeID: runtimeID) == .replaced
        } ?? false
        let verified = pane.agentIdentity != nil && pane.savedAgentIdentityInvalidated != true
        // The managed in-place launch is expected to change processes. Its
        // intent remains until the exact native conversation is verified.
        let resuming = retained?.intent?.inPlace == true && retained?.intent?.attempted == true
        try capture(
            id,
            descriptor: pane.agent,
            identity: pane.agentIdentity,
            invalidated: ((replaced && !resuming) || retained?.invalidated == true) && !verified
        )
        if
            verified, let identity = pane.agentIdentity, let state, let detected,
            state.workspaceIdentity?.paneID == id.paneID,
            identity.current(in: state, detected: detected, runtimeID: runtimeID(identity.processID)) != nil {
            try confirmInPlaceResume(id, pluginID: identity.source.pluginID, conversationID: identity.source.sessionID)
        }
    }

    /// Called only with a freshly inspected runtime, never a cached role binding.
    func confirmResume(_ live: AgentWorkflowInstance) throws {
        try confirmInPlaceResume(live.agentID, pluginID: live.pluginID, conversationID: live.conversationID)
    }

    private func confirmInPlaceResume(_ id: AgentID, pluginID: String, conversationID: String) throws {
        guard
            var record = try entry(id), record.invalidated != true,
            record.intent?.inPlace == true, record.intent?.attempted == true,
            record.descriptor?.pluginID == pluginID, record.descriptor?.sessionID == conversationID else { return }
        record.intent = nil
        try save(record)
    }

    func capture(_ id: AgentID, descriptor: AgentResumeDescriptor?, identity: AgentSessionIdentity? = nil, invalidated: Bool) throws {
        guard descriptor != nil || identity != nil || invalidated else { return }
        var record = try entry(id) ?? Entry(agentID: id)
        if invalidated {
            record.descriptor = nil
            record.identity = nil
            record.issue = "The previous conversation no longer belongs to this Agent. Create a new Agent explicitly."
            record.invalidated = true
        } else {
            let sameConversation = record.descriptor?.sessionID == (descriptor?.sessionID ?? identity?.source.sessionID)
                && record.descriptor?.pluginID == (descriptor?.pluginID ?? identity?.source.pluginID)
            if !sameConversation {
                record.intent = nil
            }
            record.descriptor = descriptor ?? (sameConversation ? record.descriptor : nil)
            record.identity = identity
            record.issue = nil
            record.invalidated = nil
        }
        try save(record)
    }

    func restore(_ id: AgentID) async throws -> AgentWorkflowInstance {
        guard busy.insert(id).inserted else { throw AgentWorkflowError("Recovery is already being checked.") }
        defer { busy.remove(id) }
        let exists = try await paneExists(id)
        let original = try entry(id)
        var record = original ?? Entry(agentID: id)
        guard record.invalidated != true else {
            throw AgentWorkflowError(record.issue ?? "The saved Agent conversation was replaced. Open its terminal or create a new Agent explicitly.")
        }
        if record.descriptor == nil {
            let descriptor = try await recoverDescriptor(id, record.identity)
            // A capture can replace the association while native history is read.
            guard try entry(id) == original else {
                throw AgentWorkflowError("The saved conversation changed while checking recovery. Refresh and try again.")
            }
            record.descriptor = descriptor
            record.issue = nil
            try save(record)
        }
        guard let descriptor = record.descriptor else {
            throw AgentWorkflowError("No verified native conversation was retained. Create a new Agent explicitly; the old files and messages are kept.")
        }
        if record.intent == nil {
            record.intent = Intent(id: UUID(), inPlace: exists)
            try save(record)
        }
        guard var intent = record.intent else { throw AgentWorkflowError("Recovery intent was not saved.") }
        if intent.pane == nil {
            intent.pane = try await locate(intent.id)
        }
        if intent.pane == nil, !intent.attempted {
            guard try entry(id) == record else { throw AgentWorkflowError("The saved conversation changed. Refresh before resuming.") }
            intent.inPlace = exists
            intent.attempted = true
            record.intent = intent
            try save(record)
            // Persist uncertainty before entering a launch which may lose its reply.
            do {
                intent.pane = try await intent.inPlace == true
                    ? resumeExisting(intent.id, id, descriptor)
                    : launch(intent.id, descriptor)
            } catch let error as NotLaunched {
                if var latest = try entry(id), latest.intent?.id == intent.id {
                    latest.intent?.attempted = false
                    try save(latest)
                }
                throw AgentWorkflowError(error.reason)
            }
        }
        guard
            let current = try entry(id), current.invalidated != true,
            current.descriptor?.sessionID == descriptor.sessionID, current.descriptor?.pluginID == descriptor.pluginID else {
            throw AgentWorkflowError("The Agent conversation changed during recovery. Check its terminal.")
        }
        record = current
        if record.intent?.id == intent.id {
            record.intent = intent
            try save(record)
        } else if intent.inPlace != true || record.intent != nil {
            throw AgentWorkflowError("The recovery request changed. Check its terminal.")
        }
        // A concurrent live capture may already have settled this intent.
        // Keep it cleared even if this call's inspection is still inconclusive.
        return try await verifyRestore(id, intent: intent, descriptor: descriptor)
    }

    private func verifyRestore(_ id: AgentID, intent: Intent, descriptor: AgentResumeDescriptor) async throws -> AgentWorkflowInstance {
        guard let pane = intent.pane else {
            throw AgentWorkflowError("Recovery creation could not be confirmed. Check the terminal list; no second tab was created.")
        }
        guard (pane.paneID == id.paneID) == (intent.inPlace == true) else { throw AgentWorkflowError("The recovery terminal identity does not match the requested destination.") }
        guard let live = try await inspect(pane, descriptor), !live.conversationID.isEmpty else { throw Starting() }
        guard
            live.hostID == id.hostID,
            live.workspacePane.isSamePane(as: pane), live.pluginID == descriptor.pluginID,
            live.conversationID == descriptor.sessionID else {
            throw AgentWorkflowError("The recovery terminal is running a different conversation. Check its Agent tab.")
        }
        guard
            let latest = try entry(id), latest.invalidated != true,
            latest.descriptor?.sessionID == live.conversationID, latest.descriptor?.pluginID == live.pluginID,
            latest.intent?.id == intent.id || (intent.inPlace == true && latest.intent == nil) else {
            throw AgentWorkflowError("The saved conversation changed during recovery. Check its terminal.")
        }
        if intent.inPlace == true {
            // A later normal exit may be explicitly resumed again in this pane.
            try confirmResume(live)
        }
        return live
    }

    static func descriptorForSavedRole(
        _ id: AgentID, identity: AgentSessionIdentity?, main: OrbieRecord, orbiters: OrbiterIndex,
        core: @Sendable (String) async -> (any AgentSessionResuming)?
    ) async throws -> AgentResumeDescriptor? {
        guard main.hostID == id.hostID, orbiters.hostID == id.hostID else { throw AgentWorkflowError("This Agent belongs to another Host.") }
        let orbiter = orbiters.agents.first { $0.agentID == id }
        guard main.target?.agentID == id || orbiter != nil else { throw AgentWorkflowError("This Agent is no longer associated with Orbie.") }
        let binding = main.target?.agentID == id ? main.binding : orbiter?.binding
        let source = identity?.source
        guard source == nil || source?.workspaceIdentity?.paneID == id.paneID else { throw AgentWorkflowError("The saved conversation belongs to a different terminal.") }
        guard binding == nil || binding?.agentID == id else { throw AgentWorkflowError("The saved role binding belongs to a different Agent.") }
        guard
            let pluginID = source?.pluginID ?? binding?.pluginID,
            let conversation = source?.sessionID ?? binding?.conversationID, !conversation.isEmpty,
            let directory = source?.workingDirectory ?? binding?.workingDirectory,
            !directory.isEmpty else { return nil }
        guard let provider = await core(pluginID) else { throw AgentWorkflowError("The saved Agent plugin is disabled or unavailable. Enable it before resuming.") }
        let saved = try await provider.recoveryDescriptor(sessionID: conversation, projectPath: directory, invocation: nil)
        let providerID = main.target?.agentID == id
            ? (main.creation?.pluginID == pluginID ? main.creation?.providerID : nil)
            : (orbiter?.creation?.pluginID == pluginID ? orbiter?.creation?.providerID : nil)
        return AgentResumeDescriptor(
            pluginID: saved.pluginID,
            sessionID: saved.sessionID,
            projectPath: saved.projectPath,
            configurationRoot: saved.configurationRoot,
            usesDefaultConfiguration: saved.usesDefaultConfiguration,
            executable: saved.executable,
            cliVersion: saved.cliVersion,
            arguments: saved.arguments,
            automaticResumeUnavailableReason: saved.automaticResumeUnavailableReason,
            providerID: providerID
        )
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
