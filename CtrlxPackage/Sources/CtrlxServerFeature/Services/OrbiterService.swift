import CtrlxNetworking
import Foundation
import Observation

@MainActor
@Observable
final class OrbiterService {
    private(set) var index: OrbiterIndex?
    private(set) var instances: [AgentWorkflowInstance] = []
    private(set) var messages: [AgentMessage] = []
    private(set) var historyPage = AgentMessagePage()
    @ObservationIgnored private var historyEndID: UUID?
    private(set) var isBusy = false
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var updateWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var draftSaveRequested = false
    private(set) var closedAgents = Set<AgentID>()
    private(set) var restoringAgents = Set<AgentID>()
    private(set) var recoveryIssues: [AgentID: String] = [:]
    private(set) var issue: String?
    private(set) var occupancy: [AgentID: String] = [:]
    var draft = OrbiterDraft()
    var drafts: [String: String] = [:]

    @ObservationIgnored private let store: OrbiterStore
    @ObservationIgnored private let recovery: AgentRoleRecovery?
    @ObservationIgnored private let interaction: AgentMessageService
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let forkSource: () async throws -> AgentWorkflowInstance
    @ObservationIgnored private let launch: (OrbiterCreation) async throws -> WorkspacePaneIdentity
    @ObservationIgnored private let locateCreation: (UUID) async throws -> WorkspacePaneIdentity?

    init(
        store: OrbiterStore,
        interaction: AgentMessageService,
        recovery: AgentRoleRecovery? = nil,
        enabled: @escaping () -> Bool,
        forkSource: @escaping () async throws -> AgentWorkflowInstance,
        launch: @escaping (OrbiterCreation) async throws -> WorkspacePaneIdentity,
        locateCreation: @escaping (UUID) async throws -> WorkspacePaneIdentity?
    ) {
        self.store = store
        self.interaction = interaction
        self.enabled = enabled
        self.recovery = recovery
        self.forkSource = forkSource
        self.launch = launch
        self.locateCreation = locateCreation
    }

    var agents: [OrbiterRecord] {
        index?.agents ?? []
    }

    func currentInstance(_ record: OrbiterRecord) -> AgentWorkflowInstance? {
        if let id = record.agentID, restoringAgents.contains(id) || recoveryIssues[id] != nil {
            return nil
        }
        return record.agentID?.resolve(in: instances, identity: { $0.agentID }).value
    }

    func history(_ record: OrbiterRecord) -> [AgentMessage] {
        if historyAgentID == record.id {
            return historyPage.messages
        }
        return record.messageIDs.compactMap { id in messages.first { $0.id == id } }
    }

    func loadHistory(endingAt id: UUID?) async {
        guard let selection = historyAgentID, (try? await begin()) != nil else { return }
        defer { finishOperation() }
        guard historyAgentID == selection, let record = agents.first(where: { $0.id == selection }) else { return }
        historyEndID = id == record.messageIDs.last ? nil : id
        await refreshContents(inspect: false)
    }

    func availability(_ record: OrbiterRecord) -> String? {
        guard enabled() else { return "Enable Orbie on this Mac before sending messages." }
        if let id = record.agentID, let issue = recoveryIssues[id] {
            return issue
        }
        if let id = record.agentID, restoringAgents.contains(id) {
            return "Restoring the original conversation…"
        }
        guard let current = currentInstance(record) else { return "The Agent is unavailable. Open its tab to check startup or recovery." }
        if let issue = current.capabilityIssue {
            return issue
        }
        if let issue = occupancy[current.agentID] {
            return issue
        }
        switch current.readiness {
        case .ready: return nil
        case .busy: return "The Agent is working. Your draft is kept."
        case .draft: return "The Agent has unsent terminal input. Your draft is kept."
        case .awaitingHuman: return "Continue the question or approval in the Agent tab."
        case .unavailable: return current.inputIssue ?? "The Agent input cannot be verified. Check its tab."
        }
    }

    func recordForNavigation(_ id: String) async throws -> OrbiterRecord {
        guard let record = try await store.load().agents.first(where: { $0.id == id }) else { throw AgentWorkflowError("This Agent is no longer associated with Orbie.") }
        return record
    }

    func refresh(inspect: Bool = true) async {
        guard !isBusy, !isUpdating else { return }
        isUpdating = true
        defer { finishUpdate() }
        await refreshContents(inspect: inspect)
    }

    private func refreshContents(inspect: Bool) async {
        do {
            try await reconcile(inspect: inspect)
            if inspect {
                try await interaction.resumePendingReplies()
            }
            issue = nil
        } catch is CancellationError {
            return
        } catch { issue = error.localizedDescription }
    }

    func saveDrafts() async {
        guard !isBusy, !isUpdating else {
            draftSaveRequested = true
            return
        }
        guard let index else { return }
        isUpdating = true
        defer { finishUpdate() }
        do { try await persist(index) } catch { issue = error.localizedDescription }
    }

    func shutdown() async {
        await saveDrafts()
    }

    func prepareCreation(inspect: Bool = false) async throws -> UUID {
        try await begin()
        defer { finishOperation() }
        if inspect || index == nil {
            try await reconcile(inspect: inspect)
        }
        try draft.validate()
        guard let hostID = index?.hostID else { throw AgentWorkflowError("Orbiters have not loaded yet.") }
        return hostID
    }

    @discardableResult
    func create(pluginID: String, providerID: String?, fork: Bool = false, requestedSource: AgentWorkflowInstance? = nil) async throws -> String {
        try await begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        try draft.validate()
        guard enabled(), var updated = index else { throw AgentWorkflowError("Enable Orbie before creating an Orbiter.") }
        guard !agents.contains(where: { $0.creation?.id == draft.id }) else { throw AgentWorkflowError("This creation is already recorded. Check the existing Agent before retrying.") }
        let source: AgentWorkflowInstance?
        if fork, let requestedSource {
            guard
                agents.contains(where: { $0.agentID == requestedSource.agentID }),
                let current = instances.first(where: { $0.matchesBinding(requestedSource) }),
                current.capabilityIssue == nil,
                try await interaction.availability(current.agentID) == nil else {
                throw AgentWorkflowError("The Fork source changed or is busy. Review its conversation first.")
            }
            source = current
        } else {
            source = fork ? try await forkSource() : nil
        }
        guard source == nil || (source?.pluginID == pluginID && source?.readiness == .ready && UUID(uuidString: source?.conversationID ?? "") != nil) else {
            throw AgentWorkflowError("Fork requires a ready, verified conversation of the same Agent type. Choose New Agent for another type.")
        }
        let creation = OrbiterCreation(id: draft.id, title: draft.title, directory: draft.directory, pluginID: pluginID, providerID: providerID, forkSource: source)
        let text = [draft.goal, draft.source, draft.materials].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var record = OrbiterRecord(creation: creation, sourceAgentID: source?.agentID, draft: text)
        record.materialsDirectories = try [await store.prepareMaterials(creation, text: text)]
        updated.agents.append(record)
        drafts[record.id] = text
        try await persist(updated)
        do {
            let oldKey = record.id
            record.pane = try await launch(creation)
            record.agentID = record.pane.map { AgentID(hostID: updated.hostID, paneID: $0.paneID) }
            drafts[record.id] = drafts.removeValue(forKey: oldKey)
            try await replace(record, previousID: oldKey)
            draft = OrbiterDraft()
            if let index {
                try await persist(index)
            }
            // The creation action opens the Agent with the captured material in
            // its draft. It never schedules hidden work or retries a lost write.
            try await reconcile(inspect: true)
            return record.id
        } catch {
            issue = "Creation was not fully confirmed: \(error.localizedDescription) The draft and any created tab are kept."
            throw error
        }
    }

    func associate(_ candidate: AgentWorkflowInstance) async throws -> String {
        try await begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        guard
            enabled(), var updated = index, candidate.hostID == updated.hostID,
            let current = instances.first(where: { $0.matchesBinding(candidate) }),
            !agents.contains(where: { $0.agentID == current.agentID }) else { throw AgentWorkflowError("Choose an unassociated, verified Agent on this Host.") }
        let record = OrbiterRecord(agentID: current.agentID, binding: current, pane: current.workspacePane)
        updated.agents.append(record)
        try await persist(updated)
        return record.id
    }

    func send(_ id: String) async throws {
        let text = drafts[id] ?? ""
        try await begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        guard var record = agents.first(where: { $0.id == id }) else { throw AgentWorkflowError("Agent not found.") }
        if let issue = availability(record) {
            throw AgentWorkflowError(issue)
        }
        guard let current = currentInstance(record) else { throw AgentWorkflowError("Agent not found.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = AgentMessage(instance: current, text: text)
        record.messageIDs.append(message.id)
        try await replace(record)
        try await interaction.send(message)
        if try await interaction.store.message(message.id)?.status != .failed, drafts[id] == text {
            drafts[id] = ""
        }
        try await reconcile(inspect: false)
    }

    func stopWaiting(_ message: AgentMessage) async throws {
        try await begin()
        defer { finishOperation() }
        guard agents.contains(where: { $0.messageIDs.contains(message.id) }) else { throw AgentWorkflowError("Message not found.") }
        try await interaction.stopWaiting(message.id)
        await refreshContents(inspect: false)
    }

    func restoreOriginalConversation(_ id: String) async throws {
        try await begin()
        defer { finishOperation() }
        guard var record = agents.first(where: { $0.id == id }), let agentID = record.agentID, let recovery else { throw AgentWorkflowError("No recovery target is available.") }
        guard currentInstance(record) == nil else { return }
        let restored: AgentWorkflowInstance
        do { restored = try await recovery.restore(agentID) } catch is AgentRoleRecovery.Starting {
            restoringAgents.insert(agentID)
            return
        }
        record.agentID = restored.agentID
        record.binding = restored
        record.pane = restored.workspacePane
        record.draft = drafts[id] ?? record.draft
        try await replace(record, previousID: id)
        remapRestoredAgent(from: agentID, to: record)
        try await reconcile(inspect: true)
    }

    private func remapRestoredAgent(from old: AgentID, to record: OrbiterRecord) {
        closedAgents.remove(old)
        restoringAgents.remove(old)
        recoveryIssues[old] = nil
        let oldKey = OrbiterRecord(agentID: old).id
        guard record.id != oldKey else { return }
        drafts[record.id] = drafts.removeValue(forKey: oldKey) ?? record.draft
        if historyAgentID == oldKey {
            historyAgentID = record.id
        }
    }

    var historyAgentID: String? {
        didSet {
            if historyAgentID != oldValue {
                historyEndID = nil
                historyPage = AgentMessagePage()
            }
        }
    }

    private func reconcile(inspect: Bool) async throws {
        if index == nil {
            index = try await store.load()
            draft = index?.draft ?? .init()
            drafts = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.draft) })
        }
        guard var updated = index else { return }
        var restoredAgents: [(AgentID, OrbiterRecord)] = []
        var refreshedOccupancy: [AgentID: String] = [:]
        var refreshedMessages: [AgentMessage] = []
        for i in updated.agents.indices {
            var record = updated.agents[i]
            let oldKey = record.id
            if inspect, record.pane == nil, let creation = record.creation {
                record.pane = try await locateCreation(creation.id)
                record.agentID = record.pane.map { AgentID(hostID: updated.hostID, paneID: $0.paneID) }
                if record.id != oldKey {
                    drafts[record.id] = drafts.removeValue(forKey: oldKey)
                }
            }
            if inspect, let id = record.agentID, let recovery {
                restoringAgents.remove(id)
                recoveryIssues[id] = nil
                closedAgents.remove(id)
                do {
                    if try await recovery.isClosed(id) {
                        closedAgents.insert(id)
                    }
                    if let restored = try await recovery.checkPendingRestore(id) {
                        record.agentID = restored.agentID
                        record.binding = restored
                        record.pane = restored.workspacePane
                        record.draft = drafts[oldKey] ?? record.draft
                        restoredAgents.append((id, record))
                    }
                } catch is AgentRoleRecovery.Starting {
                    restoringAgents.insert(id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    recoveryIssues[id] = error.localizedDescription
                }
            }
            updated.agents[i] = record
        }
        try await persist(updated)
        for (id, record) in restoredAgents {
            remapRestoredAgent(from: id, to: record)
        }
        instances = try await interaction.catalog.snapshot(refresh: inspect)
        for i in updated.agents.indices {
            var record = updated.agents[i]
            if let current = currentInstance(record) {
                if inspect {
                    try await recovery?.confirmResume(current)
                }
                record.binding = current
                record.pane = current.workspacePane
                refreshedOccupancy[current.agentID] = try await interaction.availability(current.agentID)
            }
            refreshedMessages += try await interaction.store.messages(record.messageIDs, limit: 3)
            if historyAgentID == record.id {
                let page = try await interaction.store.page(record.messageIDs, endingAt: historyEndID)
                if historyAgentID == record.id {
                    historyPage = page
                }
            }
            updated.agents[i] = record
        }
        try await persist(updated)
        occupancy = refreshedOccupancy
        messages = refreshedMessages
    }

    private func replace(_ record: OrbiterRecord, previousID: String? = nil) async throws {
        guard var updated = index, let i = updated.agents.firstIndex(where: { $0.id == (previousID ?? record.id) }) else { throw AgentWorkflowError("Agent association not found.") }
        updated.agents[i] = record
        try await persist(updated)
    }

    private func persist(_ value: OrbiterIndex) async throws {
        var updated = value
        updated.draft = draft
        for i in updated.agents.indices {
            updated.agents[i].draft = drafts[updated.agents[i].id] ?? updated.agents[i].draft
        }
        if updated != index {
            try await store.save(updated)
            index = updated
        }
    }

    private func begin() async throws {
        try Task.checkCancellation()
        guard !isBusy else { throw AgentWorkflowError("An Agent operation is already in progress.") }
        // Reserve the action before waiting so the next poll cannot overtake it.
        isBusy = true
        if isUpdating {
            await withCheckedContinuation { updateWaiter = $0 }
        }
        if Task.isCancelled {
            finishOperation()
            throw CancellationError()
        }
    }

    private func finishUpdate() {
        isUpdating = false
        updateWaiter?.resume()
        updateWaiter = nil
        scheduleDraftSave()
    }

    private func finishOperation() {
        isBusy = false
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        guard !isBusy, draftSaveRequested else { return }
        draftSaveRequested = false
        Task { [weak self] in await self?.saveDrafts() }
    }
}
