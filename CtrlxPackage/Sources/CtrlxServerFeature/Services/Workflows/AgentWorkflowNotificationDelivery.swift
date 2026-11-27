import CtrlxNetworking
import Foundation

/// Retries only destinations without a confirmed submission. Run revisions are
/// deliberately independent of notification bookkeeping.
actor AgentWorkflowNotificationDelivery {
    private let store: AgentWorkflowStore
    private let destinations: @Sendable () async -> [String]
    private let send: @Sendable (AgentWorkflowNotification, String) async throws -> Void
    private let now: @Sendable () -> Date
    private var flushing = false

    init(
        store: AgentWorkflowStore,
        destinations: @escaping @Sendable () async -> [String],
        send: @escaping @Sendable (AgentWorkflowNotification, String) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.destinations = destinations
        self.send = send
        self.now = now
    }

    func flush() async throws {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        let currentDestinations = Set(await destinations())
        let events = try await store.snapshot().notifications?.values.sorted { $0.createdAt < $1.createdAt } ?? []
        for event in events {
            let deliveries = event.deliveries ?? currentDestinations.sorted().map { .init(destination: $0) }
            try await store.setNotificationDeliveries(eventID: event.id, runID: event.target.runID, deliveries: deliveries)
            for var delivery in deliveries where delivery.submittedAt == nil && currentDestinations.contains(delivery.destination) {
                try Task.checkCancellation()
                let timestamp = now()
                let delay = min(300.0, 10 * pow(2, Double(min(delivery.attempts, 5))))
                if let last = delivery.lastAttemptAt, timestamp.timeIntervalSince(last) < delay {
                    continue
                }
                guard try await store.snapshot().notifications?[event.target.runID]?.id == event.id else { break }
                delivery.attempts += 1
                delivery.lastAttemptAt = timestamp
                do {
                    try await send(event, delivery.destination)
                    delivery.submittedAt = timestamp
                    delivery.error = nil
                } catch {
                    if Task.isCancelled {
                        throw error
                    }
                    delivery.error = String(error.localizedDescription.prefix(300))
                }
                try await store.recordNotificationDelivery(eventID: event.id, runID: event.target.runID, delivery: delivery)
            }
        }
    }
}

extension AgentWorkflowStore {
    struct NotificationContext: Sendable {
        let run: AgentWorkflowRun
        let invocation: AgentWorkflowInvocation
        let instance: AgentWorkflowInstance

        var nodeName: String {
            run.definition.nodes.first { $0.id == invocation.nodeID }?.name ?? instance.displayName
        }

        var target: AgentWorkflowNotificationTarget {
            .init(hostID: instance.hostID, runID: run.id, eventID: run.id)
        }
    }

    func notificationContext(agentID: AgentID, runtimeID: String, conversationID: String) throws -> NotificationContext? {
        for run in try load().runs.reversed() where !run.status.isTerminal {
            for call in run.invocations.reversed() where call.round == run.round && [.writing, .awaitingAcceptance, .uncertain, .running].contains(call.status) {
                guard
                    let instance = run.instance(for: call), instance.agentID == agentID,
                    instance.processRuntimeID == runtimeID, instance.conversationID == conversationID else { continue }
                return NotificationContext(run: run, invocation: call, instance: instance)
            }
        }
        return nil
    }

    /// Persist the pause and its actionable alert together. The Agent alert is
    /// replaced by this intent, so approval and automatic pause cannot double-alert.
    func pauseForApproval(context: NotificationContext, requestID: String, body: String, action: NotificationActionContext?) throws -> Bool {
        var archive = try load()
        guard
            let index = archive.runs.firstIndex(where: { $0.id == context.run.id }),
            !archive.runs[index].status.isTerminal,
            let call = archive.runs[index].invocations.first(where: { $0.id == context.invocation.id }),
            [.running, .uncertain, .awaitingAcceptance].contains(call.status),
            archive.runs[index].instance(for: call)?.matchesBinding(context.instance) == true else { return false }
        let current = archive.runs[index]
        if current.invocations.contains(where: { $0.round == current.round && $0.status == .failed }) || archive.pendingFailure(in: current) != nil {
            return true
        }
        guard current.controlRevision == context.run.controlRevision else { return false }
        if archive.notifications?[context.run.id]?.approvalRequestID == requestID {
            return true
        }
        var execution = try AgentWorkflowExecution(validating: archive.runs[index])
        execution.pause(reason: "\(context.nodeName): approval required. \(String(body.prefix(200)))")
        archive.runs[index] = execution.run
        var event = AgentWorkflowNotification(run: execution.run, hostID: archive.hostID, kind: .attention)
        event.nodeName = context.nodeName
        event.agentID = context.instance.agentID
        event.paneID = context.instance.paneID
        event.action = action
        event.approvalRequestID = requestID
        try commit(archive, notification: event)
        return true
    }

    func setNotificationDeliveries(eventID: UUID, runID: UUID, deliveries: [AgentWorkflowNotification.Delivery]) throws {
        var archive = try snapshot()
        guard archive.notifications?[runID]?.id == eventID, archive.notifications?[runID]?.deliveries == nil else { return }
        archive.notifications?[runID]?.deliveries = deliveries
        try commit(archive)
    }

    func recordNotificationDelivery(eventID: UUID, runID: UUID, delivery: AgentWorkflowNotification.Delivery) throws {
        var archive = try snapshot()
        guard
            archive.notifications?[runID]?.id == eventID,
            let index = archive.notifications?[runID]?.deliveries?.firstIndex(where: { $0.destination == delivery.destination }) else { return }
        archive.notifications?[runID]?.deliveries?[index] = delivery
        try commit(archive)
    }
}
