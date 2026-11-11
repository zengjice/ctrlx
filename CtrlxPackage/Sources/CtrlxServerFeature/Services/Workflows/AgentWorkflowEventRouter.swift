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
        let bindFirstConversation: Bool
        var isStepContinuation = false
        var verifying = false
        var revision = 0
        var following: PluginWorkflowEvent?
        var continuation: PluginWorkflowEvent?
        var continuationFollowing: PluginWorkflowEvent?
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

    func requireVerifiedSubmission(_ invocationID: UUID) async throws {
        // A timed-out receipt still supersedes the old turn. An explicit retry
        // may verify it, but must never fall back to completing that old turn.
        if !stopped, pending[invocationID] != nil, pending[invocationID]?.retry == nil {
            if let context = try await verifySubmission(invocationID) {
                await onVerified(context)
            }
        }
        guard !stopped, pending[invocationID] == nil else {
            throw AgentWorkflowError("The Agent's current turn is awaiting receipt verification. Retry the completion command after verification.")
        }
    }

    func receive(_ event: PluginEvent, peer: PluginIngressPeer) async throws -> AgentWorkflowTurnContext? {
        guard !stopped else { return nil }
        if case .awaitingReplies = event.state {
            try await store.recordQuestion(event, peer: peer)
        } else if event.notification?.isQuestion == true {
            try await store.recordQuestion(event, peer: peer)
        }
        guard let native = event.workflow else { return nil }
        let archive = try await store.snapshot()
        guard
            !stopped,
            let process = archive.instances.first(where: {
                $0.pluginID == event.pluginID && $0.paneID == event.tmuxPane
                    && peer.contains(processID: $0.processID, runtimeID: $0.processRuntimeID)
            }) else { return nil }
        var observed = process
        observed.conversationID = event.sessionID
        if
            native.kind != .submitted,
            let id = pending.first(where: {
                $0.value.context.instance.matchesBinding(observed)
                    && $0.value.context.candidate.nativeTurnID == native.nativeTurnID
                    && $0.value.context.candidate.transcriptPath == native.transcriptPath
            })?.key {
            if pending[id]?.following?.kind != .failed {
                pending[id]?.following = native
                pending[id]?.revision += 1
            }
            return nil
        }
        if
            let id = pending.first(where: { entry in
                guard
                    entry.value.context.instance.matchesBinding(observed),
                    entry.value.context.candidate.nativeTurnID != native.nativeTurnID,
                    let run = archive.runs.first(where: { $0.id == entry.value.context.runID }),
                    !run.status.isTerminal,
                    run.definition.nodes.first(where: { $0.id == entry.value.context.invocation.nodeID })?.completion == .explicit else { return false }
                return native.kind == .submitted || (
                    entry.value.continuation?.nativeTurnID == native.nativeTurnID
                        && entry.value.continuation?.transcriptPath == native.transcriptPath
                )
            })?.key {
            if native.kind == .submitted {
                pending[id]?.continuation = native
                pending[id]?.continuationFollowing = nil
                pending[id]?.revision += 1
            } else if pending[id]?.continuationFollowing?.kind != .failed {
                pending[id]?.continuationFollowing = native
                pending[id]?.revision += 1
            }
            return nil
        }

        guard native.kind == .submitted || process.matchesBinding(observed) else { return nil }
        // Submission identity is checked by verifySubmission, which retains
        // authenticated evidence through temporary process-scan outages.
        let instance = observed

        for run in archive.runs where (run.instances + run.invocations.compactMap { run.instance(for: $0) }).contains(where: {
            native.kind == .submitted ? $0.matchesProcess(instance) : $0.matchesBinding(instance)
        }) {
            let invocations = run.invocations.filter {
                guard let bound = run.instance(for: $0) else { return false }
                return native.kind == .submitted ? bound.matchesProcess(instance) : bound.matchesBinding(instance)
            }
            switch native.kind {
            case .submitted:
                if
                    let invocation = invocations.first(where: {
                        $0.submissionText(pluginID: instance.pluginID) == native.text
                            && ($0.nativeTurnID == nil || $0.nativeTurnID == native.nativeTurnID)
                            && [.writing, .awaitingAcceptance, .uncertain, .running, .succeeded, .failed].contains($0.status)
                    }) {
                    // A failed attempt is immutable; its duplicate receipt must not interrupt a retry.
                    guard invocation.status != .failed, pending[invocation.id] == nil else { return nil }
                    let bindsConversation = run.instance(for: invocation)?.matchesBinding(instance) != true
                    if bindsConversation, try !AgentWorkflowExecution(validating: run).canBindFirstConversation(instance, invocationID: invocation.id) {
                        if !run.status.isTerminal {
                            try await store.update(runID: run.id) { $0.pause(reason: "The Agent's conversation changed after its first accepted task. Start a new run.") }
                        }
                        continue
                    }
                    let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                    pending[invocation.id] = .init(context: context, bindFirstConversation: bindsConversation)
                    do { return try await verifySubmission(invocation.id) }
                    catch {
                        pending[invocation.id]?.retry?.cancel()
                        pending[invocation.id]?.retry = nil
                        throw error
                    }
                }
                if
                    !run.status.isTerminal,
                    let invocation = invocations.first(where: {
                        $0.status == .running && $0.stepTurn?.completionRequested == false
                    }) {
                    guard pending[invocation.id] == nil else { return nil }
                    let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                    pending[invocation.id] = .init(context: context, bindFirstConversation: false, isStepContinuation: true)
                    do { return try await verifySubmission(invocation.id) }
                    catch {
                        pending[invocation.id]?.retry?.cancel()
                        pending[invocation.id]?.retry = nil
                        throw error
                    }
                }
                // Human input may supplement this turn or start another one.
                // It neither pauses the run nor replaces the task's receipt.
                continue
            case .failed,
                 .stopCandidate:
                guard
                    let invocation = invocations.first(where: {
                        $0.resultTurnID == native.nativeTurnID && $0.resultTranscriptPath == native.transcriptPath
                            && [.running, .uncertain].contains($0.status)
                    }) else { continue }
                let live = native.kind == .failed ? try await inspect(instance) : instance
                guard instance.matchesBinding(live) else { return nil }
                return try await routeFollowing(.init(runID: run.id, invocation: invocation, instance: live, candidate: native))
            }
        }
        return nil
    }

    private func verifySubmission(_ id: UUID) async throws -> AgentWorkflowTurnContext? {
        guard let submission = pending[id], !submission.verifying else { return nil }
        pending[id]?.verifying = true
        defer { pending[id]?.verifying = false }
        let candidate = submission.context
        let live: AgentWorkflowInstance
        do { live = try await inspect(candidate.instance) }
        catch is AgentWorkflowInspectionUnavailable {
            if !submission.bindFirstConversation {
                try await store.update(runID: candidate.runID) {
                    $0.pause(reason: "The Agent cannot currently be inspected. Its submission receipt is awaiting verification; nothing will be resent.")
                }
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
        if let issue = live.capabilityIssue {
            throw AgentWorkflowError(issue)
        }
        if submission.isStepContinuation {
            try await store.update(runID: candidate.runID) {
                try $0.observeStepTurn(invocationID: id, instance: live, turn: .init(
                    id: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath, prompt: candidate.candidate.text
                ))
            }
        } else {
            try await runner.accepted(
                runID: candidate.runID, invocationID: id, instance: live,
                nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath,
                bindFirstConversation: submission.bindFirstConversation
            )
        }
        while let resolved = pending[id] {
            if let continuation = resolved.continuation {
                try await store.update(runID: candidate.runID) {
                    try $0.observeStepTurn(invocationID: id, instance: live, turn: .init(
                        id: continuation.nativeTurnID, transcriptPath: continuation.transcriptPath, prompt: continuation.text
                    ))
                }
            }
            let following = resolved.continuation == nil ? resolved.following : resolved.continuationFollowing
            var context: AgentWorkflowTurnContext?
            if let following {
                context = try await routeFollowing(.init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: following))
            } else if !submission.isStepContinuation, resolved.continuation == nil, candidate.invocation.nativeTurnID == nil {
                let current = try await store.snapshot().runs.first(where: { $0.id == candidate.runID })?.invocations.first(where: { $0.id == id })
                if current?.stepTurn == nil {
                    context = .init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: candidate.candidate)
                }
            }
            // Keep completion blocked until every event received during the
            // asynchronous writes above has also been applied.
            guard pending[id]?.revision == resolved.revision else { continue }
            pending.removeValue(forKey: id)
            return context
        }
        return nil
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
            guard let unresolved = pending[id], !Task.isCancelled else { return }
            pending[id]?.retry = nil
            onFailure("Could not verify a workflow submission receipt: \(error.localizedDescription)")
            do { try await store.update(runID: unresolved.context.runID) { $0.pause(reason: error.localizedDescription) } }
            catch { onFailure("Could not pause the workflow: \(error.localizedDescription)") }
        }
    }

    private func routeFollowing(_ context: AgentWorkflowTurnContext) async throws -> AgentWorkflowTurnContext? {
        let run = try await store.snapshot().runs.first(where: { $0.id == context.runID })
        guard var invocation = run?.invocations.first(where: { $0.id == context.invocation.id }) else { return nil }
        if let turn = invocation.stepTurn {
            guard turn.id == context.candidate.nativeTurnID, turn.transcriptPath == context.candidate.transcriptPath else { return nil }
            if !context.candidate.hasPendingWork {
                let id = invocation.id
                let updated = try await store.update(runID: context.runID) { try $0.stopStepTurn(invocationID: id, turnID: turn.id) }
                guard let current = updated.invocations.first(where: { $0.id == id }), current.stepTurn?.id == turn.id else { return nil }
                invocation = current
            }
            guard invocation.stepTurn?.completionRequested == true else { return nil }
        }
        if context.candidate.kind == .failed {
            try await runner.failed(
                runID: context.runID, invocationID: context.invocation.id, instance: context.instance,
                nativeTurnID: context.candidate.nativeTurnID, reason: context.candidate.text
            )
            return nil
        }
        return .init(runID: context.runID, invocation: invocation, instance: context.instance, candidate: context.candidate)
    }
}
