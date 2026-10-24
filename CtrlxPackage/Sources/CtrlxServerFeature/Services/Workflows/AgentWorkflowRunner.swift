import CtrlxNetworking
import Foundation

/// Only a writer which has not submitted any bytes (or received an explicit
/// tmux rejection before paste) may use this proof to keep an input retryable.
struct AgentWorkflowInputNotWritten: LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? {
        reason
    }
}

/// Agent-specific preparation may register a hook correlation, but must not
/// write terminal input. The writer must recheck process identity and the input
/// generation in the same ordered path used by human terminal input.
struct AgentWorkflowTransport: Sendable {
    var inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    var prepare: @Sendable (AgentWorkflowInvocation, AgentWorkflowInstance) async throws -> Void
    var write: @Sendable (AgentWorkflowInvocation, AgentWorkflowInstance) async throws -> Void
    var discard: @Sendable (UUID) async -> Void = { _ in }
}

actor AgentWorkflowRunner {
    private let store: AgentWorkflowStore
    private let transport: AgentWorkflowTransport
    private let now: @Sendable () -> Date
    private let acceptanceTimeout: Duration
    private let onFailure: @Sendable (String) -> Void
    private var pumps: [UUID: Task<Void, Never>] = [:]
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var acknowledgements: [UUID: Task<Void, Never>] = [:]
    private var requestedPumps: Set<UUID> = []
    private var halted = false

    init(
        store: AgentWorkflowStore,
        transport: AgentWorkflowTransport,
        acceptanceTimeout: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() },
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.transport = transport
        self.acceptanceTimeout = acceptanceTimeout
        self.now = now
        self.onFailure = onFailure
    }

    /// Safe to repeat, including when two completed branches request a join.
    func schedule(runID: UUID) {
        guard !halted else { return }
        requestedPumps.insert(runID)
        guard pumps[runID] == nil else { return }
        pumps[runID] = Task { await self.pump(runID: runID) }
    }

    func accepted(runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, transcriptPath: String? = nil) async throws {
        try await store.update(runID: runID) {
            try $0.accept(invocationID: invocationID, instance: instance, nativeTurnID: nativeTurnID, transcriptPath: transcriptPath)
        }
        acknowledgements.removeValue(forKey: invocationID)?.cancel()
    }

    func succeeded(runID: UUID, result: AgentWorkflowResult, instance: AgentWorkflowInstance) async throws {
        let timestamp = now()
        try await store.update(runID: runID) {
            try $0.succeed(result, instance: instance, now: timestamp)
        }
        acknowledgements.removeValue(forKey: result.invocationID)?.cancel()
        schedule(runID: runID)
    }

    func failed(runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, reason: String) async throws {
        try await store.update(runID: runID) {
            try $0.fail(invocationID: invocationID, instance: instance, nativeTurnID: nativeTurnID, reason: reason)
        }
        acknowledgements.removeValue(forKey: invocationID)?.cancel()
    }

    /// Only queued work is cancelled. Already-written inputs remain recorded
    /// and are reconciled, never automatically replayed, after Host restart.
    func shutdown() async {
        let tasks = Array(pumps.values) + Array(deliveries.values) + Array(acknowledgements.values)
        cancelScheduling()
        for task in tasks {
            await task.value
        }
    }

    private func cancelScheduling() {
        halted = true
        requestedPumps.removeAll()
        for task in pumps.values {
            task.cancel()
        }
        for task in deliveries.values {
            task.cancel()
        }
        for task in acknowledgements.values {
            task.cancel()
        }
    }

    private func pump(runID: UUID) async {
        defer { pumps.removeValue(forKey: runID) }
        while !halted, !Task.isCancelled, requestedPumps.remove(runID) != nil {
            do {
                guard let current = try await store.snapshot().runs.first(where: { $0.id == runID }), current.status == .running else { continue }
                let timestamp = now()
                let prepared: AgentWorkflowRun
                do {
                    prepared = try await store.update(runID: runID) { execution in
                        for nodeID in execution.readyNodeIDs {
                            _ = try execution.prepareInvocation(nodeID: nodeID, now: timestamp)
                        }
                    }
                } catch let error as AgentWorkflowError {
                    try await pause(runID: runID, reason: error.localizedDescription)
                    continue
                }
                guard !halted, !Task.isCancelled else { return }
                // Content outputs are committed with their invocation. Pump
                // newly ready downstream nodes only after that durable commit.
                if try !AgentWorkflowExecution(validating: prepared).readyNodeIDs.isEmpty {
                    requestedPumps.insert(runID)
                }
                for invocation in prepared.invocations where invocation.status == .pending {
                    guard deliveries[invocation.id] == nil else { continue }
                    deliveries[invocation.id] = Task { await self.deliver(runID: runID, invocationID: invocation.id) }
                }
            } catch {
                haltAfterStorageFailure(error)
            }
        }
    }

    private func deliver(runID: UUID, invocationID: UUID) async {
        defer {
            deliveries.removeValue(forKey: invocationID)
            // Resume can arrive while discard awaits I/O. Recheck after releasing
            // this delivery, otherwise that earlier pump can miss a pending input.
            schedule(runID: runID)
        }
        await deliverAttempt(runID: runID, invocationID: invocationID)
        await transport.discard(invocationID)
    }

    private func deliverAttempt(runID: UUID, invocationID: UUID) async {
        do {
            guard
                !halted, !Task.isCancelled,
                let run = try await store.snapshot().runs.first(where: { $0.id == runID }), run.status == .running,
                let invocation = run.invocations.first(where: { $0.id == invocationID }), invocation.status == .pending,
                let binding = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }) else { return }
            let live: AgentWorkflowInstance
            do {
                live = try await transport.inspect(binding)
                guard binding.matchesBinding(live), live.readiness == .ready else {
                    throw AgentWorkflowError("The Agent changed, is busy, or has an unsent draft. Nothing was sent.")
                }
                try Task.checkCancellation()
                try await transport.prepare(invocation, live)
                try Task.checkCancellation()
            } catch {
                if !halted {
                    try await pause(runID: runID, reason: error.localizedDescription)
                }
                return
            }
            guard !halted else { return }
            let timestamp = now()
            do {
                try await store.update(runID: runID) {
                    try $0.beginWriting(invocationID: invocationID, instance: live, now: timestamp)
                }
            } catch let error as AgentWorkflowError {
                try await pause(runID: runID, reason: error.localizedDescription)
                return
            }
            // From this durable point onwards, cancellation/errors can no longer
            // prove that the terminal did not receive part of the input.
            do {
                if Task.isCancelled {
                    throw AgentWorkflowInputNotWritten(reason: "Submission was cancelled before writing terminal input.")
                }
                try await transport.write(invocation, live)
            } catch let error as AgentWorkflowInputNotWritten {
                try await store.update(runID: runID) { try $0.didNotWrite(invocationID: invocationID, reason: error.reason) }
                return
            } catch {
                let reason = "Terminal submission could not be confirmed: \(error.localizedDescription)"
                try await store.update(runID: runID) { try $0.writeUncertain(invocationID: invocationID, reason: reason) }
                return
            }
            let afterWrite = try await store.update(runID: runID) { try $0.didWrite(invocationID: invocationID) }
            if !halted, afterWrite.invocations.first(where: { $0.id == invocationID })?.status == .awaitingAcceptance {
                acknowledgements[invocationID] = Task {
                    do {
                        try await Task.sleep(for: acceptanceTimeout)
                        try await store.update(runID: runID) {
                            try $0.writeUncertain(invocationID: invocationID, reason: "The Agent did not confirm task acceptance. Verify it before continuing; do not resend.")
                        }
                    } catch is CancellationError {
                        // A verified acceptance or Host shutdown cancels this wait.
                    } catch {
                        haltAfterStorageFailure(error)
                    }
                    acknowledgements.removeValue(forKey: invocationID)
                }
            }
        } catch {
            haltAfterStorageFailure(error)
        }
    }

    private func pause(runID: UUID, reason: String) async throws {
        try await store.update(runID: runID) { $0.pause(reason: reason) }
    }

    private func haltAfterStorageFailure(_ error: any Error) {
        cancelScheduling()
        onFailure("Workflow scheduling stopped because its state could not be saved: \(error.localizedDescription)")
    }
}
