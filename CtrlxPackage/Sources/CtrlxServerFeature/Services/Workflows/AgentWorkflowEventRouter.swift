import Clocks
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

struct AgentWorkflowTurnContext: Sendable {
    let runID: UUID
    let invocation: AgentWorkflowInvocation
    let instance: AgentWorkflowInstance
    let candidate: PluginWorkflowEvent
    var hookStartedAt: Date?
    var previousStop: AgentWorkflowTranscriptFile.StopBoundary?
}

private extension PluginIngressPeer {
    func workflowHookStart(for writer: AgentWorkflowInstance) -> Date? {
        // The socket peer is the per-event Hook process for shell bridges.
        guard
            let source = processes.first, source.processID != writer.processID,
            contains(processID: writer.processID, runtimeID: writer.processRuntimeID) else { return nil }
        return Date(timeIntervalSince1970: Double(source.startSeconds) + Double(source.startMicroseconds) / 1_000_000)
    }
}

/// Joins kernel-authenticated plugin evidence to the Host's durable invocation.
/// A native Stop only returns a candidate for the transcript monitor to verify.
actor AgentWorkflowEventRouter {
    private let store: AgentWorkflowStore
    private let runner: AgentWorkflowRunner
    private let catalog: AgentRuntimeCatalog?
    private struct HookCompletion: Equatable {
        let event: PluginWorkflowEvent
        let startedAt: Date?
    }

    private struct PendingContinuation {
        let event: PluginEvent
        let peer: PluginIngressPeer?
        let native: PluginWorkflowEvent
        // Nil means the writer still needs conversation verification.
        var requiresOrderCheck: Bool?
        var following: [HookCompletion] = []
        var saved: AgentWorkflowContinuationReceipt?

        func owns(_ instance: AgentWorkflowInstance) -> Bool {
            saved.map { $0.writer.matchesProcess(instance) } ?? peer.map { AgentReplyEvidence.owns(event, instance: instance, peer: $0) } ?? false
        }

        func startedAt(for writer: AgentWorkflowInstance) -> Date? {
            saved?.submittedAt ?? peer?.workflowHookStart(for: writer)
        }

        func rejectionWindow(among receipts: [Self], writer: AgentWorkflowInstance) -> Range<Date>? {
            guard let start = startedAt(for: writer) else { return nil }
            var end = Date.distantFuture
            for other in receipts where other.native.nativeTurnID != native.nativeTurnID
                && other.event.sessionID == event.sessionID
                && other.native.transcriptPath == native.transcriptPath && other.native.text == native.text {
                guard let otherStart = other.startedAt(for: writer), otherStart != start else { return nil }
                if otherStart > start {
                    end = min(end, otherStart)
                }
            }
            return start < end ? start..<end : nil
        }

        func completion(from instance: AgentWorkflowInstance) -> HookCompletion? {
            let submittedAt = startedAt(for: instance)
            let matches = following.filter {
                guard let start = $0.startedAt, let submittedAt else { return true }
                return start > submittedAt
            }
            return matches.first { $0.event.kind == .failed }
                ?? matches.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
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
        var confirmsSelectedResult = false
        var requiresOrderCheck = false
        var continuationOnly = false
        var verifying = false
        var revision = 0
        var following: HookCompletion?
        var continuations: [PendingContinuation] = []
        var retry: Task<Void, Never>?
    }

    private let submissionReaders = AgentWorkflowTranscriptReaders()
    private var stopped = false
    private var pending: [UUID: PendingSubmission] = [:]
    private let verificationTimeout: Duration
    private let clock: AnyClock<Duration>
    private let onVerified: @Sendable (AgentWorkflowTurnContext) async -> Void
    private let onFailure: @Sendable (String) -> Void
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let recheckConversation: @Sendable (PluginEvent, PluginIngressPeer, Bool) async -> AgentWorkflowStore.SubmissionDisposition
    private let provider: @Sendable (String) async -> (any AgentWorkflowProviding)?

    init(
        store: AgentWorkflowStore, runner: AgentWorkflowRunner, catalog: AgentRuntimeCatalog? = nil,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        clock: AnyClock<Duration> = AnyClock(ContinuousClock()),
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
        self.clock = clock
        self.provider = provider
        self.onVerified = onVerified
        self.onFailure = onFailure
    }

    func shutdown() async {
        stopped = true
        let tasks = pending.values.compactMap(\.retry)
        pending.removeAll()
        await submissionReaders.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    func requireVerifiedSubmission(_ invocationID: UUID, allowingStoppedReplay: Bool = false) async throws {
        let archive = try await store.snapshot()
        discardSettledSubmissions(using: archive)
        restoreContinuations(invocationID, from: archive)
        if !stopped, pending[invocationID] == nil, try await settleContinuationFailure(invocationID, in: archive) {
            return
        }
        // A timed-out receipt still supersedes the old turn. An explicit retry
        // may verify it, but must never fall back to completing that old turn.
        while !stopped, let submission = pending[invocationID], !submission.verifying {
            if let context = try await verifySubmission(invocationID, generation: submission.generation) {
                await onVerified(context)
            }
            if pending[invocationID]?.generation == submission.generation {
                break
            }
        }
        let remaining = try await store.snapshot().pendingReceipts?[invocationID]
        guard
            remaining?.continuationFailure == nil,
            remaining?.continuations?.contains(where: { $0.completion?.kind == .failed }) != true else {
            throw AgentWorkflowError("A continuation failure is awaiting verification.")
        }
        if
            !stopped, allowingStoppedReplay, let submission = pending[invocationID],
            try await isStoppedReplayCandidate(invocationID, submission: submission) {
            return
        }
        guard !stopped, try await !blocksCompletion(invocationID) else {
            throw AgentWorkflowError("The Agent's current turn is awaiting receipt verification. Retry the completion command after verification.")
        }
    }

    func discardRecoveredSubmissions(in run: AgentWorkflowRun) {
        discardSettledSubmissions(in: run)
        for (id, submission) in pending where submission.context.runID == run.id
            && Self.confirmedFirstReceipt(submission, in: run) {
            pending.removeValue(forKey: id)?.retry?.cancel()
            if !submission.continuations.isEmpty {
                pending[id] = .init(
                    context: submission.context, bindFirstConversation: false, isStepContinuation: true,
                    requiresOrderCheck: true, continuationOnly: true, continuations: submission.continuations
                )
                scheduleSubmissionRetry(id)
            }
        }
    }

    private func discardSettledSubmissions(in run: AgentWorkflowRun) {
        for (id, submission) in pending where submission.context.runID == run.id {
            if !Self.isUnsettled(id, in: run) {
                pending.removeValue(forKey: id)?.retry?.cancel()
            }
        }
    }

    private func discardSettledSubmissions(using archive: AgentWorkflowArchive) {
        for (id, submission) in pending where !archive.runs.contains(where: {
            $0.id == submission.context.runID && Self.isUnsettled(id, in: $0)
        }) {
            pending.removeValue(forKey: id)?.retry?.cancel()
        }
    }

    private static func isUnsettled(_ id: UUID, in run: AgentWorkflowRun) -> Bool {
        run.invocations.contains {
            $0.id == id && [.writing, .awaitingAcceptance, .uncertain, .running].contains($0.status)
        }
    }

    private static func confirmedFirstReceipt(_ submission: PendingSubmission, in run: AgentWorkflowRun) -> Bool {
        let context = submission.context
        return !submission.isStepContinuation && context.invocation.nativeTurnID == nil && run.invocations.contains {
            $0.id == context.invocation.id && $0.nativeTurnID == context.candidate.nativeTurnID && $0.stepTurn?.stopped == true
        }
    }

    private func blocksCompletion(_ id: UUID) async throws -> Bool {
        if try await store.snapshot().pendingReceipts?[id]?.continuations?.contains(where: { $0.isRetired != true }) == true {
            return true
        }
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
        let failure = event.workflow?.kind == .failed
        let turn = event.completionTurn ?? event.workflow.flatMap { $0.kind == .failed ? PluginWorkflowTurn(nativeTurnID: $0.nativeTurnID, transcriptPath: $0.transcriptPath) : nil }
        guard !stopped, let turn else { return false }
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
            return failure ? !run.status.isTerminal : run.definition.notifyOnAgentCompletion != true
        }

        let run = archive.runs.reversed().first { run in
            run.invocations.contains { invocation in
                matchesTurn(id: invocation.resultTurnID, path: invocation.resultTranscriptPath)
                    && run.instance(for: invocation).map(matchesAgent) == true
            }
        }
        return run.map { failure ? !$0.status.isTerminal : $0.definition.notifyOnAgentCompletion != true } ?? false
    }

    private func isSupersededSubmission(
        _ turn: PluginWorkflowTurn, prompt: String, instance: AgentWorkflowInstance, requiringReceipt: Bool = false,
        submissionRejectionWindow: Range<Date>? = nil, invocationID: UUID? = nil,
        hookStartedAt: Date? = nil, nativeStart: AgentWorkflowTranscriptFile.SubmissionBoundary? = nil
    ) async throws -> Bool? {
        guard let provider = await provider(instance.pluginID) else { return nil }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                let transcript = try await submissionReader(
                    turn, instance: instance, prompt: prompt, provider: provider,
                    rejectionWindow: submissionRejectionWindow, invocationID: invocationID
                )
                if
                    let superseded = try await transcript.file.hasNewerSubmission(
                        than: turn, requiringReceipt: requiringReceipt, hookStartedAt: hookStartedAt, nativeStart: nativeStart
                    ) {
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
        hookStartedAt: Date? = nil,
        pendingRevision: (id: UUID, generation: UUID, revision: Int)? = nil
    ) async throws -> AgentWorkflowStore.SubmissionDisposition {
        let archive = try await store.snapshot()
        let invocationID = pendingRevision?.id ?? archive.runs.lazy.filter { !$0.status.isTerminal }.compactMap { run in
            run.invocations.last {
                $0.round == run.round && [.writing, .awaitingAcceptance, .uncertain, .running].contains($0.status)
                    && run.instance(for: $0)?.agentID == instance.agentID && run.instance(for: $0)?.pluginID == instance.pluginID
            }?.id
        }.first
        return try await store.observeSubmission(event, instance: instance) { turn, requiresNativeReceipt in
            let superseded = try await self.isSupersededSubmission(
                turn, prompt: event.text, instance: instance, requiringReceipt: requiresNativeReceipt,
                invocationID: invocationID, hookStartedAt: hookStartedAt
            )
            if let pendingRevision, await !self.matchesPendingRevision(pendingRevision) {
                return nil
            }
            return superseded
        }
    }

    private func matchesPendingRevision(_ expected: (id: UUID, generation: UUID, revision: Int)) -> Bool {
        pending[expected.id]?.generation == expected.generation && pending[expected.id]?.revision == expected.revision
    }

    private func matchingDelivery(
        _ event: PluginWorkflowEvent, in archive: AgentWorkflowArchive, pluginID: String,
        matchesWriter: (AgentWorkflowRun, AgentWorkflowInvocation, AgentWorkflowInstance) -> Bool
    ) -> (AgentWorkflowRun, AgentWorkflowInvocation, AgentWorkflowInstance)? {
        for run in archive.runs {
            for invocation in run.invocations where AgentReplyEvidence.submission(
                event, prompt: invocation.submissionText(pluginID: pluginID), acceptedTurnID: nil
            ) {
                if let writer = run.instance(for: invocation), matchesWriter(run, invocation, writer) {
                    return (run, invocation, writer)
                }
            }
        }
        return nil
    }

    private func handleHistoricalSubmission(
        _ event: PluginEvent, native: PluginWorkflowEvent, peer: PluginIngressPeer, archive: AgentWorkflowArchive
    ) async throws -> Bool {
        let current = archive.instances.first {
            $0.conversationID == event.sessionID && AgentReplyEvidence.owns(event, instance: $0, peer: peer)
        }
        for run in archive.runs {
            for invocation in run.invocations {
                guard
                    run.status.isTerminal || invocation.round != run.round || [.succeeded, .failed].contains(invocation.status),
                    let writer = run.instance(for: invocation), writer.conversationID == event.sessionID,
                    AgentReplyEvidence.owns(event, instance: writer, peer: peer)
                    || current.map({ writer.matchesConversation($0) }) == true else { continue }
                let isResult = AgentReplyEvidence.turn(native, id: invocation.resultTurnID, path: invocation.resultTranscriptPath)
                guard isResult || AgentReplyEvidence.turn(native, id: invocation.nativeTurnID, path: invocation.nativeTranscriptPath) else { continue }
                if
                    isResult, run.status.isTerminal, [.running, .uncertain].contains(invocation.status),
                    AgentReplyEvidence.owns(event, instance: writer, peer: peer),
                    let completion = archive.pendingReceipts?[invocation.id]?.completion(for: .init(
                        nativeTurnID: native.nativeTurnID, transcriptPath: native.transcriptPath
                    )), !completion.hasPendingWork {
                    if
                        let context = try await routeFollowing(.init(
                            runID: run.id, invocation: invocation, instance: writer, candidate: completion,
                            hookStartedAt: archive.pendingReceipts?[invocation.id]?.completionHookStartedAt
                        )) {
                        await onVerified(context)
                    }
                }
                return true
            }
        }
        return false
    }

    private func continuesDelivery(
        _ native: PluginWorkflowEvent, invocation: AgentWorkflowInvocation, in run: AgentWorkflowRun,
        hookStartedAt: Date?, receipt: AgentWorkflowPendingReceipt?
    ) -> Bool {
        guard
            !run.status.isTerminal, invocation.round == run.round, invocation.status == .running,
            let accepted = invocation.nativeTurnID, let turn = invocation.stepTurn, !turn.completionRequested else { return false }
        if accepted != native.nativeTurnID {
            return true
        }
        if invocation.continuationTurnID == turn.id, invocation.continuationInstance != nil {
            return true
        }
        guard
            turn.stopped, let stoppedAt = receipt?.completionHookStartedAt,
            let hookStartedAt else { return false }
        return hookStartedAt > stoppedAt
    }

    private func selectedResultReplay(
        _ native: PluginWorkflowEvent, instance: AgentWorkflowInstance, in archive: AgentWorkflowArchive
    ) -> PendingSubmission? {
        for run in archive.runs where !run.status.isTerminal {
            for invocation in run.invocations where invocation.round == run.round && [.running, .uncertain].contains(invocation.status) {
                guard
                    let turn = invocation.stepTurn, turn.id != invocation.nativeTurnID,
                    native.transcriptPath == turn.transcriptPath,
                    AgentReplyEvidence.submission(native, prompt: turn.prompt, acceptedTurnID: turn.id),
                    let bound = run.instance(for: invocation), bound.matchesConversation(instance),
                    !bound.matchesBinding(instance) || invocation.status == .uncertain || turn.completionRequested else { continue }
                let context = AgentWorkflowTurnContext(
                    runID: run.id,
                    invocation: invocation,
                    instance: instance,
                    candidate: native
                )
                return .init(context: context, bindFirstConversation: false, confirmsSelectedResult: true)
            }
        }
        return nil
    }

    private func recordStepTurn(
        _ native: PluginWorkflowEvent, runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance,
        hookStartedAt: Date?, following: HookCompletion?, verifiedSubmission: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil
    ) async throws -> Bool {
        let archive = try await store.snapshot()
        let call = archive.runs.first(where: { $0.id == runID })?.invocations.first(where: { $0.id == invocationID })
        let saved = archive.pendingReceipts?[invocationID]
        if
            let verifiedSubmission, let selected = saved?.selectedSubmission,
            selected.nativeStart != nil, selected.nativeStart == verifiedSubmission.nativeStart,
            selected.identifies(.init(writer: instance, submission: native, submittedAt: hookStartedAt)) {
            return call?.stepTurn?.stopped != true
        }
        var reopening: AgentWorkflowTranscriptFile.VerifiedSubmission?
        if
            let call, let current = call.stepTurn, current.id == native.nativeTurnID,
            current.stopped || (call.continuationTurnID == current.id && call.continuationInstance != nil),
            archive.pendingFailure(for: call) == nil {
            guard current.transcriptPath == native.transcriptPath else {
                throw AgentWorkflowError("The native turn changed its transcript path.")
            }
            if let resumedAt = saved?.resumedHookStartedAt, let hookStartedAt, hookStartedAt <= resumedAt {
                return true
            }
            guard let provider = await provider(instance.pluginID) else { return false }
            let turn = PluginWorkflowTurn(nativeTurnID: native.nativeTurnID, transcriptPath: native.transcriptPath)
            let prior = saved?.continuationCompletions?.filter {
                $0.writer.matchesBinding(instance) && $0.event.kind == .stopCandidate && !$0.event.hasPendingWork
                    && AgentReplyEvidence.turn($0.event, id: turn.nativeTurnID, path: turn.transcriptPath)
                    && $0.startedAt != nil
            }
            let preceding = prior?.filter { ($0.startedAt ?? .distantFuture) < (hookStartedAt ?? .distantPast) }
                .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            if preceding == nil, let stoppedAt = saved?.completionHookStartedAt, let hookStartedAt, hookStartedAt <= stoppedAt {
                return true
            }
            let stop = preceding?.event ?? saved?.completion(for: turn).flatMap { $0.kind == .stopCandidate && !$0.hasPendingWork ? $0 : nil }
            let parser = provider.workflowTranscript(
                conversationID: instance.conversationID, nativeTurnID: turn.nativeTurnID, prompt: current.prompt, candidate: stop?.text ?? ""
            )
            let resumedStop: PluginWorkflowEvent? = if let hookStartedAt, let following, let stoppedAt = following.startedAt, stoppedAt > hookStartedAt {
                following.event
            } else {
                nil
            }
            do {
                let file = try AgentWorkflowTranscriptFile(path: turn.transcriptPath, parser: parser)
                reopening = try await file.verifyResumedSubmission(turn, after: saved?.stopBoundary, matching: stop, resumedStop: resumedStop)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return false
            }
            guard reopening != nil else { return false }
        }
        return try await store.observeStepTurn(
            runID: runID, invocationID: invocationID, instance: instance,
            turn: .init(id: native.nativeTurnID, transcriptPath: native.transcriptPath, prompt: native.text),
            reopening: reopening, expectedReceipt: saved, hookStartedAt: hookStartedAt, verifiedSubmission: verifiedSubmission
        )
    }

    /// A receipt arriving before the pane can be checked is only a candidate.
    func receiveUnconfirmedSubmission(_ event: PluginEvent, peer: PluginIngressPeer) async throws {
        guard !stopped, let native = event.workflow, native.kind == .submitted, !event.sessionID.isEmpty else { return }
        let archive = try await store.snapshot()
        discardSettledSubmissions(using: archive)
        for id in archive.pendingReceipts?.keys ?? [UUID: AgentWorkflowPendingReceipt]().keys {
            restoreContinuations(id, from: archive)
        }
        guard try await !handleHistoricalSubmission(event, native: native, peer: peer, archive: archive) else { return }
        if retryMatchingSubmission(event, native: native, peer: peer) {
            return
        }
        if
            let instance = archive.instances.first(where: {
                $0.conversationID == event.sessionID && AgentReplyEvidence.owns(event, instance: $0, peer: peer)
            }), let submission = selectedResultReplay(native, instance: instance, in: archive) {
            if pending[submission.context.invocation.id] == nil, let context = try await beginVerification(submission) {
                await onVerified(context)
            }
            return
        }
        let delivery = matchingDelivery(native, in: archive, pluginID: event.pluginID) { _, _, writer in
            AgentReplyEvidence.owns(event, instance: writer, peer: peer)
        }
        if
            let (run, invocation, bound) = delivery, !continuesDelivery(
                native, invocation: invocation, in: run, hookStartedAt: peer.workflowHookStart(for: bound), receipt: archive.pendingReceipts?[invocation.id]
            ) {
            guard
                invocation.round == run.round, pending[invocation.id] == nil,
                [.writing, .awaitingAcceptance, .uncertain, .running].contains(invocation.status) else { return }
            if invocation.nativeTurnID != nil {
                guard
                    bound.conversationID == event.sessionID,
                    AgentReplyEvidence.turn(native, id: invocation.nativeTurnID, path: invocation.nativeTranscriptPath) else { return }
                let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: bound, candidate: native)
                if let verified = try await beginVerification(.init(context: context, bindFirstConversation: false)) {
                    await onVerified(verified)
                }
                return
            }
            var instance = bound
            instance.conversationID = event.sessionID
            let bindsConversation = !bound.matchesBinding(instance)
            if bindsConversation, try !AgentWorkflowExecution(validating: run).canBindFirstConversation(instance, invocationID: invocation.id) {
                return
            }
            try await catalog?.recordBridge(event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
            guard !stopped, pending[invocation.id] == nil else { return }
            let context = AgentWorkflowTurnContext(
                runID: run.id,
                invocation: invocation,
                instance: instance,
                candidate: native,
                hookStartedAt: peer.workflowHookStart(for: instance)
            )
            _ = try await beginVerification(.init(context: context, bindFirstConversation: bindsConversation, requiresOrderCheck: true))
            return
        }
        let receipt = PendingContinuation(event: event, peer: peer, native: native)
        for run in archive.runs where !run.status.isTerminal {
            for invocation in run.invocations where invocation.round == run.round {
                guard !stopped else { return }
                guard delivery == nil || delivery?.1.id == invocation.id else { continue }
                if let submission = pending[invocation.id] {
                    guard
                        submission.isStepContinuation || native.nativeTurnID != submission.context.candidate.nativeTurnID
                        || invocation.stepTurn?.stopped == true,
                        native.nativeTurnID != invocation.resultTurnID || invocation.stepTurn?.stopped == true || submission.isStepContinuation,
                        invocation.stepTurn?.completionRequested != true,
                        run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit,
                        submission.continuationOnly ? receipt.couldResume(submission.context.instance)
                        : event.sessionID == submission.context.instance.conversationID && receipt.owns(submission.context.instance) else { continue }
                    try await enqueuePendingContinuation(receipt, run: run, invocation: invocation, bound: submission.context.instance)
                    return
                }
                guard
                    invocation.status == .running, let turn = invocation.stepTurn,
                    !turn.completionRequested,
                    native.nativeTurnID != turn.id || turn.stopped || invocation.continuationInstance != nil,
                    let node = run.definition.nodes.first(where: { $0.id == invocation.nodeID }), node.completion == .explicit else { continue }
                let prompt = AgentWorkflowPrompt.continuation(definition: run.definition, nodeID: node.id, invocationID: invocation.id)
                let isManualContinuation = invocation.continuationTurnID != turn.id || native.text != prompt
                let participant = run.definition.instance(for: node.agentInstanceID, in: run.instances)
                let bound = isManualContinuation ? run.instance(for: invocation) : invocation.continuationInstance ?? participant
                guard var instance = bound else { continue }
                if isManualContinuation {
                    guard receipt.couldResume(instance) else { continue }
                    try await enqueuePendingContinuation(receipt, run: run, invocation: invocation, bound: instance)
                    return
                }
                guard AgentReplyEvidence.owns(event, instance: instance, peer: peer) else { continue }
                instance.conversationID = event.sessionID
                try await catalog?.recordBridge(event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
                guard !stopped, pending[invocation.id] == nil else { return }
                let context = AgentWorkflowTurnContext(
                    runID: run.id, invocation: invocation, instance: instance, candidate: native, hookStartedAt: peer.workflowHookStart(for: instance)
                )
                _ = try await beginVerification(.init(
                    context: context, bindFirstConversation: false, isStepContinuation: true, requiresOrderCheck: true,
                    continuations: [.init(event: event, peer: peer, native: native, requiresOrderCheck: true)]
                ))
                return
            }
        }
    }

    private func enqueuePendingContinuation(
        _ receipt: PendingContinuation, run: AgentWorkflowRun, invocation: AgentWorkflowInvocation, bound: AgentWorkflowInstance
    ) async throws {
        guard let peer = receipt.peer, await recheckConversation(receipt.event, peer, false) != .superseded, !stopped else { return }
        let id = invocation.id
        if pending[id] == nil {
            let context = AgentWorkflowTurnContext(
                runID: run.id, invocation: invocation, instance: bound, candidate: receipt.native, hookStartedAt: receipt.startedAt(for: bound)
            )
            _ = try await beginVerification(.init(
                context: context, bindFirstConversation: false, isStepContinuation: true, requiresOrderCheck: true,
                continuationOnly: true, continuations: [receipt]
            ))
        } else {
            try await appendContinuation(receipt, to: id)
        }
    }

    private func appendContinuation(_ receipt: PendingContinuation, to id: UUID) async throws {
        guard let submission = pending[id] else { return }
        if
            !submission.continuations.contains(where: {
                $0.native == receipt.native && $0.event.sessionID == receipt.event.sessionID && $0.peer == receipt.peer
            }) {
            pending[id]?.continuations.append(receipt)
            if let entries = pending[id]?.continuations, entries.allSatisfy({ $0.startedAt(for: submission.context.instance) != nil }) {
                pending[id]?.continuations.sort {
                    ($0.startedAt(for: submission.context.instance) ?? .distantPast)
                        < ($1.startedAt(for: submission.context.instance) ?? .distantPast)
                }
            }
            pending[id]?.revision += 1
        }
        try await persistContinuations(id)
        scheduleSubmissionRetry(id)
    }

    func bufferPendingCompletion(_ event: PluginEvent, peer: PluginIngressPeer) async throws -> Bool {
        guard !stopped, let native = event.workflow, native.kind != .submitted else { return false }
        let archive = try await store.snapshot()
        discardSettledSubmissions(using: archive)
        for id in archive.pendingReceipts?.keys ?? [UUID: AgentWorkflowPendingReceipt]().keys {
            restoreContinuations(id, from: archive)
        }
        for (id, submission) in pending {
            let context = submission.context
            let known = [context.instance] + archive.instances + (archive.pendingReceipts?[id]?.continuations?.map(\.writer) ?? [])
            guard
                let writer = known.first(where: {
                    $0.agentID == context.instance.agentID && $0.workspacePane.isSamePane(as: context.instance.workspacePane)
                        && AgentReplyEvidence.owns(event, instance: $0, peer: peer)
                }) else { continue }
            let related = submission.continuations.indices.filter { index in
                let receipt = submission.continuations[index]
                guard
                    event.sessionID == receipt.event.sessionID && event.tmuxPane == receipt.event.tmuxPane
                    && event.pluginID == receipt.event.pluginID
                    && AgentReplyEvidence.turn(native, id: receipt.native.nativeTurnID, path: receipt.native.transcriptPath)
                    && receipt.owns(writer) else { return false }
                if let completionAt = peer.workflowHookStart(for: writer), let submittedAt = receipt.startedAt(for: writer) {
                    return completionAt > submittedAt
                }
                return true
            }
            if !related.isEmpty {
                let latest = related.compactMap { submission.continuations[$0].startedAt(for: writer) }.max()
                let matches = related.filter { submission.continuations[$0].startedAt(for: writer) == latest }
                let completion = HookCompletion(event: native, startedAt: peer.workflowHookStart(for: writer))
                for index in matches where !submission.continuations[index].following.contains(completion) {
                    pending[id]?.continuations[index].following.append(completion)
                    pending[id]?.revision += 1
                }
                try await persistContinuations(id)
                scheduleSubmissionRetry(id)
                return true
            }
            guard !submission.isStepContinuation else { continue }
            guard event.sessionID == context.instance.conversationID, AgentReplyEvidence.owns(event, instance: context.instance, peer: peer) else { continue }
            if AgentReplyEvidence.turn(native, id: context.candidate.nativeTurnID, path: context.candidate.transcriptPath) {
                let startedAt = peer.workflowHookStart(for: context.instance)
                if let startedAt, let submittedAt = context.hookStartedAt, startedAt <= submittedAt {
                    continue
                }
                let follows = native.kind == .failed || (submission.following?.startedAt.map { (startedAt ?? .distantPast) >= $0 } ?? true)
                if submission.following?.event.kind != .failed, follows {
                    pending[id]?.following = .init(event: native, startedAt: startedAt)
                    pending[id]?.revision += 1
                    try await store.recordCompletionEvidence(.init(
                        runID: context.runID, invocation: context.invocation, instance: context.instance, candidate: native, hookStartedAt: startedAt
                    ))
                }
                scheduleSubmissionRetry(id)
                return true
            }
        }
        // A native Stop can reach the socket before its submitted hook.
        // Keep it quarantined until a matching, verified submission owns it.
        if
            archive.runs.contains(where: { run in
                run.invocations.contains { call in
                    guard
                        AgentReplyEvidence.turn(native, id: call.resultTurnID, path: call.resultTranscriptPath),
                        let writer = run.instance(for: call), writer.conversationID == event.sessionID else { return false }
                    return AgentReplyEvidence.owns(event, instance: writer, peer: peer)
                }
            }) {
            return false
        }
        for run in archive.runs where !run.status.isTerminal {
            for call in run.invocations where call.round == run.round && [.writing, .running, .uncertain, .awaitingAcceptance].contains(call.status) {
                guard
                    run.definition.nodes.first(where: { $0.id == call.nodeID })?.completion == .explicit,
                    let bound = run.instance(for: call),
                    let writer = ([bound] + archive.instances + (archive.pendingReceipts?[call.id]?.continuations?.map(\.writer) ?? [])).first(where: {
                        $0.agentID == bound.agentID && AgentReplyEvidence.owns(event, instance: $0, peer: peer)
                    }) else { continue }
                var source = writer
                source.conversationID = event.sessionID
                try await store.saveContinuations(
                    [],
                    completions: [.init(writer: source, event: native, startedAt: peer.workflowHookStart(for: writer))],
                    runID: run.id,
                    invocationID: call.id
                )
                try restoreContinuations(call.id, from: await store.snapshot())
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
        if try await bufferPendingCompletion(event, peer: peer) {
            return nil
        }
        let archive = try await store.snapshot()
        guard !stopped else { return nil }
        discardSettledSubmissions(using: archive)
        if native.kind == .submitted, try await handleHistoricalSubmission(event, native: native, peer: peer, archive: archive) {
            return nil
        }
        if native.kind == .submitted, retryMatchingSubmission(event, native: native, peer: peer) {
            return nil
        }
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
                    let startedAt = peer.workflowHookStart(for: instance)
                    if native.kind == .failed {
                        // Keep the failure durable while inspecting the live writer.
                        try await store.recordCompletionEvidence(.init(
                            runID: run.id, invocation: invocation, instance: instance, candidate: native, hookStartedAt: startedAt
                        ))
                    }
                    let live = native.kind == .failed && process != nil ? try await inspect(instance) : instance
                    guard instance.matchesBinding(live) else { return nil }
                    return try await routeFollowing(.init(
                        runID: run.id, invocation: invocation, instance: live, candidate: native, hookStartedAt: startedAt
                    ))
                }
            }
            // The original receipt can survive a restart without an in-memory verifier.
            for run in archive.runs {
                for invocation in run.invocations where invocation.nativeTurnID == nil {
                    guard
                        let receipt = archive.pendingReceipts?[invocation.id], receipt.conversationID == event.sessionID,
                        AgentReplyEvidence.turn(native, id: receipt.turn.nativeTurnID, path: receipt.turn.transcriptPath),
                        var instance = run.instance(for: invocation), AgentReplyEvidence.owns(event, instance: instance, peer: peer) else { continue }
                    let bindsConversation = instance.conversationID != receipt.conversationID
                    instance.conversationID = receipt.conversationID
                    let submission = PluginWorkflowEvent(
                        kind: .submitted, nativeTurnID: receipt.turn.nativeTurnID, transcriptPath: receipt.turn.transcriptPath,
                        text: invocation.submissionText(pluginID: instance.pluginID)
                    )
                    let context = AgentWorkflowTurnContext(runID: run.id, invocation: invocation, instance: instance, candidate: submission)
                    return try await beginVerification(.init(
                        context: context, bindFirstConversation: bindsConversation,
                        following: .init(event: native, startedAt: peer.workflowHookStart(for: instance))
                    ))
                }
            }
            return nil
        }
        guard var observed = process else { return nil }
        observed.conversationID = event.sessionID
        let instance = observed
        if let submission = selectedResultReplay(native, instance: instance, in: archive) {
            guard pending[submission.context.invocation.id] == nil else { return nil }
            return try await beginVerification(submission)
        }
        let delivery = matchingDelivery(native, in: archive, pluginID: instance.pluginID) { run, invocation, writer in
            writer.matchesProcess(instance) || (invocation.nativeTurnID != nil && writer.matchesConversation(instance))
                || (!run.status.isTerminal && invocation.status == .running && invocation.stepTurn?.completionRequested == false
                    && writer.agentID == instance.agentID && writer.pluginID == instance.pluginID)
        }
        if
            let (run, invocation, writer) = delivery, !continuesDelivery(
                native, invocation: invocation, in: run, hookStartedAt: peer.workflowHookStart(for: instance), receipt: archive.pendingReceipts?[invocation.id]
            ) {
            guard
                [.writing, .awaitingAcceptance, .uncertain, .running, .succeeded].contains(invocation.status),
                invocation.nativeTurnID == nil || invocation.nativeTurnID == native.nativeTurnID,
                pending[invocation.id] == nil else { return nil }
            let disposition = try await observeSubmission(native, instance: instance, hookStartedAt: peer.workflowHookStart(for: instance))
            guard disposition != .superseded, !stopped else { return nil }
            let bindsConversation = !writer.matchesBinding(instance) && !writer.matchesConversation(instance)
            if bindsConversation, try !AgentWorkflowExecution(validating: run).canBindFirstConversation(instance, invocationID: invocation.id) {
                if !run.status.isTerminal {
                    try await store.update(runID: run.id) { $0.pause(reason: "The Agent's conversation changed after its first accepted task. Start a new run.") }
                }
                return nil
            }
            let context = AgentWorkflowTurnContext(
                runID: run.id,
                invocation: invocation,
                instance: instance,
                candidate: native,
                hookStartedAt: peer.workflowHookStart(for: instance)
            )
            return try await beginVerification(.init(
                context: context, bindFirstConversation: bindsConversation, requiresOrderCheck: disposition == .deferred
            ))
        }
        if
            let id = pending.first(where: { entry in
                let bound = entry.value.context.instance
                return (delivery == nil || delivery?.1.id == entry.key)
                    && (bound.matchesBinding(observed) || (entry.value.continuationOnly && bound.matchesProcess(observed)))
                    && (entry.value.isStepContinuation || entry.value.context.candidate.nativeTurnID != native.nativeTurnID)
                    && archive.runs.contains { run in
                        run.id == entry.value.context.runID && !run.status.isTerminal
                            && run.definition.nodes.first(where: { $0.id == entry.value.context.invocation.nodeID })?.completion == .explicit
                    }
            })?.key {
            let recorded = archive.runs.lazy.flatMap(\.invocations).first { $0.id == id }
            let repeatsRecordedTurn = recorded?.resultTurnID == native.nativeTurnID
            if repeatsRecordedTurn, pending[id]?.continuations.contains(where: { $0.native.nativeTurnID != native.nativeTurnID }) == true {
                return nil
            }
            if pending[id]?.continuations.contains(where: { $0.requiresOrderCheck == nil }) == true {
                try await appendContinuation(.init(event: event, peer: peer, native: native, requiresOrderCheck: true), to: id)
                return nil
            }
            let disposition = try await observeSubmission(native, instance: observed, hookStartedAt: peer.workflowHookStart(for: observed))
            guard disposition != .superseded, !stopped, pending[id] != nil else { return nil }
            try await appendContinuation(.init(
                event: event, peer: peer, native: native, requiresOrderCheck: disposition == .deferred || repeatsRecordedTurn
            ), to: id)
            return nil
        }
        let disposition = try await observeSubmission(native, instance: observed, hookStartedAt: peer.workflowHookStart(for: observed))
        guard disposition != .superseded, !stopped else { return nil }
        let requiresOrderCheck = disposition == .deferred

        for run in archive.runs where (run.instances + run.invocations.compactMap { run.instance(for: $0) }).contains(where: {
            $0.matchesProcess(instance) || ($0.agentID == instance.agentID && $0.pluginID == instance.pluginID)
        }) {
            let invocations = run.invocations.filter {
                guard delivery == nil || delivery?.1.id == $0.id else { return false }
                guard let bound = run.instance(for: $0) else { return false }
                if !run.status.isTerminal, $0.status == .running, $0.stepTurn?.completionRequested == false {
                    return bound.matchesProcess(instance) || (bound.agentID == instance.agentID && bound.pluginID == instance.pluginID)
                }
                return bound.matchesProcess(instance) || ($0.nativeTurnID != nil && bound.matchesConversation(instance))
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
                let context = AgentWorkflowTurnContext(
                    runID: run.id, invocation: invocation, instance: instance, candidate: native,
                    hookStartedAt: peer.workflowHookStart(for: instance)
                )
                return try await beginVerification(.init(
                    context: context, bindFirstConversation: false, isStepContinuation: true, requiresOrderCheck: requiresOrderCheck,
                    continuations: [.init(event: event, peer: peer, native: native, requiresOrderCheck: requiresOrderCheck)]
                ))
            }
        }
        return nil
    }

    private func beginVerification(_ submission: PendingSubmission) async throws -> AgentWorkflowTurnContext? {
        let id = submission.context.invocation.id
        if !submission.isStepContinuation, submission.context.invocation.nativeTurnID == nil {
            guard pending[id] == nil else { return nil }
            pending[id] = submission
            pending[id]?.verifying = true
            do {
                let recorded = try await store.recordPendingReceipt(submission.context)
                guard pending[id]?.generation == submission.generation, !stopped else { return nil }
                guard recorded else {
                    pending.removeValue(forKey: id)
                    return nil
                }
                if let following = pending[id]?.following {
                    let context = submission.context
                    try await store.recordCompletionEvidence(.init(
                        runID: context.runID, invocation: context.invocation, instance: context.instance,
                        candidate: following.event, hookStartedAt: following.startedAt
                    ))
                }
                pending[id]?.verifying = false
            } catch {
                if pending[id]?.generation == submission.generation {
                    pending.removeValue(forKey: id)
                }
                throw error
            }
        } else {
            pending[id]?.retry?.cancel()
            pending[id] = submission
        }
        try await persistContinuations(id)
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
        var useInitialReceipt = !submission.isStepContinuation
        let live: AgentWorkflowInstance
        do {
            let archive = try await store.snapshot()
            guard pending[id]?.generation == generation else { return nil }
            if try await discardOutdatedContinuationFailures(id, in: archive) {
                return nil
            }
            let retired = try await reconcileRetiredWriters(id, in: archive)
            guard pending[id]?.generation == generation else { return nil }
            if retired.settled {
                return nil
            }
            if retired.waiting {
                scheduleSubmissionRetry(id)
                return nil
            }
            if try await settleContinuationFailure(id, in: archive) {
                return nil
            }
            guard pending[id]?.generation == generation else { return nil }
            guard
                let run = archive.runs.first(where: { $0.id == candidate.runID }),
                Self.isUnsettled(id, in: run),
                !run.status.isTerminal || !submission.isStepContinuation else {
                pending.removeValue(forKey: id)?.retry?.cancel()
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
                    guard Self.isUnsettled(id, in: $0.run) else { return }
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
                    candidate.candidate, instance: live, hookStartedAt: candidate.hookStartedAt, pendingRevision: (id, generation, current.revision)
                )
                guard pending[id]?.generation == generation else { return nil }
                guard order != .deferred else {
                    scheduleSubmissionRetry(id)
                    return nil
                }
                useInitialReceipt = order == .ready
            }
        }
        if useInitialReceipt, submission.confirmsSelectedResult {
            try await store.accept(
                runID: candidate.runID, invocationID: id, instance: live, nativeTurnID: candidate.candidate.nativeTurnID,
                transcriptPath: candidate.candidate.transcriptPath, bindFirstConversation: false, confirmsSelectedResult: true
            )
        } else if useInitialReceipt {
            try await runner.accepted(
                runID: candidate.runID, invocationID: id, instance: live,
                nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath,
                bindFirstConversation: submission.bindFirstConversation
            )
        }
        if useInitialReceipt, let provider = await provider(live.pluginID) {
            do {
                let turn = PluginWorkflowTurn(nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath)
                _ = try await submissionReader(turn, instance: live, prompt: candidate.candidate.text, provider: provider, invocationID: id)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // The authenticated receipt can precede its native record.
                try Task.checkCancellation()
            }
        }
        while let resolved = pending[id], resolved.generation == generation {
            let revision = (id, generation, resolved.revision)
            var following = useInitialReceipt ? resolved.following : nil
            if submission.confirmsSelectedResult, let following {
                try await store.recordCompletionEvidence(.init(
                    runID: candidate.runID, invocation: candidate.invocation, instance: live,
                    candidate: following.event, hookStartedAt: following.startedAt
                ))
            }
            let archive = try await store.snapshot()
            guard matchesPendingRevision(revision) else { continue }
            if
                archive.pendingReceipts?[id]?.continuationFailure != nil
                || archive.pendingReceipts?[id]?.continuations?.contains(where: { $0.completion?.kind == .failed }) == true {
                scheduleSubmissionRetry(id)
                return nil
            }
            if useInitialReceipt {
                let turn = PluginWorkflowTurn(
                    nativeTurnID: candidate.candidate.nativeTurnID, transcriptPath: candidate.candidate.transcriptPath
                )
                if
                    let run = archive.runs.first(where: { $0.id == candidate.runID }),
                    let call = run.invocations.first(where: { $0.id == id }),
                    call.resultTurnID == turn.nativeTurnID, call.resultTranscriptPath == turn.transcriptPath,
                    let saved = archive.pendingReceipts?[id]?.completion(for: turn) {
                    following = .init(event: saved, startedAt: archive.pendingReceipts?[id]?.completionHookStartedAt)
                }
            }
            if let following, following.event.kind == .failed {
                guard matchesPendingRevision(revision) else { continue }
                let context = try await routeFollowing(.init(
                    runID: candidate.runID, invocation: candidate.invocation, instance: live,
                    candidate: following.event, hookStartedAt: following.startedAt
                ))
                guard matchesPendingRevision(revision) else { continue }
                pending.removeValue(forKey: id)
                return context
            }
            var writer = live
            let (receipt, isDeferred) = try await verifiedPendingContinuation(resolved, live: live, revision: revision)
            guard matchesPendingRevision(revision) else { continue }
            if let receipt {
                if let following {
                    try await store.recordCompletionEvidence(.init(
                        runID: candidate.runID, invocation: candidate.invocation, instance: live,
                        candidate: following.event, hookStartedAt: following.startedAt
                    ))
                    guard matchesPendingRevision(revision) else { continue }
                }
                writer = receipt.instance
                let recorded = try await recordStepTurn(
                    receipt.submission.native, runID: candidate.runID, invocationID: id, instance: writer,
                    hookStartedAt: receipt.submission.startedAt(for: writer), following: receipt.following, verifiedSubmission: receipt.proof
                )
                if !recorded, receipt.following?.event.kind != .failed {
                    scheduleSubmissionRetry(id)
                    return nil
                }
                following = receipt.following
            } else if isDeferred {
                scheduleSubmissionRetry(id)
                return nil
            }
            var context: AgentWorkflowTurnContext?
            if let following {
                let next = AgentWorkflowTurnContext(
                    runID: candidate.runID, invocation: candidate.invocation, instance: writer,
                    candidate: following.event, hookStartedAt: following.startedAt
                )
                context = try await routeFollowing(next)
            } else if useInitialReceipt, resolved.continuations.isEmpty, candidate.invocation.nativeTurnID == nil {
                let current = try await store.snapshot().runs.first(where: { $0.id == candidate.runID })?.invocations.first(where: { $0.id == id })
                if current?.stepTurn == nil {
                    context = .init(runID: candidate.runID, invocation: candidate.invocation, instance: live, candidate: candidate.candidate)
                }
            }
            // Keep completion blocked until every event received during the
            // asynchronous writes above has also been applied.
            guard matchesPendingRevision((id, generation, resolved.revision)) else { continue }
            try await store.removeContinuations(await storedContinuations(resolved), invocationID: id, keepingAccepted: true)
            guard matchesPendingRevision(revision) else { continue }
            pending.removeValue(forKey: id)
            return context
        }
        return nil
    }

    private func conversationDisposition(
        _ receipt: PendingContinuation, admitting: Bool, confirmed: AgentWorkflowStore.SubmissionDisposition
    ) async -> AgentWorkflowStore.SubmissionDisposition {
        guard receipt.requiresOrderCheck == nil, let peer = receipt.peer else { return confirmed }
        return await recheckConversation(receipt.event, peer, admitting)
    }

    private func storedContinuations(_ submission: PendingSubmission) async throws -> [AgentWorkflowContinuationReceipt] {
        let archive = try await store.snapshot()
        return submission.continuations.compactMap { receipt in
            guard
                var writer = receipt.saved?.writer ?? ([submission.context.instance] + archive.instances).first(where: {
                    $0.agentID == submission.context.instance.agentID && receipt.owns($0)
                }) else { return nil }
            writer.conversationID = receipt.event.sessionID
            let stop = receipt.completion(from: writer)
            return .init(
                writer: writer,
                submission: receipt.native,
                submittedAt: receipt.startedAt(for: writer),
                completion: stop?.event,
                completedAt: stop?.startedAt
            )
        }
    }

    private func persistContinuations(_ id: UUID) async throws {
        guard let submission = pending[id] else { return }
        let entries = try await storedContinuations(submission)
        let completions = entries.flatMap { entry -> [AgentWorkflowContinuationCompletion] in
            submission.continuations.filter { $0.native == entry.submission && $0.startedAt(for: entry.writer) == entry.submittedAt }
                .flatMap(\.following).map { .init(writer: entry.writer, event: $0.event, startedAt: $0.startedAt) }
        }
        try await store.saveContinuations(entries, completions: completions, runID: submission.context.runID, invocationID: id)
    }

    private func restoreContinuations(_ id: UUID, from archive: AgentWorkflowArchive) {
        guard
            !stopped, pending[id] == nil,
            let entries = archive.pendingReceipts?[id]?.continuations, !entries.isEmpty,
            let run = archive.runs.first(where: { Self.isUnsettled(id, in: $0) }),
            let call = run.invocations.first(where: { $0.id == id }), let bound = run.instance(for: call),
            let initial = archive.pendingReceipts?[id] else { return }
        var ordered = entries.filter { $0.isRetired != true }
        guard !ordered.isEmpty else { return }
        if ordered.allSatisfy({ $0.submittedAt != nil }) {
            ordered.sort { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
        }
        let continuations: [PendingContinuation] = ordered.map { entry in
            let event = PluginEvent(
                pluginID: entry.writer.pluginID,
                sessionID: entry.writer.conversationID,
                tmuxPane: entry.writer.paneID,
                workflow: entry.submission
            )
            return .init(
                event: event,
                peer: nil,
                native: entry.submission,
                requiresOrderCheck: true,
                following: entry.completion.map { [.init(event: $0, startedAt: entry.completedAt)] } ?? [],
                saved: entry
            )
        }
        let candidate = call.nativeTurnID == nil
            ? PluginWorkflowEvent(
                kind: .submitted,
                nativeTurnID: initial.turn.nativeTurnID,
                transcriptPath: initial.turn.transcriptPath,
                text: call.submissionText(pluginID: bound.pluginID)
            )
            : ordered[0].submission
        var firstWriter = bound
        if call.nativeTurnID == nil {
            firstWriter.conversationID = initial.conversationID
        }
        let bindsConversation = call.nativeTurnID == nil && !bound.matchesBinding(firstWriter)
            && (try? AgentWorkflowExecution(validating: run).canBindFirstConversation(firstWriter, invocationID: id)) == true
        let context = AgentWorkflowTurnContext(
            runID: run.id,
            invocation: call,
            instance: firstWriter,
            candidate: candidate,
            hookStartedAt: initial.submittedHookStartedAt
        )
        pending[id] = .init(
            context: context,
            bindFirstConversation: bindsConversation,
            isStepContinuation: call.nativeTurnID != nil,
            requiresOrderCheck: true,
            continuationOnly: call.nativeTurnID != nil,
            continuations: continuations
        )
        scheduleSubmissionRetry(id)
    }

    private func reloadContinuations(_ id: UUID, removing entries: [AgentWorkflowContinuationReceipt]) async throws {
        try await store.removeContinuations(entries, invocationID: id)
        pending.removeValue(forKey: id)?.retry?.cancel()
        try restoreContinuations(id, from: await store.snapshot())
    }

    private func reconcileRetiredWriters(_ id: UUID, in archive: AgentWorkflowArchive) async throws -> (settled: Bool, waiting: Bool) {
        guard
            let receipt = archive.pendingReceipts?[id], let entries = receipt.continuations,
            let run = archive.runs.first(where: { Self.isUnsettled(id, in: $0) }),
            let call = run.invocations.first(where: { $0.id == id }), call.nativeTurnID != nil else { return (false, false) }
        var waiting = false
        var completed: [(AgentWorkflowContinuationReceipt, AgentWorkflowTranscriptFile.VerifiedRecoveryEnd)] = []
        for (index, entry) in entries.enumerated() {
            let replaced = archive.instances.contains { $0.agentID == entry.writer.agentID && !$0.matchesProcess(entry.writer) }
            let superseded = entries.dropFirst(index + 1).contains { !$0.writer.matchesBinding(entry.writer) }
            let requiresTerminal = replaced || superseded || entry.isRetired == true || entry.nativeStart != nil || entry.completion?.kind == .failed
            // A reused ID can hide an aborted segment before the latest start.
            let sameTurn = AgentReplyEvidence.turn(entry.submission, id: call.resultTurnID, path: call.resultTranscriptPath)
            guard requiresTerminal || sameTurn else { continue }
            guard let belongs = try await continuationBelongs(entry, invocation: call, receipt: receipt, instance: entry.writer) else {
                waiting = waiting || (requiresTerminal && entry.isRetired != true)
                continue
            }
            if !belongs {
                try await reloadContinuations(id, removing: [entry])
                return (false, false)
            }
            if let failure = entry.completion, failure.kind == .failed {
                try await store.failContinuation(entry, runID: run.id, invocationID: id, reason: failure.text, nativeEnd: nil)
                try discardSettledSubmissions(using: await store.snapshot())
                return (true, false)
            }
            guard let provider = await provider(entry.writer.pluginID) else {
                waiting = waiting || (requiresTerminal && entry.isRetired != true)
                continue
            }
            let reading: (file: AgentWorkflowTranscriptFile, delivery: AgentWorkflowTranscriptFile.VerifiedSubmission?)
            do {
                reading = try await submissionReader(
                    .init(nativeTurnID: entry.submission.nativeTurnID, transcriptPath: entry.submission.transcriptPath),
                    instance: entry.writer, prompt: entry.submission.text, provider: provider, invocationID: id
                )
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                waiting = waiting || (requiresTerminal && entry.isRetired != true)
                continue
            }
            let turn = PluginWorkflowTurn(nativeTurnID: entry.submission.nativeTurnID, transcriptPath: entry.submission.transcriptPath)
            let originalEntry = receipt.isOriginalSubmission(entry, prompt: call.submissionText(pluginID: entry.writer.pluginID))
            let delivery = reading.delivery
            if originalEntry, delivery?.isCurrent != true {
                waiting = true
                continue
            }
            let source = if originalEntry, delivery?.isRejection == true {
                delivery
            } else {
                try await reading.file.verifySubmittedTurn(turn, hookStartedAt: entry.submittedAt, nativeStart: originalEntry ? delivery?.nativeStart : entry.nativeStart)
            }
            guard
                let source,
                let sourceStart = source.nativeStart,
                !originalEntry || delivery.map({ source.hasSameRevision(as: $0) }) == true else {
                waiting = waiting || (requiresTerminal && entry.isRetired != true)
                continue
            }
            if !requiresTerminal {
                guard
                    let selected = receipt.selectedSubmission?.nativeStart, selected.identity == sourceStart.identity,
                    sourceStart.offset > selected.offset else { continue }
            }
            let reader = try AgentWorkflowTranscriptFile(path: turn.transcriptPath, parser: provider.workflowTranscript(
                conversationID: entry.writer.conversationID, nativeTurnID: turn.nativeTurnID,
                prompt: entry.submission.text, candidate: entry.completion?.text ?? ""
            ))
            guard
                let (outcome, end) = try await reader.verifiedOutcome(for: source, hasStop: entry.completion?.kind == .stopCandidate) else {
                waiting = true
                continue
            }
            guard let outcome else {
                waiting = waiting || (requiresTerminal && entry.isRetired != true)
                continue
            }
            switch outcome {
            case let .failed(reason):
                try await store.failContinuation(entry, runID: run.id, invocationID: id, reason: reason, nativeEnd: end)
                try discardSettledSubmissions(using: await store.snapshot())
                return (true, false)
            case let .succeeded(text):
                guard requiresTerminal else { continue }
                let stopped = call.stepTurn?.stopped == true && call.resultTurnID == entry.submission.nativeTurnID
                    && call.resultTranscriptPath == entry.submission.transcriptPath && run.instance(for: call)?.matchesBinding(entry.writer) == true
                if entry.completion?.corroboratesAnswer(text) == true || (entry.completion == nil && stopped) {
                    if entry.isRetired != true {
                        completed.append((entry, end))
                    }
                } else {
                    waiting = waiting || entry.isRetired != true
                }
            }
        }
        for (entry, end) in completed {
            try await store.retireContinuation(entry, invocationID: id, nativeEnd: end)
        }
        if !completed.isEmpty {
            try await reloadContinuations(id, removing: [])
        }
        return (false, waiting)
    }

    private func discardOutdatedContinuationFailures(_ id: UUID, in archive: AgentWorkflowArchive) async throws -> Bool {
        if
            let receipt = archive.pendingReceipts?[id], let resumedAt = receipt.resumedHookStartedAt,
            let run = archive.runs.first(where: { Self.isUnsettled(id, in: $0) }),
            let call = run.invocations.first(where: { $0.id == id }) {
            let candidates = (receipt.continuations ?? []) + (receipt.continuationFailure.map { [$0.receipt] } ?? [])
            let outdated = candidates.filter {
                $0.completion?.kind == .failed
                    && AgentReplyEvidence.turn($0.submission, id: call.resultTurnID, path: call.resultTranscriptPath)
                    && $0.submittedAt.map { $0 < resumedAt } == true
            }
            if !outdated.isEmpty {
                let sameHooks = candidates.filter { candidate in
                    outdated.contains { old in
                        old.writer.matchesBinding(candidate.writer) && old.submittedAt == candidate.submittedAt
                            && AgentReplyEvidence.turn(candidate.submission, id: old.submission.nativeTurnID, path: old.submission.transcriptPath)
                    }
                }
                try await reloadContinuations(id, removing: sameHooks)
                return true
            }
        }
        return false
    }

    private func settleContinuationFailure(_ id: UUID, in archive: AgentWorkflowArchive) async throws -> Bool {
        if try await discardOutdatedContinuationFailures(id, in: archive) {
            return false
        }
        if
            let receipt = archive.pendingReceipts?[id], let run = archive.runs.first(where: { Self.isUnsettled(id, in: $0) }),
            let invocation = run.invocations.first(where: { $0.id == id }),
            let entry = receipt.continuations?.first(where: { $0.completion?.kind == .failed }), let failure = entry.completion {
            let live = try await inspect(entry.writer)
            guard live.matchesBinding(entry.writer) else { throw AgentWorkflowInspectionUnavailable() }
            if invocation.nativeTurnID == nil, let issue = live.capabilityIssue {
                throw AgentWorkflowError(issue)
            }
            guard let belongs = try await continuationBelongs(entry, invocation: invocation, receipt: receipt, instance: live) else {
                throw AgentWorkflowInspectionUnavailable()
            }
            if !belongs {
                try await reloadContinuations(id, removing: [entry])
                return false
            }
            if invocation.nativeTurnID == nil {
                try await runner.accepted(
                    runID: run.id,
                    invocationID: id,
                    instance: live,
                    nativeTurnID: receipt.turn.nativeTurnID,
                    transcriptPath: receipt.turn.transcriptPath,
                    bindFirstConversation: AgentWorkflowExecution(validating: run).canBindFirstConversation(live, invocationID: id)
                )
            }
            guard
                try await recordStepTurn(
                    entry.submission,
                    runID: run.id,
                    invocationID: id,
                    instance: live,
                    hookStartedAt: entry.submittedAt,
                    following: .init(event: failure, startedAt: entry.completedAt)
                ) else {
                throw AgentWorkflowInspectionUnavailable()
            }
            _ = try await routeFollowing(.init(runID: run.id, invocation: invocation, instance: live, candidate: failure, hookStartedAt: entry.completedAt))
            guard try await store.snapshot().pendingReceipts?[id] == nil else { throw AgentWorkflowInspectionUnavailable() }
            try discardSettledSubmissions(using: await store.snapshot())
            return true
        }
        guard
            let evidence = archive.pendingReceipts?[id]?.continuationFailure,
            let run = archive.runs.first(where: { Self.isUnsettled(id, in: $0) }),
            let invocation = run.invocations.first(where: { $0.id == id }) else { return false }
        let live = try await inspect(evidence.writer)
        guard live.matchesBinding(evidence.writer) else { throw AgentWorkflowInspectionUnavailable() }
        guard
            let receipt = archive.pendingReceipts?[id],
            try await continuationBelongs(
                .init(
                    writer: evidence.writer,
                    submission: evidence.submission,
                    submittedAt: evidence.submittedAt,
                    completion: evidence.failure,
                    completedAt: evidence.failedAt
                ),
                invocation: invocation,
                receipt: receipt,
                instance: live
            ) == true else { throw AgentWorkflowInspectionUnavailable() }
        guard
            try await recordStepTurn(
                evidence.submission, runID: run.id, invocationID: id, instance: live, hookStartedAt: evidence.submittedAt,
                following: .init(event: evidence.failure, startedAt: evidence.failedAt)
            ) else { throw AgentWorkflowInspectionUnavailable() }
        _ = try await routeFollowing(.init(
            runID: run.id, invocation: invocation, instance: live, candidate: evidence.failure, hookStartedAt: evidence.failedAt
        ))
        let updated = try await store.snapshot()
        guard updated.pendingReceipts?[id]?.continuationFailure == nil else { throw AgentWorkflowInspectionUnavailable() }
        discardSettledSubmissions(using: updated)
        return true
    }

    private func continuationBelongs(
        _ entry: AgentWorkflowContinuationReceipt, invocation: AgentWorkflowInvocation,
        receipt: AgentWorkflowPendingReceipt, instance: AgentWorkflowInstance, afterSelected: Bool = false
    ) async throws -> Bool? {
        let anchor = PluginWorkflowTurn(
            nativeTurnID: (afterSelected ? invocation.resultTurnID : invocation.nativeTurnID) ?? receipt.turn.nativeTurnID,
            transcriptPath: (afterSelected ? invocation.resultTranscriptPath : invocation.nativeTranscriptPath) ?? receipt.turn.transcriptPath
        )
        let turn = PluginWorkflowTurn(nativeTurnID: entry.submission.nativeTurnID, transcriptPath: entry.submission.transcriptPath)
        if anchor == turn {
            return true
        } // Same-ID segments are checked by recordStepTurn.
        if
            !afterSelected || invocation.continuationTurnID == invocation.resultTurnID,
            invocation.continuationTurnID != nil, invocation.continuationInstance?.matchesBinding(instance) == true,
            let run = try await store.snapshot().runs.first(where: { $0.id == invocation.delivery.runID }),
            entry.submission.text == AgentWorkflowPrompt.continuation(definition: run.definition, nodeID: invocation.nodeID, invocationID: invocation.id) {
            return true
        }
        guard let provider = await provider(instance.pluginID) else { return nil }
        let file = try await submissionReader(turn, instance: instance, prompt: entry.submission.text, provider: provider, invocationID: invocation.id)
        guard let candidate = try await file.file.verifySubmittedTurn(turn, hookStartedAt: entry.submittedAt, nativeStart: entry.nativeStart) else { return nil }
        let conversation = afterSelected ? invocation.instance?.conversationID ?? receipt.conversationID : receipt.conversationID
        var originalWriter = instance
        originalWriter.conversationID = conversation
        let originalFile = try await submissionReader(
            anchor, instance: originalWriter, prompt: invocation.submissionText(pluginID: instance.pluginID),
            provider: provider, invocationID: invocation.id
        )
        let input = invocation.submissionText(pluginID: instance.pluginID)
        let selectedIsDelivery = receipt.selectedSubmission.map { receipt.isOriginalSubmission($0, prompt: input) } ?? ((invocation.stepTurn?.prompt ?? input) == input)
        let usesDelivery = anchor == receipt.turn && (!afterSelected || selectedIsDelivery)
        if usesDelivery, originalFile.delivery?.isCurrent != true {
            return nil
        }
        guard
            let original = try await originalFile.file.verifySubmittedTurn(
                anchor, firstOccurrence: !usesDelivery && !afterSelected && receipt.submittedHookStartedAt == nil,
                hookStartedAt: afterSelected ? receipt.selectedSubmission?.submittedAt : receipt.submittedHookStartedAt,
                nativeStart: usesDelivery ? originalFile.delivery?.nativeStart : receipt.selectedSubmission?.nativeStart
            ), candidate.isCurrent, original.isCurrent,
            !usesDelivery || originalFile.delivery.map({ original.hasSameRevision(as: $0) && $0.isCurrent }) == true else { return nil }
        if afterSelected {
            try await store.rememberSubmission(original, invocationID: invocation.id)
        }
        if anchor.transcriptPath == turn.transcriptPath {
            guard let candidateStart = candidate.nativeStart, let originalStart = original.nativeStart else { return nil }
            return candidateStart.identity == originalStart.identity && candidateStart.offset > originalStart.offset
        }
        if let submittedAt = entry.submittedAt, let original = receipt.submittedHookStartedAt, submittedAt <= original {
            return false
        }
        guard let candidateAt = candidate.submittedAt, let originalAt = original.submittedAt else { return nil }
        return candidateAt > originalAt
    }

    private func verifiedPendingContinuation(
        _ submission: PendingSubmission, live: AgentWorkflowInstance, revision: (id: UUID, generation: UUID, revision: Int)
    ) async throws -> (receipt: (instance: AgentWorkflowInstance, submission: PendingContinuation, following: HookCompletion?, proof: AgentWorkflowTranscriptFile.VerifiedSubmission)?, isDeferred: Bool) {
        guard !submission.continuations.isEmpty else { return (nil, false) }
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
        var missingNewerReceipt = false
        let archive = try await store.snapshot()
        let call = archive.runs.first(where: { $0.id == submission.context.runID })?.invocations.first(where: { $0.id == revision.id })
        for receipt in owned {
            var writer = current
            writer.conversationID = receipt.event.sessionID
            let turn = PluginWorkflowTurn(nativeTurnID: receipt.native.nativeTurnID, transcriptPath: receipt.native.transcriptPath)
            // A Claude rejection has no prompt ID. Match it within this
            // submission's interval before the next hook for the same input.
            let older = try await isSupersededSubmission(
                turn, prompt: receipt.native.text, instance: writer, requiringReceipt: true,
                submissionRejectionWindow: receipt.rejectionWindow(among: owned, writer: writer), invocationID: revision.id,
                hookStartedAt: receipt.startedAt(for: writer), nativeStart: receipt.saved?.nativeStart
            )
            guard matchesPendingRevision(revision) else { return (nil, false) }
            if let older {
                if !older {
                    guard let call, let saved = archive.pendingReceipts?[call.id] else { return (nil, true) }
                    let entry = AgentWorkflowContinuationReceipt(writer: writer, submission: receipt.native, submittedAt: receipt.startedAt(for: writer))
                    guard let belongs = try await continuationBelongs(entry, invocation: call, receipt: saved, instance: writer) else { return (nil, true) }
                    if belongs {
                        guard let follows = try await continuationBelongs(entry, invocation: call, receipt: saved, instance: writer, afterSelected: true) else {
                            return (nil, true)
                        }
                        if follows {
                            latest.append((receipt, writer))
                        }
                    }
                } else if let call, let saved = archive.pendingReceipts?[call.id] {
                    let entry = AgentWorkflowContinuationReceipt(writer: writer, submission: receipt.native, submittedAt: receipt.startedAt(for: writer))
                    let belongs = try await continuationBelongs(entry, invocation: call, receipt: saved, instance: writer, afterSelected: true)
                    missingNewerReceipt = missingNewerReceipt || belongs != false
                }
            } else {
                let disposition = await conversationDisposition(receipt, admitting: false, confirmed: .deferred)
                guard matchesPendingRevision(revision) else { return (nil, false) }
                if disposition != .superseded {
                    return (nil, true)
                }
            }
        }

        var isDeferred = latest.isEmpty && missingNewerReceipt
        for (receipt, instance) in latest {
            let disposition = await conversationDisposition(receipt, admitting: true, confirmed: .ready)
            guard matchesPendingRevision(revision) else { return (nil, false) }
            guard disposition == .ready else {
                isDeferred = isDeferred || disposition == .deferred
                continue
            }
            if let peer = receipt.peer {
                try await catalog?.recordBridge(receipt.event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
            }
            let verified: AgentWorkflowInstance
            do {
                verified = !submission.continuationOnly && instance.matchesBinding(live) ? live : try await inspect(instance)
            } catch is AgentWorkflowInspectionUnavailable {
                isDeferred = true
                continue
            }
            guard matchesPendingRevision(revision) else { return (nil, false) }
            guard instance.matchesBinding(verified) else {
                throw AgentWorkflowError("The Agent changed before its submission receipt could be verified.")
            }
            if let issue = verified.capabilityIssue {
                throw AgentWorkflowError(issue)
            }
            let turn = PluginWorkflowTurn(nativeTurnID: receipt.native.nativeTurnID, transcriptPath: receipt.native.transcriptPath)
            let proof = try await verifyCurrentSubmission(
                turn, prompt: receipt.native.text, instance: verified, hookStartedAt: receipt.startedAt(for: verified), invocationID: revision.id
            )
            guard matchesPendingRevision(revision) else { return (nil, false) }
            guard let proof else {
                isDeferred = true
                continue
            }
            let order = try await store.observeSubmission(receipt.native, instance: verified, verifiedTranscript: proof)
            guard matchesPendingRevision(revision) else { return (nil, false) }
            if order == .ready {
                let ledger = try await store.snapshot().pendingReceipts?[revision.id]
                guard matchesPendingRevision(revision) else { return (nil, false) }
                let selected = ledger?.continuations?.first {
                    $0.writer.matchesBinding(verified) && $0.submission == receipt.native && $0.submittedAt == receipt.startedAt(for: verified)
                }
                let completion = selected?.completion.map { HookCompletion(event: $0, startedAt: selected?.completedAt) }
                return ((verified, receipt, completion, proof), false)
            }
            isDeferred = isDeferred || order == .deferred
        }
        return (nil, isDeferred)
    }

    private func verifyCurrentSubmission(
        _ turn: PluginWorkflowTurn, prompt: String, instance: AgentWorkflowInstance, hookStartedAt: Date? = nil, invocationID: UUID? = nil
    ) async throws -> AgentWorkflowTranscriptFile.VerifiedSubmission? {
        guard let provider = await provider(instance.pluginID) else { return nil }
        do {
            let file = try await submissionReader(turn, instance: instance, prompt: prompt, provider: provider, invocationID: invocationID)
            return try await file.file.verifyCurrentSubmission(turn, hookStartedAt: hookStartedAt)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func submissionReader(
        _ turn: PluginWorkflowTurn, instance: AgentWorkflowInstance, prompt: String,
        provider: any AgentWorkflowProviding, rejectionWindow: Range<Date>? = nil, invocationID: UUID? = nil
    ) async throws -> (file: AgentWorkflowTranscriptFile, delivery: AgentWorkflowTranscriptFile.VerifiedSubmission?) {
        let archive = try await store.snapshot()
        var anchor: AgentWorkflowTranscriptFile.SubmissionAnchor?
        var delivery: AgentWorkflowTranscriptFile.VerifiedSubmission?
        if
            let invocationID, let receipt = archive.pendingReceipts?[invocationID], receipt.turn.transcriptPath == turn.transcriptPath,
            let invocation = archive.runs.lazy.flatMap(\.invocations).first(where: { $0.id == invocationID }) {
            let input = invocation.submissionText(pluginID: instance.pluginID)
            var originalWriter = instance
            originalWriter.conversationID = receipt.conversationID
            let known = receipt.originalSubmissionStart.flatMap {
                $0.inputOffset == nil || $0.inputEnd == nil ? nil : AgentWorkflowTranscriptFile.SubmissionAnchor(
                    turnID: receipt.turn.nativeTurnID, boundary: $0, hookStartedAt: receipt.submittedHookStartedAt
                )
            }
            do {
                let original = try await submissionReaders.reader(
                    turn: receipt.turn, instance: originalWriter, prompt: input, provider: provider, anchor: known, forDelivery: true
                )
                if let proof = try await original.verifyDelivery(receipt.turn, input: input) {
                    delivery = proof
                    try await store.rememberDelivery(proof, invocationID: invocationID)
                    if let start = proof.nativeStart {
                        anchor = .init(turnID: receipt.turn.nativeTurnID, boundary: start, hookStartedAt: receipt.submittedHookStartedAt)
                    }
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                try Task.checkCancellation()
            }
        }
        return try (await submissionReaders.reader(turn: turn, instance: instance, prompt: prompt, provider: provider, rejectionWindow: rejectionWindow, anchor: anchor), delivery)
    }

    private func scheduleSubmissionRetry(_ id: UUID) {
        guard let submission = pending[id], submission.retry == nil else { return }
        let generation = submission.generation
        pending[id]?.retry = Task { await self.retrySubmission(id, generation: generation) }
    }

    private func retryMatchingSubmission(_ event: PluginEvent, native: PluginWorkflowEvent, peer: PluginIngressPeer) -> Bool {
        guard
            let entry = pending.first(where: {
                !$0.value.continuationOnly && $0.value.context.candidate == native
                    && $0.value.context.instance.conversationID == event.sessionID
                    && AgentReplyEvidence.owns(event, instance: $0.value.context.instance, peer: peer)
                    && (!$0.value.isStepContinuation || $0.value.context.hookStartedAt == peer.workflowHookStart(for: $0.value.context.instance))
            }) else { return false }
        scheduleSubmissionRetry(entry.key)
        return true
    }

    private func retrySubmission(_ id: UUID, generation: UUID) async {
        let deadline = clock.now.advanced(by: verificationTimeout)
        do {
            while pending[id]?.generation == generation {
                try await clock.sleep(for: .milliseconds(200))
                guard pending[id]?.generation == generation else { return }
                guard clock.now < deadline else {
                    if try await expireStoppedReplay(id, generation: generation) {
                        return
                    }
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
            do {
                let run = try await store.update(runID: unresolved.context.runID) {
                    guard !Task.isCancelled, Self.isUnsettled(id, in: $0.run) else { return }
                    guard !Self.confirmedFirstReceipt(unresolved, in: $0.run) else { return }
                    $0.pause(reason: error.localizedDescription)
                }
                discardSettledSubmissions(in: run)
                if Self.confirmedFirstReceipt(unresolved, in: run) {
                    if pending[id]?.generation == generation {
                        discardRecoveredSubmissions(in: run)
                    }
                } else if !Task.isCancelled, Self.isUnsettled(id, in: run) {
                    onFailure("Could not verify a workflow submission receipt: \(error.localizedDescription)")
                }
            } catch { onFailure("Could not pause the workflow: \(error.localizedDescription)") }
        }
    }

    private func expireStoppedReplay(_ id: UUID, generation: UUID) async throws -> Bool {
        guard
            let submission = pending[id], submission.generation == generation,
            try await isStoppedReplayCandidate(id, submission: submission) else { return false }
        if let context = try await verifySubmission(id, generation: generation) {
            await onVerified(context)
        }
        // Keep an inconclusive receipt available for a fresh Hook or completion check.
        if pending[id]?.generation == generation {
            pending[id]?.retry = nil
        }
        return true
    }

    private func isStoppedReplayCandidate(_ id: UUID, submission: PendingSubmission) async throws -> Bool {
        guard !stopped, submission.isStepContinuation else { return false }
        let archive = try await store.snapshot()
        guard
            let run = archive.runs.first(where: { $0.id == submission.context.runID }),
            let turn = run.invocations.first(where: { $0.id == id })?.stepTurn, turn.stopped, !turn.completionRequested,
            let stoppedAt = archive.pendingReceipts?[id]?.completionHookStartedAt,
            archive.pendingReceipts?[id]?.backgroundTurn != .init(nativeTurnID: turn.id, transcriptPath: turn.transcriptPath),
            AgentReplyEvidence.turn(submission.context.candidate, id: turn.id, path: turn.transcriptPath),
            submission.continuationOnly || submission.context.hookStartedAt.map({ $0 <= stoppedAt }) == true,
            submission.following?.event.kind != .failed,
            submission.continuations.allSatisfy({ receipt in
                AgentReplyEvidence.turn(receipt.native, id: turn.id, path: turn.transcriptPath)
                    && !receipt.following.contains(where: { $0.event.kind == .failed })
                    && receipt.startedAt(for: submission.context.instance).map { $0 <= stoppedAt } == true
            }),
            matchesPendingRevision((id, submission.generation, submission.revision)) else { return false }
        return true
    }

    private func routeFollowing(_ context: AgentWorkflowTurnContext) async throws -> AgentWorkflowTurnContext? {
        guard case let .recorded(previousStop) = try await store.recordCompletionEvidence(context) else { return nil }
        let run = try await store.snapshot().runs.first(where: { $0.id == context.runID })
        guard
            let run, let invocation = run.invocations.first(where: { $0.id == context.invocation.id }),
            [.running, .uncertain].contains(invocation.status),
            AgentReplyEvidence.turn(context.candidate, id: invocation.resultTurnID, path: invocation.resultTranscriptPath),
            run.instance(for: invocation)?.matchesBinding(context.instance) == true else { return nil }
        if invocation.stepTurn != nil {
            guard context.candidate.kind == .failed || invocation.stepTurn?.completionRequested == true else { return nil }
        }
        if context.candidate.kind == .failed {
            try await runner.failed(
                runID: context.runID, invocationID: context.invocation.id, instance: context.instance,
                nativeTurnID: context.candidate.nativeTurnID, reason: context.candidate.text
            )
            return nil
        }
        return .init(
            runID: context.runID, invocation: invocation, instance: context.instance, candidate: context.candidate,
            hookStartedAt: context.hookStartedAt, previousStop: previousStop
        )
    }
}
