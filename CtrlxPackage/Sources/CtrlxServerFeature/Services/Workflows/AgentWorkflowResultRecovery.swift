import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Continue may settle a persisted receipt from native completion evidence.
/// It never manufactures a receipt or writes terminal input.
struct AgentWorkflowResultRecovery: Sendable {
    let store: AgentWorkflowStore
    let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    let provider: @Sendable (String) async -> (any AgentWorkflowProviding)?

    func recover(_ original: AgentWorkflowRun) async throws -> AgentWorkflowRun {
        guard original.status == .paused else { return original }
        var run = original
        for invocation in original.invocations where invocation.status == .uncertain {
            guard
                invocation.nativeTurnID != nil,
                let bound = original.instance(for: invocation),
                let turnID = invocation.resultTurnID, !turnID.isEmpty,
                let path = invocation.resultTranscriptPath,
                let node = original.definition.nodes.first(where: { $0.id == invocation.nodeID }),
                node.completion != .explicit || invocation.stepTurn?.completionRequested == true,
                let provider = await provider(bound.pluginID) else { continue }
            let instances = try await store.snapshot().instances
            guard
                let current = instances.first(where: { $0.matchesConversation(bound) })
                ?? instances.first(where: { $0.matchesProcess(bound) }).map({ _ in bound }) else {
                throw AgentWorkflowError("\(bound.displayName): Restore the accepted task's conversation in its Agent tab before continuing. Nothing was resent.")
            }
            let live = try await inspect(current)
            guard live.matchesBinding(current) else { throw AgentWorkflowError("The Agent changed while recovering its result.") }
            let file = try AgentWorkflowTranscriptFile(path: path, parser: provider.workflowTranscript(
                conversationID: bound.conversationID, nativeTurnID: turnID,
                prompt: invocation.stepTurn?.prompt ?? invocation.submissionText(pluginID: bound.pluginID), candidate: ""
            ))
            var outcome: AgentWorkflowTranscriptOutcome?
            while true {
                try Task.checkCancellation()
                let poll = try await file.pollRecovery()
                outcome = poll.outcome
                if outcome != nil || poll.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard let outcome else {
                continue
            }
            let verified = try await inspect(live)
            guard verified.matchesBinding(live) else { throw AgentWorkflowError("The Agent changed while recovering its result.") }
            try Task.checkCancellation()
            let timestamp = Date()
            run = try await store.update(runID: run.id, expectedRevision: run.revision) {
                switch outcome {
                case let .succeeded(text):
                    try $0.succeed(.init(invocationID: invocation.id, nativeTurnID: turnID, text: text, completedAt: timestamp), instance: verified, now: timestamp)
                case let .failed(reason):
                    try $0.fail(invocationID: invocation.id, instance: verified, nativeTurnID: turnID, reason: reason)
                }
            }
        }
        return run
    }
}
