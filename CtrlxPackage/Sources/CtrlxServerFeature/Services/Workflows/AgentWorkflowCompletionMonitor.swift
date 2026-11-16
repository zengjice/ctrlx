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
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.monitor = AgentReplyMonitor(state: { context in
            let archive = try await store.snapshot()
            let submissionOnly = context.candidate.kind == .submitted || context.candidate.hasPendingWork
            let pending = archive.runs.contains { run in
                (!run.status.isTerminal || !submissionOnly) && run.invocations.contains {
                    $0.id == context.id && $0.resultTurnID == context.candidate.nativeTurnID
                        && ($0.status == .running || (!submissionOnly && $0.status == .uncertain))
                }
            }
            return AgentReplyState(isPending: pending, instance: archive.instances.first {
                $0.matchesBinding(context.instance) || $0.matchesConversation(context.instance)
            })
        }, completed: { context, live, outcome in
            guard let run = try await store.snapshot().runs.first(where: { $0.invocations.contains { $0.id == context.id } }) else { return }
            switch outcome {
            case let .succeeded(answer):
                try await runner.succeeded(runID: run.id, result: .init(
                    invocationID: context.id, nativeTurnID: context.candidate.nativeTurnID,
                    text: answer, completedAt: Date()
                ), instance: live)
            case let .failed(reason):
                try await runner.failed(
                    runID: run.id,
                    invocationID: context.id,
                    instance: live,
                    nativeTurnID: context.candidate.nativeTurnID,
                    reason: reason
                )
            }
        }, waiting: { context, reason, temporary in
            guard let run = try await store.snapshot().runs.first(where: { $0.invocations.contains { $0.id == context.id } }) else { return }
            try await store.update(runID: run.id) {
                if temporary {
                    $0.waitForAgent(context.instance, reason: reason)
                } else {
                    $0.pause(reason: reason)
                }
            }
        }, inspect: inspect, verificationTimeout: verificationTimeout, onFailure: onFailure)
    }

    func verify(_ context: AgentWorkflowTurnContext, provider: any AgentWorkflowProviding) async {
        await monitor.verify(.init(
            id: context.invocation.id,
            instance: context.instance,
            prompt: context.invocation.stepTurn?.prompt ?? context.invocation.submissionText(pluginID: context.instance.pluginID),
            candidate: context.candidate
        ), provider: provider)
    }

    func shutdown() async {
        await monitor.shutdown()
    }
}
