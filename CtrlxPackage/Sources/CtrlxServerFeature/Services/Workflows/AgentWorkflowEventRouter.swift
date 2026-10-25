import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

struct AgentWorkflowTurnContext: Sendable {
    let runID: UUID
    let invocation: AgentWorkflowInvocation
    let instance: AgentWorkflowInstance
    let candidate: PluginWorkflowEvent
}

/// Joins kernel-authenticated plugin evidence to the Host's durable invocation.
/// A native Stop only returns a candidate for the transcript monitor to verify.
actor AgentWorkflowEventRouter {
    private let store: AgentWorkflowStore
    private let runner: AgentWorkflowRunner
    private struct PendingSubmission {
        let context: AgentWorkflowTurnContext
        var following: PluginWorkflowEvent?
        var retry: Task<Void, Never>?
    }

    private var stopped = false
    private var pending: [UUID: PendingSubmission] = [:]
    private let verificationTimeout: Duration
    private let onVerified: @Sendable (AgentWorkflowTurnContext) async -> Void
    private let onFailure: @Sendable (String) -> Void
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance

    init(
        store: AgentWorkflowStore, runner: AgentWorkflowRunner,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        onVerified: @escaping @Sendable (AgentWorkflowTurnContext) async -> Void = { _ in },
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.runner = runner
        self.inspect = inspect
        self.verificationTimeout = verificationTimeout
        self.onVerified = onVerified
        self.onFailure = onFailure
    }

    func shutdown() async {
        stopped = true
        let tasks = pending.values.compactMap(\.retry)
        pending.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    func receive(_ event: PluginEvent, peer: PluginIngressPeer) async throws -> AgentWorkflowTurnContext? {
        guard !stopped, let native = event.workflow else { return nil }
        let archive = try await store.snapshot()
        guard
            !stopped,
            let observed = archive.instances.first(where: {
                $0.pluginID == event.pluginID && $0.conversationID == event.sessionID
                    && $0.paneID == event.tmuxPane
                    && peer.contains(processID: $0.processID, runtimeID: $0.processRuntimeID)
            }) else { return nil }
        if
            native.kind != .submitted,
            let id = pending.first(where: {
                $0.value.context.instance.matchesBinding(observed)
                    && $0.value.context.candidate.nativeTurnID == native.nativeTurnID
                    && $0.value.context.candidate.transcriptPath == native.transcriptPath
            })?.key {
            if pending[id]?.following?.kind != .failed {
                pending[id]?.following = native
            }
            return nil
        }
        // Submission identity is checked by verifySubmission, which retains
        // authenticated evidence through temporary process-scan outages.
        let instance = native.kind == .failed ? try await inspect(observed) : observed
        guard observed.matchesBinding(instance) else { return nil }

        for run in archive.runs where run.instances.contains(where: { $0.matchesBinding(instance) }) {
            let invocations = run.invocations.filter { $0.delivery.toAgentID == instance.id }
            switch native.kind {
            case .submitted:
                if
                    let invocation = invocations.first(where: {
                        $0.delivery.input.text == native.text
                            && [.writing, .awaitingAcceptance, .uncertain, .running, .succeeded, .failed].contains($0.status)
                    }) {
                    guard pending[invocation.id] == nil else { return nil }
                    let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                    pending[invocation.id] = .init(context: context)
                    do { return try await verifySubmission(invocation.id) }
                    catch {
                        pending.removeValue(forKey: invocation.id)?.retry?.cancel()
                        throw error
                    }
                }
                if !run.status.isTerminal {
                    try await store.update(runID: run.id) {
                        $0.pause(reason: "The Agent received input outside the current workflow. Verify the task before continuing.")
                    }
                }
            case .failed,
                 .stopCandidate:
                guard
                    let invocation = invocations.first(where: {
                        $0.nativeTurnID == native.nativeTurnID && $0.nativeTranscriptPath == native.transcriptPath
                            && [.running, .uncertain].contains($0.status)
                    }) else { continue }
                return try await routeFollowing(.init(runID: run.id, invocation: invocation, instance: instance, candidate: native))
            }
        }
        return nil
    }

    private func verifySubmission(_ id: UUID) async throws -> AgentWorkflowTurnContext? {
        guard let candidate = pending[id]?.context else { return nil }
        let live: AgentWorkflowInstance
        do { live = try await inspect(candidate.instance) }
        catch is AgentWorkflowInspectionUnavailable {
            try await store.update(runID: candidate.runID) {
                $0.pause(reason: "The Agent cannot currently be inspected. Its submission receipt is awaiting verification; nothing will be resent.")
            }
            if pending[id]?.retry == nil {
                pending[id]?.retry = Task { await self.retrySubmission(id) }
            }
            return nil
        }
        try Task.checkCancellation()
        guard pending[id] != nil else { return nil }
        guard candidate.instance.matchesBinding(live) else {
            throw AgentWorkflowError("The Agent changed before its submission receipt could be verified.")
        }
        try await runner.accepted(
            runID: candidate.runID, invocationID: id, instance: live,
            nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath
        )
        guard let resolved = pending.removeValue(forKey: id) else { return nil }
        if let following = resolved.following {
            // The Stop may have arrived while inspection or receipt persistence
            // was suspended. Route it only after the native turn is linked.
            return try await routeFollowing(.init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: following))
        }
        guard candidate.invocation.nativeTurnID == nil else { return nil }
        return .init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: candidate.candidate)
    }

    private func retrySubmission(_ id: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: verificationTimeout)
        do {
            while pending[id] != nil {
                try await Task.sleep(for: .milliseconds(200))
                guard ContinuousClock.now < deadline else {
                    throw AgentWorkflowError("Submission receipt verification timed out. Check the Agent before continuing; the task will not be resent.")
                }
                if let context = try await verifySubmission(id) {
                    await onVerified(context)
                }
            }
        } catch {
            guard let unresolved = pending.removeValue(forKey: id), !Task.isCancelled else { return }
            onFailure("Could not verify a workflow submission receipt: \(error.localizedDescription)")
            do { try await store.update(runID: unresolved.context.runID) { $0.pause(reason: error.localizedDescription) } }
            catch { onFailure("Could not pause the workflow: \(error.localizedDescription)") }
        }
    }

    private func routeFollowing(_ context: AgentWorkflowTurnContext) async throws -> AgentWorkflowTurnContext? {
        if context.candidate.kind == .failed {
            try await runner.failed(
                runID: context.runID, invocationID: context.invocation.id, instance: context.instance,
                nativeTurnID: context.candidate.nativeTurnID, reason: context.candidate.text
            )
            return nil
        }
        return context
    }
}
