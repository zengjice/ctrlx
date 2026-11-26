import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Workflow policy around the shared native reply verifier.
actor AgentWorkflowCompletionMonitor {
    private let monitor: AgentReplyMonitor

    init(
        store: AgentWorkflowStore,
        runner: AgentWorkflowRunner,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        synchronizeIngress: @escaping @Sendable () async throws -> Void = { },
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        let readers = AgentWorkflowTranscriptReaders()
        self.monitor = AgentReplyMonitor(state: { context in
            let archive = try await store.snapshot()
            let submissionOnly = context.candidate.kind == .submitted || context.candidate.hasPendingWork
            let pending = archive.runs.contains { run in
                (!run.status.isTerminal || !submissionOnly) && run.invocations.contains {
                    $0.id == context.id && $0.resultTurnID == context.candidate.nativeTurnID
                        && ($0.status == .running || (!submissionOnly && $0.status == .uncertain))
                }
            }
            let current = archive.instances.first {
                $0.matchesBinding(context.instance) || $0.matchesConversation(context.instance)
            } ?? archive.instances.first { $0.matchesProcess(context.instance) }.map { _ in context.instance }
            // A stale catalog conversation does not replace the accepted turn.
            // inspect still verifies its live process and native conversation.
            return AgentReplyState(isPending: pending, instance: current)
        }, completed: { context, live, outcome, _, nativeEnd in
            let archive = try await store.snapshot()
            guard let run = archive.runs.first(where: { $0.invocations.contains { $0.id == context.id } }) else { return }
            if let startedAt = context.hookStartedAt, archive.pendingReceipts?[context.id]?.completionHookStartedAt != startedAt {
                return
            }
            switch outcome {
            case let .succeeded(answer):
                try await runner.succeeded(runID: run.id, result: .init(
                    invocationID: context.id, nativeTurnID: context.candidate.nativeTurnID,
                    text: answer, completedAt: Date()
                ), instance: live, nativeEnd: nativeEnd)
            case let .failed(reason):
                try await runner.failed(
                    runID: run.id,
                    invocationID: context.id,
                    instance: live,
                    nativeTurnID: context.candidate.nativeTurnID,
                    reason: reason,
                    nativeEnd: nativeEnd
                )
            }
        }, waiting: { context, reason, temporary in
            guard let run = try await store.snapshot().runs.first(where: { $0.invocations.contains { $0.id == context.id } }) else { return }
            if temporary {
                try await store.update(runID: run.id) {
                    $0.waitForAgent(context.instance, reason: reason)
                }
            } else {
                try await store.pauseForUnverifiedResult(
                    runID: run.id, invocationID: context.id,
                    turn: .init(nativeTurnID: context.candidate.nativeTurnID, transcriptPath: context.candidate.transcriptPath),
                    reason: reason
                )
            }
        }, inspect: inspect, verificationTimeout: verificationTimeout, synchronizeCompletion: synchronizeIngress, verifyFinalTranscript: true, prepareTranscript: { context, provider, transcript in
            let archive = try await store.snapshot()
            guard let invocation = archive.runs.lazy.flatMap(\.invocations).first(where: { $0.id == context.id }) else { throw AgentReplyMonitor.UnconfirmedSubmission() }
            let receipt = archive.pendingReceipts?[context.id]
            let turn = PluginWorkflowTurn(nativeTurnID: context.candidate.nativeTurnID, transcriptPath: context.candidate.transcriptPath)
            guard invocation.isOriginalDelivery(turn, receipt: receipt, pluginID: context.instance.pluginID) else { return }
            guard
                let proof = try await readers.delivery(for: invocation, turn: turn, instance: context.instance, receipt: receipt, provider: provider),
                try await transcript.start(at: proof) else {
                throw AgentReplyMonitor.UnconfirmedSubmission()
            }
            try await store.rememberDelivery(proof, invocationID: context.id)
        }, matchesAnswer: { event, answer in
            event.kind != .stopCandidate || event.hasPendingWork || event.corroboratesAnswer(answer)
        }, onFailure: onFailure)
    }

    func verify(_ context: AgentWorkflowTurnContext, provider: any AgentWorkflowProviding) async {
        await monitor.verify(.init(
            id: context.invocation.id,
            instance: context.instance,
            prompt: context.invocation.stepTurn?.prompt ?? context.invocation.submissionText(pluginID: context.instance.pluginID),
            candidate: context.candidate,
            hookStartedAt: context.hookStartedAt, previousStop: context.previousStop
        ), provider: provider)
    }

    func shutdown() async {
        await monitor.shutdown()
    }
}
