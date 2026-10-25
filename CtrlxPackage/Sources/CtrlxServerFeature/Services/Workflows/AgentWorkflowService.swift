import CtrlxNetworking
import Foundation

/// Human management uses the same durable ledger as native Agent events. The
/// runner remains Host-owned; Viewer lifetime never owns execution tasks.
actor AgentWorkflowService {
    private let store: AgentWorkflowStore
    private let scan: @Sendable ([AgentWorkflowInstance]) async throws -> [AgentWorkflowObservation]
    private let schedule: @Sendable (UUID) async -> Void
    private let now: @Sendable () -> Date
    private let onFailure: @Sendable (String) -> Void
    private var refreshing: Task<[AgentWorkflowInstance], Error>?
    private var monitoring: Task<Void, Never>?
    private var idleSince: [UUID: Date] = [:]
    private let attachmentReader = AgentWorkflowAttachmentReader()

    init(
        store: AgentWorkflowStore,
        scan: @escaping @Sendable ([AgentWorkflowInstance]) async throws -> [AgentWorkflowObservation],
        schedule: @escaping @Sendable (UUID) async -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.scan = scan
        self.schedule = schedule
        self.now = now
        self.onFailure = onFailure
    }

    /// Host-owned even with no Viewer connected. No process scan is needed when
    /// every run is paused or terminal; start/resume already perform their own.
    func startMonitoring(interval: Duration = .seconds(10)) {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                do { try await self?.checkActiveRuns() }
                catch {
                    if !Task.isCancelled {
                        await self?.reportMonitorFailure(error.localizedDescription)
                    }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func checkActiveRuns(completionGrace: TimeInterval = 60) async throws {
        let timestamp = now()
        // Paused runs still need current instance state so operators can open
        // a recovered terminal and answer Questions without resuming handoffs.
        let monitored = try await store.snapshot().runs.filter { !$0.status.isTerminal }
        guard !monitored.isEmpty else {
            idleSince.removeAll()
            return
        }
        for run in monitored where run.status != .paused && run.authorizationExpiresAt <= timestamp {
            try await store.update(runID: run.id) { $0.pause(reason: "Workflow authorization expired. No further tasks will be sent.") }
        }
        let instances: [AgentWorkflowInstance]
        do { instances = monitored.contains(where: { !$0.instances.isEmpty }) ? try await refreshInstancesCatalog() : [] }
        catch {
            idleSince.removeAll()
            throw error
        }
        try Task.checkCancellation()
        let runs = try await store.snapshot().runs.filter { $0.status == .running || $0.status == .finishing }
        var observedIdle: Set<UUID> = []
        for run in runs {
            if
                let blocked = run.instances.compactMap({ binding in instances.first { binding.matchesBinding($0) } })
                    .first(where: { $0.readiness == .draft || $0.readiness == .awaitingHuman }) {
                try await store.update(runID: run.id) {
                    $0.pause(reason: "\(blocked.displayName) needs human input or has a draft. Resolve it before continuing.")
                }
                continue
            }
            for invocation in run.invocations where invocation.status == .running {
                guard
                    let bound = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }),
                    instances.contains(where: { bound.matchesBinding($0) && $0.readiness == .ready }) else { continue }
                observedIdle.insert(invocation.id)
                let since = idleSince[invocation.id] ?? timestamp
                idleSince[invocation.id] = since
                guard timestamp.timeIntervalSince(since) >= completionGrace else { continue }
                // A submission hook can reject a task after emitting a receipt,
                // or a final hook may be missing. Idle is never success evidence.
                try await store.update(runID: run.id) { execution in
                    guard execution.run.invocations.contains(where: { $0.id == invocation.id && $0.status == .running }) else { return }
                    execution.pause(reason: "\(bound.displayName) returned to its input without a verified final result. Check its terminal; this task will not be resent automatically.")
                }
            }
        }
        idleSince = idleSince.filter { observedIdle.contains($0.key) }
    }

    private func reportMonitorFailure(_ reason: String) {
        onFailure("Could not check workflow Agent state: \(reason)")
    }

    func snapshot(refreshInstances: Bool = false) async throws -> AgentWorkflowArchive {
        if refreshInstances {
            _ = try await refreshInstancesCatalog()
        }
        return try await store.snapshot()
    }

    /// Coalesce complete scans so a late scan cannot overwrite newer process
    /// evidence. A failed scan preserves the existing catalog and run bindings.
    @discardableResult
    func refreshInstancesCatalog() async throws -> [AgentWorkflowInstance] {
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { [store, scan] in
            let previous = try await store.snapshot().instances
            let observations = try await scan(previous)
            try Task.checkCancellation()
            return try await store.reconcile(observations)
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func save(_ definition: AgentWorkflowDefinition, expectedRevision: Int?) async throws -> AgentWorkflowDefinition {
        try AgentWorkflowWire.validate(definition)
        return try await store.saveDefinition(definition, expectedRevision: expectedRevision)
    }

    func deleteDefinition(id: UUID, expectedRevision: Int) async throws {
        try await store.deleteDefinition(id: id, expectedRevision: expectedRevision)
    }

    func start(definitionID: UUID, expectedRevision: Int, requestID: UUID, authorizationExpiresAt: Date) async throws -> AgentWorkflowRun {
        // A retry after a lost reply must return the original run even when the
        // Agent is now busy, the template changed, or a new scan is unavailable.
        if let existing = try await store.snapshot().runs.first(where: { $0.id == requestID }) {
            guard existing.definition.id == definitionID, existing.definition.revision == expectedRevision else {
                throw AgentWorkflowError("This request ID already belongs to a different workflow start.")
            }
            return existing
        }
        if try await store.snapshot().definitions.first(where: { $0.id == definitionID })?.agentInstanceIDs.isEmpty == false {
            _ = try await refreshInstancesCatalog()
        }
        let attachments = try await store.definitionAttachments(id: definitionID, revision: expectedRevision)
        try await attachmentReader.validate(attachments)
        let run = try await store.start(
            definitionID: definitionID, expectedRevision: expectedRevision,
            requestID: requestID, now: now(), authorizationExpiresAt: authorizationExpiresAt
        )
        await schedule(run.id)
        return run
    }

    func pause(runID: UUID, expectedRevision: Int) async throws -> AgentWorkflowRun {
        try await store.update(runID: runID, expectedRevision: expectedRevision) {
            $0.pause(reason: "Paused by a workflow operator.")
        }
    }

    func resume(runID: UUID, expectedRevision: Int, roundLimit: Int? = nil) async throws -> AgentWorkflowRun {
        let needsAgents = try await store.snapshot().runs.first(where: { $0.id == runID })?.instances.isEmpty == false
        let instances = needsAgents ? try await refreshInstancesCatalog() : []
        let timestamp = now()
        let run = try await store.update(runID: runID, expectedRevision: expectedRevision) {
            try $0.resume(instances: instances, roundLimit: roundLimit, now: timestamp)
        }
        await schedule(run.id)
        return run
    }

    func end(runID: UUID, expectedRevision: Int) async throws -> AgentWorkflowRun {
        try await store.update(runID: runID, expectedRevision: expectedRevision) { $0.end() }
    }

    func deleteRun(id: UUID, expectedRevision: Int) async throws {
        try await store.deleteRun(id: id, expectedRevision: expectedRevision)
    }

    func attachments(_ ids: [UUID]) async throws -> [AgentWorkflowAttachment] {
        try await store.attachmentMetadata(ids)
    }

    func uploadAttachment(_ operation: AgentWorkflowAttachmentUpload) async throws -> (offset: Int, attachment: AgentWorkflowAttachment?) {
        try await store.uploadAttachment(operation)
    }

    func discardAttachments(_ ids: [UUID]) async throws {
        try await store.discardAttachments(ids)
    }

    func linkConversion(sourceID: UUID, outputs: [AgentWorkflowConversionOutput]) async throws -> [AgentWorkflowAttachment] {
        try await store.linkConversion(sourceID: sourceID, outputs: outputs)
    }

    func shutdown() async {
        monitoring?.cancel()
        refreshing?.cancel()
        await monitoring?.value
        monitoring = nil
        _ = try? await refreshing?.value
        await store.shutdownAttachmentUploads()
    }
}
