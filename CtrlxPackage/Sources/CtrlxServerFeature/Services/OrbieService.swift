import CtrlxNetworking
import Foundation
import Observation

@MainActor
@Observable
final class OrbieService {
    private(set) var record: OrbieRecord?
    private(set) var instance: AgentWorkflowInstance?
    private(set) var runs: [AgentWorkflowRun] = []
    private(set) var isBusy = false
    private(set) var issue: String?
    var draft = ""

    @ObservationIgnored private let store: OrbieStore
    @ObservationIgnored private let workflows: AgentWorkflowService
    @ObservationIgnored private let launch: (OrbieRecord.Creation) async throws -> WorkspacePaneIdentity
    @ObservationIgnored private let locateCreation: (UUID) async throws -> WorkspacePaneIdentity?

    init(
        store: OrbieStore, workflows: AgentWorkflowService,
        launch: @escaping (OrbieRecord.Creation) async throws -> WorkspacePaneIdentity,
        locateCreation: @escaping (UUID) async throws -> WorkspacePaneIdentity?
    ) {
        self.store = store
        self.workflows = workflows
        self.launch = launch
        self.locateCreation = locateCreation
    }

    var directory: String {
        store.paths.orbieDirectory.path
    }

    var hasActiveRun: Bool {
        runs.contains { !$0.status.isTerminal }
    }

    var availability: String? {
        guard let record else { return "Loading Orbie…" }
        guard record.enabled else { return "Orbie is disabled on this Mac. Its Agent and saved data are retained." }
        guard record.creation != nil else { return "Create Orbie on this Mac to begin." }
        guard let binding = record.binding, let instance else {
            return "Waiting for the Orbie Agent. Open its terminal to finish startup, or check the existing workspace recovery controls."
        }
        guard binding.matchesBinding(instance) else {
            return "The Orbie process or conversation changed. Open its terminal and explicitly reconnect before sending."
        }
        if let issue = instance.capabilityIssue {
            return issue
        }
        guard record.pendingRunID == nil else { return "The last submission was not confirmed. Review it before sending another message." }
        if hasActiveRun {
            return runs.last(where: { !$0.status.isTerminal })?.issue ?? "Orbie has an unfinished message. Open its terminal for questions or approvals."
        }
        return switch instance.readiness {
        case .ready: nil
        case .busy: "Orbie is working. Your draft will be kept."
        case .draft: "Orbie has unsent terminal input. Send or clear it in the Agent tab; your panel draft will be kept."
        case .awaitingHuman: "Orbie needs an answer or approval. Continue in its Agent tab."
        case .unavailable: "Orbie’s input cannot be verified. Open its Agent tab and check startup or recovery."
        }
    }

    func refresh(inspect: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if record == nil {
                let saved = try await store.load()
                record = saved
                draft = saved.draft
            }
            try await reconcile(inspect: inspect)
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func create(pluginID: String, providerID: String?) async throws {
        guard !isBusy, var record, record.creation == nil else {
            throw AgentWorkflowError("Orbie already exists or creation is being checked. Open or reconcile the existing Agent first.")
        }
        isBusy = true
        defer { isBusy = false }
        let directory = try await store.prepareDirectory()
        let intent = OrbieRecord.Creation(id: UUID(), pluginID: pluginID, providerID: providerID, directory: directory)
        record.enabled = true
        record.creation = intent
        try await persist(record)
        // Once this intent is durable, any failure requires reconciliation.
        // Never interpret a lost reply as permission to launch another Agent.
        do {
            record.creation?.pane = try await launch(intent)
            try await persist(record)
            try await reconcile(inspect: true)
            issue = nil
        } catch {
            issue = "Creation was not fully confirmed: \(error.localizedDescription) Check the existing Agent before rebuilding."
            throw AgentWorkflowError(issue ?? error.localizedDescription)
        }
    }

    func send() async {
        guard !isBusy, record != nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await reconcile(inspect: true)
            guard availability == nil, var updated = record, let instance else {
                throw AgentWorkflowError(availability ?? "Orbie is unavailable.")
            }
            let text = draft
            let id = UUID()
            let node = AgentWorkflowNode(name: "Reply", agentInstanceID: instance.id)
            let definition = try await workflows.save(.init(
                id: id, name: "Orbie", hostID: updated.hostID, nodes: [node], edges: [],
                entryNodeID: node.id, initialInput: .init(text: text)
            ), expectedRevision: nil)
            updated.draft = text
            updated.runIDs.append(id)
            updated.pendingRunID = id
            try await persist(updated)
            _ = try await workflows.start(
                definitionID: definition.id, expectedRevision: definition.revision, requestID: id,
                authorizationExpiresAt: Date().addingTimeInterval(3_600), expectedInstances: [instance]
            )
            // A failed save leaves the request association intact. Refresh reads
            // the existing run; it never starts or resumes it automatically.
            try await reconcile(inspect: false)
            if draft == text {
                draft = ""
            }
            issue = nil
        } catch {
            // Start rejection before a committed run is safe to discard; an
            // uncertain submission keeps its reference until explicitly reviewed.
            if error is AgentWorkflowStartRejection {
                do { try await clearUnstartedRequest() }
                catch { issue = error.localizedDescription
                    return
                }
            }
            issue = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy, var updated = record else { return }
        isBusy = true
        defer { isBusy = false }
        updated.enabled = enabled
        updated.draft = draft
        do { try await persist(updated)
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// Explicitly accepts a newly inspected process at the same durable target,
    /// after the operator has used the ordinary terminal/recovery UI.
    func reconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await reconcile(inspect: true)
            guard
                var updated = record, !hasActiveRun, updated.pendingRunID == nil,
                let current = instance, current.capabilities != nil,
                current.pluginID == updated.creation?.pluginID else {
                throw AgentWorkflowError("Review unfinished messages and the current Agent before reconnecting.")
            }
            updated.binding = current
            try await persist(updated)
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func reviewUnstartedRequest() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await clearUnstartedRequest()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func endMessage(_ run: AgentWorkflowRun) async {
        guard !isBusy, record?.runIDs.contains(run.id) == true else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await workflows.end(runID: run.id, expectedRevision: run.revision)
            try await reconcile(inspect: false)
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// Explicit recreation detaches the old association without closing its
    /// terminal or deleting any workflow records or user files.
    func resetBinding() async {
        guard !isBusy, !hasActiveRun, record?.pendingRunID == nil, var updated = record else { return }
        isBusy = true
        defer { isBusy = false }
        updated.creation = nil
        updated.binding = nil
        do { try await persist(updated)
            instance = nil
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    private func reconcile(inspect: Bool) async throws {
        guard var updated = record else { return }
        if inspect, let creation = updated.creation, creation.pane == nil {
            updated.creation?.pane = try await locateCreation(creation.id)
        }
        let archive = try await workflows.snapshot(refreshInstances: inspect && updated.enabled)
        guard archive.hostID == updated.hostID else { throw AgentWorkflowError("The Orbie Host changed.") }
        runs = updated.runIDs.compactMap { id in archive.runs.first { $0.id == id } }
        let target = updated.binding?.target ?? updated.creation?.pane.map {
            AgentWorkflowTarget(hostID: updated.hostID, windowID: $0.windowID, paneID: $0.paneID)
        }
        instance = updated.binding.flatMap { binding in
            archive.instances.first { binding.matchesProcess($0) }
        } ?? archive.instances.first { $0.target == target && $0.pluginID == updated.creation?.pluginID }
        if let instance {
            if updated.binding == nil {
                updated.binding = instance
            } else if let binding = updated.binding, binding.matchesProcess(instance) {
                if binding.conversationID.isEmpty {
                    // Only the workflow channel may establish the first native ID.
                    updated.binding = instance
                } else {
                    // A live pane can move without granting a new conversation authority.
                    updated.binding?.workspacePane = instance.workspacePane
                }
            }
        }
        if let id = updated.pendingRunID, runs.contains(where: { $0.id == id }) {
            if draft == updated.draft {
                draft = ""
            }
            updated.draft = ""
            updated.pendingRunID = nil
        }
        if updated != record {
            try await persist(updated)
        }
    }

    private func clearUnstartedRequest() async throws {
        guard var updated = record, let id = updated.pendingRunID else { return }
        let archive = try await workflows.snapshot()
        guard !archive.runs.contains(where: { $0.id == id }) else {
            throw AgentWorkflowError("This message has an execution record. Review that record instead of resending it.")
        }
        updated.pendingRunID = nil
        updated.runIDs.removeAll { $0 == id }
        try await persist(updated)
    }

    private func persist(_ updated: OrbieRecord) async throws {
        try await store.save(updated)
        record = updated
    }
}
