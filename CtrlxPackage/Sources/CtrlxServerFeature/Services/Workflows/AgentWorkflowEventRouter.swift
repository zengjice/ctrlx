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
    private let catalog: AgentRuntimeCatalog?
    private struct PendingContinuation {
        let event: PluginEvent
        let peer: PluginIngressPeer
        let native: PluginWorkflowEvent
        // Nil means the writer still needs conversation verification.
        var requiresOrderCheck: Bool?
        var following: [(event: PluginWorkflowEvent, peer: PluginIngressPeer)] = []

        func owns(_ instance: AgentWorkflowInstance) -> Bool {
            AgentReplyEvidence.owns(event, instance: instance, peer: peer)
        }

        func hookStart(for writer: AgentWorkflowInstance) -> Date? {
            guard let source = peer.processes.first, source.processID != writer.processID else { return nil }
            return Date(timeIntervalSince1970: Double(source.startSeconds) + Double(source.startMicroseconds) / 1_000_000)
        }

        func rejectionWindow(among receipts: [Self], writer: AgentWorkflowInstance) -> Range<Date>? {
            guard let start = hookStart(for: writer) else { return nil }
            var end = Date.distantFuture
            for other in receipts where other.native.nativeTurnID != native.nativeTurnID
                && other.event.sessionID == event.sessionID
                && other.native.transcriptPath == native.transcriptPath && other.native.text == native.text {
                guard let otherStart = other.hookStart(for: writer), otherStart != start else { return nil }
                if otherStart > start {
                    end = min(end, otherStart)
                }
            }
            return start < end ? start..<end : nil
        }

        func completion(from instance: AgentWorkflowInstance) -> PluginWorkflowEvent? {
            let matches = following.reversed().compactMap {
                $0.peer.contains(processID: instance.processID, runtimeID: instance.processRuntimeID) ? $0.event : nil
            }
            return matches.first { $0.kind == .failed } ?? matches.first
        }

        func couldResume(_ instance: AgentWorkflowInstance) -> Bool {
            owns(instance) || (event.tmuxPane == instance.paneID
                && event.pluginID == instance.pluginID && event.sessionID == instance.conversationID)
        }
    }

    private struct PendingSubmission {
        let generation = UUID()
        let context: AgentWorkflowTurnContext
        let bindFirstConversation: Bool
        var isStepContinuation = false
        var requiresOrderCheck = false
        var continuationOnly = false
        var verifying = false
        var revision = 0
        var following: PluginWorkflowEvent?
        var continuations: [PendingContinuation] = []
        var retry: Task<Void, Never>?
    }

    private var stopped = false
    private var pending: [UUID: PendingSubmission] = [:]
    private let verificationTimeout: Duration
    private let onVerified: @Sendable (AgentWorkflowTurnContext) async -> Void
    private let onFailure: @Sendable (String) -> Void
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let recheckConversation: @Sendable (PluginEvent, PluginIngressPeer, Bool) async -> AgentWorkflowStore.SubmissionDisposition
    private let provider: @Sendable (String) async -> (any AgentWorkflowProviding)?

    init(
        store: AgentWorkflowStore, runner: AgentWorkflowRunner, catalog: AgentRuntimeCatalog? = nil,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        recheckConversation: @escaping @Sendable (PluginEvent, PluginIngressPeer, Bool) async -> AgentWorkflowStore.SubmissionDisposition = { _, _, _ in .superseded },
        provider: @escaping @Sendable (String) async -> (any AgentWorkflowProviding)? = { _ in nil },
        onVerified: @escaping @Sendable (AgentWorkflowTurnContext) async -> Void = { _ in },
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.runner = runner
        self.catalog = catalog
        self.inspect = inspect
        self.recheckConversation = recheckConversation
        self.verificationTimeout = verificationTimeout
        self.provider = provider
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
        if !stopped, let submission = pending[invocationID], submission.retry == nil {
            if let context = try await verifySubmission(invocationID, generation: submission.generation) {
                await onVerified(context)
            }
        }
        guard !stopped, try await !blocksCompletion(invocationID) else {
            throw AgentWorkflowError("The Agent's current turn is awaiting receipt verification. Retry the completion command after verification.")
        }
    }

    private func blocksCompletion(_ id: UUID) async throws -> Bool {
        guard let submission = pending[id] else { return false }
        guard submission.continuationOnly else { return true }
        let instances = try await store.snapshot().instances
        guard let current = pending[id] else { return false }
        return !current.continuationOnly || current.continuations.contains { receipt in
            receipt.owns(current.context.instance) || instances.contains {
                $0.agentID == current.context.instance.agentID && receipt.owns($0)
            }
        }
    }

    func suppressesAgentCompletion(_ event: PluginEvent, peer: PluginIngressPeer) async throws -> Bool {
        guard !stopped, let turn = event.completionTurn else { return false }
        let receipts = pending.values
        let archive = try await store.snapshot()
        let current = archive.instances.first { AgentReplyEvidence.owns(event, instance: $0, peer: peer) }
        func matchesAgent(_ bound: AgentWorkflowInstance) -> Bool {
            guard bound.conversationID == event.sessionID else { return false }
            return AgentReplyEvidence.owns(event, instance: bound, peer: peer)
                || current.map { bound.agentID == $0.agentID && bound.pluginID == $0.pluginID } == true
        }
        func matchesTurn(id: String?, path: String?) -> Bool {
            turn.nativeTurnID == id && turn.transcriptPath == path
        }

        // A Stop may arrive while the receipt or a continuation is still being verified.
        if
            let receipt = receipts.first(where: { submission in
                let bound = submission.context.instance
                let currentWriter = current.flatMap {
                    $0.agentID == bound.agentID && $0.pluginID == bound.pluginID && $0.workspacePane.isSamePane(as: bound.workspacePane) ? $0 : nil
                }
                let savedWriter = AgentReplyEvidence.owns(event, instance: bound, peer: peer) ? bound : nil
                if
                    submission.continuations.contains(where: { receipt in
                        receipt.event.sessionID == event.sessionID && matchesTurn(id: receipt.native.nativeTurnID, path: receipt.native.transcriptPath)
                            && (savedWriter.map(receipt.owns) == true || currentWriter.map(receipt.owns) == true)
                    }) {
                    return true
                }
                return !submission.continuationOnly && matchesAgent(bound)
                    && matchesTurn(id: submission.context.candidate.nativeTurnID, path: submission.context.candidate.transcriptPath)
            }), let run = archive.runs.first(where: { $0.id == receipt.context.runID }) {
            return run.definition.notifyOnAgentCompletion != true
        }

        let run = archive.runs.reversed().first { run in
            run.invocations.contains { invocation in
                matchesTurn(id: invocation.resultTurnID, path: invocation.resultTranscriptPath)
                    && run.instance(for: invocation).map(matchesAgent) == true
            }
        }
        return run.map { $0.definition.notifyOnAgentCompletion != true } ?? false
    }

    private func isSupersededSubmission(
        _ turn: PluginWorkflowTurn, prompt: String, instance: AgentWorkflowInstance, requiringReceipt: Bool = false,
        submissionRejectionWindow: Range<Date>? = nil
    ) async throws -> Bool? {
        guard let provider = await provider(instance.pluginID) else { return nil }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let parser = provider.workflowTranscript(
                conversationID: instance.conversationID, nativeTurnID: turn.nativeTurnID, prompt: prompt, candidate: ""
            )
            do {
                let transcript = try AgentWorkflowTranscriptFile(
                    path: turn.transcriptPath, parser: parser, submissionRejectionWindow: submissionRejectionWindow
                )
                if let superseded = try await transcript.hasNewerSubmission(than: turn, requiringReceipt: requiringReceipt) {
                    return superseded
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile && attempt == 0 && !requiringReceipt {
                // The native hook can precede creation of a new transcript.
                return false
            } catch {
                try Task.checkCancellation()
            }
        }
        return nil
    }

    private func observeSubmission(
        _ event: PluginWorkflowEvent, instance: AgentWorkflowInstance,
        pendingRevision: (id: UUID, generation: UUID, revision: Int)? = nil, requiringReceipt: Bool = false
    ) async throws -> AgentWorkflowStore.SubmissionDisposition {
        try await store.observeSubmission(event, instance: instance) { turn in
            let superseded = try await self.isSupersededSubmission(turn, prompt: event.text, instance: instance, requiringReceipt: requiringReceipt)
            if let pendingRevision, await !self.matchesPendingRevision(pendingRevision) {
                return nil
            }
            return superseded
        }
    }

    private func matchesPendingRevision(_ expected: (id: UUID, generation: UUID, revision: Int)) -> Bool {
        pending[expected.id]?.generation == expected.generation && pending[expected.id]?.revision == expected.revision
    }

    /// A receipt arriving before the pane can be checked is only a candidate.
    func receiveUnconfirmedSubmission(_ event: PluginEvent, peer: PluginIngressPeer) async throws {
        guard !stopped, let native = event.workflow, native.kind == .submitted, !event.sessionID.isEmpty else { return }
        let archive = try await store.snapshot()
        let receipt = PendingContinuation(event: event, peer: peer, native: native)
        for run in archive.runs where !run.status.isTerminal {
            for invocation in run.invocations where invocation.round == run.round {
                guard !stopped else { return }
                if let submission = pending[invocation.id] {
                    guard
                        submission.continuationOnly || native.nativeTurnID != submission.context.candidate.nativeTurnID,
                        native.nativeTurnID != invocation.resultTurnID,
                        invocation.stepTurn?.completionRequested != true,
                        run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit,
                        submission.continuationOnly ? receipt.couldResume(submission.context.instance)
                        : event.sessionID == submission.context.instance.conversationID && receipt.owns(submission.context.instance) else { continue }
                    try await enqueuePendingContinuation(receipt, run: run, invocation: invocation, bound: submission.context.instance)
                    return
                }
                let bound: AgentWorkflowInstance?
                let isContinuation: Bool
                let isManualContinuation: Bool
                if
                    invocation.status == .running, let turn = invocation.stepTurn,
                    !turn.completionRequested, native.nativeTurnID != turn.id,
                    let node = run.definition.nodes.first(where: { $0.id == invocation.nodeID }), node.completion == .explicit {
                    let prompt = AgentWorkflowPrompt.continuation(definition: run.definition, nodeID: node.id, invocationID: invocation.id)
                    isManualContinuation = invocation.continuationTurnID != turn.id || native.text != prompt
                    let participant = run.definition.instance(for: node.agentInstanceID, in: run.instances)
                    bound = isManualContinuation ? run.instance(for: invocation) : invocation.continuationInstance ?? participant
                    isContinuation = true
                } else {
                    guard
                        invocation.nativeTurnID == nil, [.writing, .awaitingAcceptance, .uncertain].contains(invocation.status),
                        AgentReplyEvidence.submission(native, prompt: invocation.submissionText(pluginID: event.pluginID), acceptedTurnID: nil) else { continue }
                    bound = run.instance(for: invocation)
                    isContinuation = false
                    isManualContinuation = false
                }
                guard var instance = bound else { continue }
                if isManualContinuation {
                    guard receipt.couldResume(instance) else { continue }
                    try await enqueuePendingContinuation(receipt, run: run, invocation: invocation, bound: instance)
                    return
                }
                guard AgentReplyEvidence.owns(event, instance: instance, peer: peer) else { continue }
                let bindsConversation = !isContinuation && instance.conversationID != event.sessionID
                instance.conversationID = event.sessionID
                if bindsConversation, try !AgentWorkflowExecution(validating: run).canBindFirstConversation(instance, invocationID: invocation.id) {
                    continue
                }
                try await catalog?.recordBridge(event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
                guard !stopped, pending[invocation.id] == nil else { return }
                let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                _ = try await beginVerification(.init(
                    context: context, bindFirstConversation: bindsConversation, isStepContinuation: isContinuation, requiresOrderCheck: true
                ))
                return
            }
        }
    }

    private func enqueuePendingContinuation(
        _ receipt: PendingContinuation, run: AgentWorkflowRun, invocation: AgentWorkflowInvocation, bound: AgentWorkflowInstance
    ) async throws {
        guard await recheckConversation(receipt.event, receipt.peer, false) != .superseded, !stopped else { return }
        let id = invocation.id
        if pending[id] == nil {
            let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: bound, candidate: receipt.native)
            _ = try await beginVerification(.init(
                context: context, bindFirstConversation: false, isStepContinuation: true, requiresOrderCheck: true,
                continuationOnly: true, continuations: [receipt]
            ))
        } else {
            appendContinuation(receipt, to: id)
        }
    }

    private func appendContinuation(_ receipt: PendingContinuation, to id: UUID) {
        guard
            pending[id]?.continuations.contains(where: {
                $0.native == receipt.native && $0.event.sessionID == receipt.event.sessionID && $0.peer == receipt.peer
            }) == false else { return }
        pending[id]?.continuations.append(receipt)
        pending[id]?.revision += 1
        scheduleSubmissionRetry(id)
    }

    func bufferPendingCompletion(_ event: PluginEvent, peer: PluginIngressPeer) -> Bool {
        guard !stopped, let native = event.workflow, native.kind != .submitted else { return false }
        for (id, submission) in pending {
            let context = submission.context
            let related = submission.continuations.indices.filter { index in
                let receipt = submission.continuations[index]
                return event.sessionID == receipt.event.sessionID && event.tmuxPane == receipt.event.tmuxPane
                    && event.pluginID == receipt.event.pluginID
                    && AgentReplyEvidence.turn(native, id: receipt.native.nativeTurnID, path: receipt.native.transcriptPath)
            }
            if !related.isEmpty {
                for index in related where !submission.continuations[index].following.contains(where: { $0.event == native && $0.peer == peer }) {
                    pending[id]?.continuations[index].following.append((native, peer))
                    pending[id]?.revision += 1
                }
                return true
            }
            guard !submission.continuationOnly else { continue }
            guard event.sessionID == context.instance.conversationID, AgentReplyEvidence.owns(event, instance: context.instance, peer: peer) else { continue }
            if AgentReplyEvidence.turn(native, id: context.candidate.nativeTurnID, path: context.candidate.transcriptPath) {
                if submission.following?.kind != .failed {
                    pending[id]?.following = native
                    pending[id]?.revision += 1
                }
                return true
            }
        }
        return false
    }

    func receive(_ event: PluginEvent, peer: PluginIngressPeer) async throws -> AgentWorkflowTurnContext? {
        guard !stopped else { return nil }
        if case .awaitingReplies = event.state {
            try await store.recordQuestion(event, peer: peer)
        } else if event.notification?.isQuestion == true {
            try await store.recordQuestion(event, peer: peer)
        }
        guard !stopped, let native = event.workflow else { return nil }
        if bufferPendingCompletion(event, peer: peer) {
            return nil
        }
        let archive = try await store.snapshot()
        guard !stopped else { return nil }
        let process = archive.instances.first { AgentReplyEvidence.owns(event, instance: $0, peer: peer) }
        if native.kind != .submitted {
            for run in archive.runs {
                for invocation in run.invocations where [.running, .uncertain].contains(invocation.status) {
                    guard
                        AgentReplyEvidence.turn(native, id: invocation.resultTurnID, path: invocation.resultTranscriptPath),
                        let bound = run.instance(for: invocation), bound.conversationID == event.sessionID,
                        AgentReplyEvidence.owns(event, instance: bound, peer: peer) else { continue }
                    var instance = process ?? bound
                    instance.conversationID = event.sessionID
                    guard bound.matchesBinding(instance) else { continue }
                    // The accepted writer and turn are already authenticated in
                    // the ledger. Stop still needs native result verification.
                    let live = native.kind == .failed && process != nil ? try await inspect(instance) : instance
                    guard instance.matchesBinding(live) else { return nil }
                    return try await routeFollowing(.init(runID: run.id, invocation: invocation, instance: live, candidate: native))
                }
            }
            return nil
        }
        guard var observed = process else { return nil }
        observed.conversationID = event.sessionID
        if
            let id = pending.first(where: { entry in
                let bound = entry.value.context.instance
                return (bound.matchesBinding(observed) || (entry.value.continuationOnly && bound.matchesProcess(observed)))
                    && (entry.value.continuationOnly || entry.value.context.candidate.nativeTurnID != native.nativeTurnID)
                    && archive.runs.contains { run in
                        run.id == entry.value.context.runID && !run.status.isTerminal
                            && run.definition.nodes.first(where: { $0.id == entry.value.context.invocation.nodeID })?.completion == .explicit
                    }
            })?.key {
            let recorded = archive.runs.lazy.flatMap(\.invocations).first { $0.id == id }
            let repeatsRecordedTurn = recorded?.resultTurnID == native.nativeTurnID
            if repeatsRecordedTurn, pending[id]?.continuations.isEmpty == false {
                return nil
            }
            if pending[id]?.continuations.contains(where: { $0.requiresOrderCheck == nil }) == true {
                appendContinuation(.init(event: event, peer: peer, native: native, requiresOrderCheck: true), to: id)
                return nil
            }
            let disposition = try await observeSubmission(native, instance: observed)
            guard disposition != .superseded, !stopped, pending[id] != nil else { return nil }
            appendContinuation(.init(
                event: event, peer: peer, native: native, requiresOrderCheck: disposition == .deferred || repeatsRecordedTurn
            ), to: id)
            return nil
        }
        let disposition = try await observeSubmission(native, instance: observed)
        guard disposition != .superseded, !stopped else { return nil }
        let requiresOrderCheck = disposition == .deferred

        // The catalog can lag /new. verifySubmission checks the actual writer.
        let instance = observed

        for run in archive.runs where (run.instances + run.invocations.compactMap { run.instance(for: $0) }).contains(where: {
            $0.matchesProcess(instance) || ($0.agentID == instance.agentID && $0.pluginID == instance.pluginID)
        }) {
            let invocations = run.invocations.filter {
                guard let bound = run.instance(for: $0) else { return false }
                if !run.status.isTerminal, $0.status == .running, $0.stepTurn?.completionRequested == false {
                    return bound.matchesProcess(instance) || (bound.agentID == instance.agentID && bound.pluginID == instance.pluginID)
                }
                return bound.matchesProcess(instance) || ($0.nativeTurnID != nil && bound.matchesConversation(instance))
            }
            if
                let invocation = invocations.first(where: {
                    AgentReplyEvidence.submission(native, prompt: $0.submissionText(pluginID: instance.pluginID), acceptedTurnID: $0.nativeTurnID)
                        && [.writing, .awaitingAcceptance, .uncertain, .running, .succeeded, .failed].contains($0.status)
                }) {
                // A failed attempt is immutable; its duplicate receipt must not interrupt a retry.
                guard invocation.status != .failed, pending[invocation.id] == nil else { return nil }
                let bound = run.instance(for: invocation)
                let bindsConversation = bound?.matchesBinding(instance) != true && bound?.matchesConversation(instance) != true
                if bindsConversation, try !AgentWorkflowExecution(validating: run).canBindFirstConversation(instance, invocationID: invocation.id) {
                    if !run.status.isTerminal {
                        try await store.update(runID: run.id) { $0.pause(reason: "The Agent's conversation changed after its first accepted task. Start a new run.") }
                    }
                    continue
                }
                let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                return try await beginVerification(.init(
                    context: context, bindFirstConversation: bindsConversation, requiresOrderCheck: requiresOrderCheck
                ))
            }
            if
                !run.status.isTerminal,
                let invocation = invocations.first(where: {
                    $0.status == .running && $0.stepTurn?.completionRequested == false
                }) {
                if let previous = pending[invocation.id] {
                    let oldWriter = previous.context.instance
                    guard
                        instance.agentID == oldWriter.agentID, instance.pluginID == oldWriter.pluginID,
                        !instance.conversationID.isEmpty, !instance.matchesBinding(oldWriter),
                        native.nativeTurnID != invocation.resultTurnID else { return nil }
                }
                let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: native)
                return try await beginVerification(.init(
                    context: context, bindFirstConversation: false, isStepContinuation: true, requiresOrderCheck: requiresOrderCheck
                ))
            }
        }
        return nil
    }

    private func beginVerification(_ submission: PendingSubmission) async throws -> AgentWorkflowTurnContext? {
        let id = submission.context.invocation.id
        pending[id]?.retry?.cancel()
        pending[id] = submission
        if submission.requiresOrderCheck {
            scheduleSubmissionRetry(id)
            return nil
        }
        do { return try await verifySubmission(id, generation: submission.generation) }
        catch {
            guard pending[id]?.generation == submission.generation else { return nil }
            pending[id]?.retry?.cancel()
            pending[id]?.retry = nil
            throw error
        }
    }

    private func verifySubmission(_ id: UUID, generation: UUID) async throws -> AgentWorkflowTurnContext? {
        guard let submission = pending[id], submission.generation == generation, !submission.verifying else { return nil }
        pending[id]?.verifying = true
        defer {
            if pending[id]?.generation == generation {
                pending[id]?.verifying = false
            }
        }
        let candidate = submission.context
        var useInitialReceipt = !submission.continuationOnly
        let live: AgentWorkflowInstance
        do {
            let archive = try await store.snapshot()
            guard pending[id]?.generation == generation else { return nil }
            if
                submission.requiresOrderCheck,
                !archive.runs.contains(where: { $0.id == candidate.runID && !$0.status.isTerminal }) {
                pending.removeValue(forKey: id)
                return nil
            }
            if submission.continuationOnly {
                live = candidate.instance
            } else {
                if submission.isStepContinuation, !archive.instances.contains(where: { $0.matchesProcess(candidate.instance) }) {
                    throw AgentWorkflowInspectionUnavailable()
                }
                let current = archive.instances.first {
                    $0.matchesBinding(candidate.instance)
                }
                live = try await inspect(submission.isStepContinuation ? current ?? candidate.instance : candidate.instance)
            }
        } catch is AgentWorkflowInspectionUnavailable {
            guard pending[id]?.generation == generation, !Task.isCancelled else { return nil }
            if !submission.bindFirstConversation {
                try await store.update(runID: candidate.runID) {
                    $0.waitForAgent(candidate.instance, reason: "Its submission receipt is awaiting verification; nothing will be resent.")
                }
            }
            if pending[id]?.generation == generation {
                scheduleSubmissionRetry(id)
            }
            return nil
        }
        try Task.checkCancellation()
        guard pending[id]?.generation == generation else { return nil }
        guard candidate.instance.matchesBinding(live) else {
            throw AgentWorkflowError("The Agent changed before its submission receipt could be verified.")
        }
        if !submission.continuationOnly, let issue = live.capabilityIssue {
            throw AgentWorkflowError(issue)
        }
        if useInitialReceipt, submission.requiresOrderCheck {
            guard let current = pending[id] else { return nil }
            if
                current.continuations.last?.requiresOrderCheck == false,
                current.continuations.allSatisfy({ $0.requiresOrderCheck != nil }) {
                useInitialReceipt = candidate.invocation.nativeTurnID == nil
            } else {
                let order = try await observeSubmission(
                    candidate.candidate, instance: live, pendingRevision: (id, generation, current.revision)
                )
                guard pending[id]?.generation == generation else { return nil }
                guard order != .deferred else {
                    scheduleSubmissionRetry(id)
                    return nil
                }
                useInitialReceipt = order == .ready
            }
        }
        if useInitialReceipt, submission.isStepContinuation {
            try await store.observeStepTurn(runID: candidate.runID, invocationID: id, instance: live, turn: .init(
                id: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath, prompt: candidate.candidate.text
            ))
        } else if useInitialReceipt {
            try await runner.accepted(
                runID: candidate.runID, invocationID: id, instance: live,
                nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath,
                bindFirstConversation: submission.bindFirstConversation
            )
        }
        while let resolved = pending[id], resolved.generation == generation {
            let revision = (id, generation, resolved.revision)
            var following = useInitialReceipt ? resolved.following : nil
            var writer = live
            let (receipt, isDeferred) = try await verifiedPendingContinuation(resolved, live: live, revision: revision)
            guard matchesPendingRevision(revision) else { continue }
            if let receipt {
                writer = receipt.instance
                try await store.observeStepTurn(runID: candidate.runID, invocationID: id, instance: writer, turn: .init(
                    id: receipt.event.nativeTurnID, transcriptPath: receipt.event.transcriptPath, prompt: receipt.event.text
                ))
                following = receipt.following
            } else if isDeferred {
                scheduleSubmissionRetry(id)
                return nil
            }
            var context: AgentWorkflowTurnContext?
            if let following {
                context = try await routeFollowing(.init(runID: candidate.runID, invocation: candidate.invocation, instance: writer, candidate: following))
            } else if useInitialReceipt, !submission.isStepContinuation, resolved.continuations.isEmpty, candidate.invocation.nativeTurnID == nil {
                let current = try await store.snapshot().runs.first(where: { $0.id == candidate.runID })?.invocations.first(where: { $0.id == id })
                if current?.stepTurn == nil {
                    context = .init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: candidate.candidate)
                }
            }
            // Keep completion blocked until every event received during the
            // asynchronous writes above has also been applied.
            guard matchesPendingRevision((id, generation, resolved.revision)) else { continue }
            pending.removeValue(forKey: id)
            return context
        }
        return nil
    }

    private func verifiedPendingContinuation(
        _ submission: PendingSubmission, live: AgentWorkflowInstance, revision: (id: UUID, generation: UUID, revision: Int)
    ) async throws -> (receipt: (instance: AgentWorkflowInstance, event: PluginWorkflowEvent, following: PluginWorkflowEvent?)?, isDeferred: Bool) {
        guard let last = submission.continuations.last else { return (nil, false) }
        if submission.continuations.allSatisfy({ $0.requiresOrderCheck != nil }) {
            let order = last.requiresOrderCheck == true
                ? try await observeSubmission(last.native, instance: live, pendingRevision: revision) : .ready
            return (order == .ready ? (live, last.native, last.completion(from: live)) : nil, order == .deferred)
        }
        let target = submission.context.instance
        guard
            let current = try await store.snapshot().instances.first(where: {
                $0.agentID == target.agentID && $0.pluginID == target.pluginID && $0.workspacePane.isSamePane(as: target.workspacePane)
            }) else { return (nil, true) }

        let owned = submission.continuations.reversed().filter { $0.owns(current) }
        guard !owned.isEmpty else { return (nil, true) }

        // A turn can be the latest on disk while a later receipt is still
        // waiting for its native turn to appear.
        var latest: [(PendingContinuation, AgentWorkflowInstance)] = []
        for receipt in owned {
            var writer = current
            writer.conversationID = receipt.event.sessionID
            let turn = PluginWorkflowTurn(nativeTurnID: receipt.native.nativeTurnID, transcriptPath: receipt.native.transcriptPath)
            // A Claude rejection has no prompt ID. Match it within this
            // submission's interval before the next hook for the same input.
            let older = try await isSupersededSubmission(
                turn, prompt: receipt.native.text, instance: writer, requiringReceipt: true,
                submissionRejectionWindow: receipt.rejectionWindow(among: owned, writer: writer)
            )
            guard matchesPendingRevision(revision) else { return (nil, false) }
            if let older {
                if !older {
                    latest.append((receipt, writer))
                }
            } else {
                let disposition = await recheckConversation(receipt.event, receipt.peer, false)
                guard matchesPendingRevision(revision) else { return (nil, false) }
                if disposition != .superseded {
                    return (nil, true)
                }
            }
        }

        var isDeferred = false
        for (receipt, instance) in latest {
            let disposition = receipt.requiresOrderCheck == nil
                ? await recheckConversation(receipt.event, receipt.peer, true) : .ready
            guard matchesPendingRevision(revision) else { return (nil, false) }
            guard disposition == .ready else {
                isDeferred = isDeferred || disposition == .deferred
                continue
            }
            try await catalog?.recordBridge(receipt.event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: receipt.peer)
            let live: AgentWorkflowInstance
            do { live = try await inspect(instance) }
            catch is AgentWorkflowInspectionUnavailable {
                isDeferred = true
                continue
            }
            guard matchesPendingRevision(revision) else { return (nil, false) }
            guard instance.matchesBinding(live) else {
                throw AgentWorkflowError("The Agent changed before its submission receipt could be verified.")
            }
            if let issue = live.capabilityIssue {
                throw AgentWorkflowError(issue)
            }
            let order = try await observeSubmission(receipt.native, instance: live, pendingRevision: revision, requiringReceipt: true)
            guard matchesPendingRevision(revision) else { return (nil, false) }
            if order == .ready {
                return ((live, receipt.native, receipt.completion(from: live)), false)
            }
            isDeferred = isDeferred || order == .deferred
        }
        return (nil, isDeferred)
    }

    private func scheduleSubmissionRetry(_ id: UUID) {
        guard let submission = pending[id], submission.retry == nil else { return }
        let generation = submission.generation
        pending[id]?.retry = Task { await self.retrySubmission(id, generation: generation) }
    }

    private func retrySubmission(_ id: UUID, generation: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: verificationTimeout)
        do {
            while pending[id]?.generation == generation {
                try await Task.sleep(for: .milliseconds(200))
                guard pending[id]?.generation == generation else { return }
                guard ContinuousClock.now < deadline else {
                    throw AgentWorkflowError("Submission receipt verification timed out. Check the Agent before continuing; the task will not be resent.")
                }
                if let context = try await verifySubmission(id, generation: generation) {
                    await onVerified(context)
                }
            }
        } catch {
            guard let unresolved = pending[id], unresolved.generation == generation, !Task.isCancelled else { return }
            if unresolved.continuationOnly, (try? await blocksCompletion(id)) == false {
                if pending[id]?.generation == generation, pending[id]?.revision == unresolved.revision {
                    pending.removeValue(forKey: id)
                    return
                }
            }
            guard pending[id]?.generation == generation, !Task.isCancelled else { return }
            pending[id]?.retry = nil
            onFailure("Could not verify a workflow submission receipt: \(error.localizedDescription)")
            do { try await store.update(runID: unresolved.context.runID) { $0.pause(reason: error.localizedDescription) } }
            catch { onFailure("Could not pause the workflow: \(error.localizedDescription)") }
        }
    }

    private func routeFollowing(_ context: AgentWorkflowTurnContext) async throws -> AgentWorkflowTurnContext? {
        let run = try await store.snapshot().runs.first(where: { $0.id == context.runID })
        guard
            let run, var invocation = run.invocations.first(where: { $0.id == context.invocation.id }),
            [.running, .uncertain].contains(invocation.status),
            AgentReplyEvidence.turn(context.candidate, id: invocation.resultTurnID, path: invocation.resultTranscriptPath),
            run.instance(for: invocation)?.matchesBinding(context.instance) == true else { return nil }
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
