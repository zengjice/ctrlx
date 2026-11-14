import CtrlxNetworking
import Foundation
import Observation

@MainActor
@Observable
final class OrbiterService {
    private(set) var index: OrbiterIndex?
    private(set) var instances: [AgentWorkflowInstance] = []
    private(set) var runs: [AgentWorkflowRun] = []
    private(set) var isBusy = false
    private(set) var isOperating = false
    private(set) var issue: String?
    var draft = OrbiterDraft()
    var taskDrafts: [UUID: String] = [:]

    @ObservationIgnored private let store: OrbiterStore
    @ObservationIgnored private let workflows: AgentWorkflowService
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let forkSource: () async throws -> AgentWorkflowInstance
    @ObservationIgnored private let launch: (OrbiterTask) async throws -> WorkspacePaneIdentity
    @ObservationIgnored private let locateCreation: (UUID) async throws -> WorkspacePaneIdentity?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false

    init(
        store: OrbiterStore, workflows: AgentWorkflowService, enabled: @escaping () -> Bool,
        forkSource: @escaping () async throws -> AgentWorkflowInstance,
        launch: @escaping (OrbiterTask) async throws -> WorkspacePaneIdentity,
        locateCreation: @escaping (UUID) async throws -> WorkspacePaneIdentity?
    ) {
        self.store = store
        self.workflows = workflows
        self.enabled = enabled
        self.forkSource = forkSource
        self.launch = launch
        self.locateCreation = locateCreation
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = Task { [weak self, workflows] in
            for await _ in await workflows.changes() {
                guard !Task.isCancelled else { return }
                await self?.refresh(inspect: false)
            }
        }
    }

    func shutdown() async {
        observation?.cancel()
        observation = nil
        await saveDrafts()
    }

    var tasks: [OrbiterTask] {
        index?.tasks ?? []
    }

    func executions(_ task: OrbiterTask) -> [AgentWorkflowRun] {
        task.runIDs.compactMap { id in runs.first { $0.id == id } }
    }

    func currentInstance(_ task: OrbiterTask) -> AgentWorkflowInstance? {
        if let bound = task.binding, let current = instances.first(where: { bound.matchesProcess($0) }) {
            return current
        }
        guard let pane = task.pane ?? task.binding?.workspacePane else { return nil }
        return instances.first { $0.pluginID == task.pluginID && $0.workspacePane.isSamePane(as: pane) }
    }

    func availability(_ task: OrbiterTask) -> String? {
        guard enabled() else { return "Enable Orbie on this Mac before delivering tasks." }
        guard !task.archived else { return "Unarchive this task to continue." }
        guard let binding = task.binding, let current = currentInstance(task) else {
            return "Waiting for the existing Agent. Open its tab and use Resume or Use Shell if recovery is needed. No task will be resent automatically."
        }
        guard binding.matchesBinding(current) else { return "The Agent changed. Confirm its conversation and reconnect explicitly before sending." }
        if let reason = current.capabilityIssue {
            return reason
        }
        guard task.pendingRunID == nil else { return "The last submission is unconfirmed. Review its execution before sending again." }
        guard !executions(task).contains(where: { !$0.status.isTerminal }) else { return "This task has an unfinished execution. Questions, approvals and recovery stay in the Agent tab." }
        switch current.readiness {
        case .ready: return nil
        case .busy: return "The Agent is working. Your draft is kept."
        case .draft: return "The Agent has unsent terminal input. Your draft is kept."
        case .awaitingHuman: return "Continue the question or approval in the Agent tab."
        case .unavailable: return "The Agent input cannot be verified. Check its tab."
        }
    }

    var activeCount: Int {
        tasks.filter { !$0.archived }.filter { task in
            task.pendingRunID != nil || executions(task).contains { !$0.status.isTerminal }
                || (task.origin != .associated && task.binding == nil)
                || currentInstance(task)?.readiness == .busy
        }.count
    }

    func materialDirectory(_ task: OrbiterTask) -> URL {
        store.paths.orbiterDirectory(task.id)
    }

    func taskForNavigation(_ id: UUID) async throws -> OrbiterTask {
        guard let task = try await store.load().tasks.first(where: { $0.id == id }) else {
            throw AgentWorkflowError("This task is no longer in the saved task index.")
        }
        return task
    }

    func refresh(inspect: Bool = true) async {
        guard !isBusy else { refreshRequested = true
            return
        }
        isBusy = true
        defer { finishOperation() }
        do { try await reconcile(inspect: inspect)
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func saveDrafts() async {
        guard !isBusy, let index else { refreshRequested = true
            return
        }
        isBusy = true
        defer { finishOperation() }
        do { try await persist(index) } catch { issue = error.localizedDescription }
    }

    /// A creation intent is never retried implicitly, including after an App restart.
    @discardableResult
    func create(pluginID: String, providerID: String?, fork: Bool = false) async throws -> UUID {
        try begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        try draft.validate()
        guard enabled(), activeCount < 2, var updated = index else { throw AgentWorkflowError("At most two Orbiter tasks can be active. The draft is kept; nothing is queued.") }
        guard !updated.tasks.contains(where: { $0.id == draft.id }) else { throw AgentWorkflowError("This task already has a creation record. Check its tab instead of creating another.") }
        let source = fork ? try await forkSource() : nil
        guard source == nil || (source?.pluginID == pluginID && source?.readiness == .ready && UUID(uuidString: source?.conversationID ?? "") != nil) else {
            throw AgentWorkflowError("Fork requires a ready, verified Orbie conversation of the same Agent type. Choose New Agent for a different type.")
        }
        let title = uniqueTitle(draft.title)
        var task = OrbiterTask(
            id: draft.id, title: title, createdAt: Date(), goal: draft.goal, source: draft.source,
            materials: draft.materials, directory: draft.directory, origin: fork ? .fork : .newAgent,
            pluginID: pluginID, providerID: providerID, forkSource: source, draft: ""
        )
        task.draft = task.initialInput
        taskDrafts[task.id] = task.draft
        updated.tasks.append(task)
        try await persist(updated)
        try await store.saveMaterials(task, runs: [])
        do {
            task.pane = try await launch(task)
            try await replace(task)
            draft = OrbiterDraft()
            if let index {
                try await persist(index)
            }
            // Only the live user action may perform this initial delivery.
            // Refresh and reopening never execute a saved draft.
            for _ in 0..<20 {
                try await reconcile(inspect: true)
                guard let confirmed = tasks.first(where: { $0.id == task.id }) else { break }
                if availability(confirmed) == nil {
                    try await deliver(confirmed)
                    return task.id
                }
                if confirmed.binding != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            issue = "Agent created. Finish startup in its tab, then explicitly send the saved task."
            return task.id
        } catch {
            issue = "Creation or initial delivery was not fully confirmed: \(error.localizedDescription) The task, draft and any created tab are kept. Check the existing task before retrying."
            throw AgentWorkflowError(issue ?? error.localizedDescription)
        }
    }

    func associate(_ candidate: AgentWorkflowInstance, with taskID: UUID? = nil) async throws -> UUID {
        try begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        guard
            enabled(), var updated = index, candidate.hostID == updated.hostID,
            let current = instances.first(where: { candidate.matchesBinding($0) }), current.capabilities != nil,
            !tasks.contains(where: { $0.id != taskID && $0.pane?.isSamePane(as: current.workspacePane) == true }) else {
            throw AgentWorkflowError("Choose an unassociated, verified Agent on this Host.")
        }
        if let taskID {
            guard
                var task = tasks.first(where: { $0.id == taskID }), task.pluginID == current.pluginID,
                task.pendingRunID == nil, !executions(task).contains(where: { !$0.status.isTerminal }) else {
                throw AgentWorkflowError("Review unfinished executions before associating another Agent of the same type.")
            }
            task.pane = current.workspacePane
            task.binding = current
            task.directory = current.workingDirectory
            try await replace(task)
            return taskID
        }
        try draft.validate()
        guard !updated.tasks.contains(where: { $0.id == draft.id }) else { throw AgentWorkflowError("This task already exists.") }
        var task = OrbiterTask(id: draft.id, title: uniqueTitle(draft.title), createdAt: Date(), goal: draft.goal, source: draft.source, materials: draft.materials, directory: current.workingDirectory, origin: .associated, pluginID: current.pluginID, providerID: nil, forkSource: nil, pane: current.workspacePane, binding: current, draft: "")
        task.draft = task.initialInput
        updated.tasks.append(task)
        taskDrafts[task.id] = task.draft
        try await persist(updated)
        try await store.saveMaterials(task, runs: [])
        draft = OrbiterDraft()
        if let index {
            try await persist(index)
        }
        return task.id
    }

    func send(_ id: UUID) async throws {
        try begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        guard let task = tasks.first(where: { $0.id == id }) else { throw AgentWorkflowError("Task not found.") }
        try await deliver(task)
    }

    func reconnect(_ id: UUID) async throws {
        try begin()
        defer { finishOperation() }
        try await reconcile(inspect: true)
        guard
            var task = tasks.first(where: { $0.id == id }), task.pendingRunID == nil,
            !executions(task).contains(where: { !$0.status.isTerminal }),
            let current = currentInstance(task), current.capabilities != nil else { throw AgentWorkflowError("Review unfinished executions and recover the Agent in its tab first.") }
        task.binding = current
        task.pane = current.workspacePane
        try await replace(task)
    }

    func setArchived(_ id: UUID, _ archived: Bool) async throws {
        try begin()
        defer { finishOperation() }
        guard
            var task = tasks.first(where: { $0.id == id }), task.pendingRunID == nil,
            !executions(task).contains(where: { !$0.status.isTerminal }),
            currentInstance(task)?.readiness != .busy else { throw AgentWorkflowError("End the task execution before archiving.") }
        task.archived = archived
        try await replace(task)
    }

    func end(_ run: AgentWorkflowRun) async throws {
        try begin()
        defer { finishOperation() }
        guard tasks.contains(where: { $0.runIDs.contains(run.id) }) else { throw AgentWorkflowError("Execution not associated with a task.") }
        _ = try await workflows.end(runID: run.id, expectedRevision: run.revision)
        try await reconcile(inspect: false)
    }

    func clearUnstartedRequest(_ id: UUID) async throws {
        try begin()
        defer { finishOperation() }
        try await reconcile(inspect: false)
        guard var task = tasks.first(where: { $0.id == id }), let pending = task.pendingRunID else { return }
        guard !runs.contains(where: { $0.id == pending }) else { throw AgentWorkflowError("Review the existing execution; it cannot be resent as an unstarted request.") }
        task.pendingRunID = nil
        task.runIDs.removeAll { $0 == pending }
        try await replace(task)
    }

    private func deliver(_ task: OrbiterTask) async throws {
        if let reason = availability(task) {
            throw AgentWorkflowError(reason)
        }
        guard activeCount < 2, let current = currentInstance(task), let index else { throw AgentWorkflowError("Two Orbiter tasks are active. Your draft is kept; nothing is queued.") }
        let text = taskDrafts[task.id] ?? task.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentWorkflowError("Enter a follow-up message.") }
        let id = UUID()
        let node = AgentWorkflowNode(name: "Task", agentInstanceID: current.id)
        let definition = try await workflows.save(.init(id: id, name: "Orbiter: \(task.title)", hostID: index.hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: text)), expectedRevision: nil)
        var updated = task
        updated.runIDs.append(id)
        updated.pendingRunID = id
        try await replace(updated)
        do {
            _ = try await workflows.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: id, authorizationExpiresAt: Date().addingTimeInterval(3_600), expectedInstances: [current], retain: true)
            try await reconcile(inspect: false)
            issue = nil
        } catch {
            if error is AgentWorkflowStartRejection {
                let archive = try await workflows.snapshot()
                if !archive.runs.contains(where: { $0.id == id }) {
                    updated.pendingRunID = nil
                    updated.runIDs.removeAll { $0 == id }
                    try await replace(updated)
                }
            }
            throw error
        }
    }

    private func reconcile(inspect: Bool) async throws {
        if index == nil {
            index = try await store.load()
            draft = index?.draft ?? .init()
            taskDrafts = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.draft) })
        }
        guard var updated = index else { return }
        let archive = try await workflows.snapshot(refreshInstances: inspect)
        guard archive.hostID == updated.hostID else { throw AgentWorkflowError("The Orbiter Host changed.") }
        instances = archive.instances
        runs = archive.runs.filter { run in updated.tasks.contains { $0.runIDs.contains(run.id) } }
        for i in updated.tasks.indices {
            var task = updated.tasks[i]
            if inspect, task.pane == nil, task.origin != .associated {
                task.pane = try await locateCreation(task.id)
            }
            if let current = currentInstance(task) {
                if task.binding == nil || (task.binding?.matchesProcess(current) == true && task.binding?.conversationID.isEmpty == true) {
                    task.binding = current
                } else if task.binding?.matchesProcess(current) == true {
                    task.binding?.workspacePane = current.workspacePane
                }
                if task.binding?.matchesProcess(current) == true {
                    task.pane = current.workspacePane
                    task.directory = current.workingDirectory
                }
            }
            if let pending = task.pendingRunID, let run = runs.first(where: { $0.id == pending }) {
                task.pendingRunID = nil
                if (taskDrafts[task.id] ?? task.draft) == run.definition.initialInput.text {
                    taskDrafts[task.id] = ""
                }
            }
            try await store.saveMaterials(task, runs: executions(task))
            updated.tasks[i] = task
        }
        try await persist(updated)
    }

    private func replace(_ task: OrbiterTask) async throws {
        guard var updated = index, let position = updated.tasks.firstIndex(where: { $0.id == task.id }) else { throw AgentWorkflowError("Task not found.") }
        updated.tasks[position] = task
        try await persist(updated)
    }

    private func persist(_ value: OrbiterIndex) async throws {
        var updated = value
        updated.draft = draft
        for i in updated.tasks.indices {
            updated.tasks[i].draft = taskDrafts[updated.tasks[i].id] ?? updated.tasks[i].draft
        }
        if updated != index {
            try await store.save(updated)
            index = updated
        }
    }

    private func uniqueTitle(_ raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = base
        var suffix = 2
        while tasks.contains(where: { $0.title == title }) {
            title = "\(base) \(suffix)"
            suffix += 1
        }
        return title
    }

    private func begin() throws {
        guard !isBusy else { throw AgentWorkflowError("A task operation is already in progress.") }
        isBusy = true
        isOperating = true
    }

    private func finishOperation() {
        isBusy = false
        isOperating = false
        if refreshRequested {
            refreshRequested = false
            Task { [weak self] in await self?.refresh(inspect: false) }
        }
    }
}
