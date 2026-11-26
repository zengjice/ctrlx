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
