import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Transcript polling runs independently from hook ingress and keyboard input.
/// A newer Stop candidate supersedes the earlier verification for the same turn.
actor AgentWorkflowCompletionMonitor {
    private struct Watch {
        let submissionOnly: Bool
        let token: UUID
        let task: Task<Void, Never>
    }

    private let store: AgentWorkflowStore
    private let runner: AgentWorkflowRunner
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let onFailure: @Sendable (String) -> Void
    private let verificationTimeout: Duration
    private var watches: [UUID: Watch] = [:]

    init(
        store: AgentWorkflowStore,
        runner: AgentWorkflowRunner,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.runner = runner
        self.inspect = inspect
        self.verificationTimeout = verificationTimeout
        self.onFailure = onFailure
    }

    func verify(_ context: AgentWorkflowTurnContext, provider: any AgentWorkflowProviding) {
        let id = context.invocation.id
        // A deferred receipt can arrive after its Stop was already routed.
        // Never replace final-answer verification with submission-only watching.
        if context.candidate.kind == .submitted, watches[id]?.submissionOnly == false {
            return
        }
        watches.removeValue(forKey: id)?.task.cancel()
        guard !context.candidate.hasPendingWork else { return }
        let token = UUID()
        watches[id] = Watch(submissionOnly: context.candidate.kind == .submitted, token: token, task: Task {
            await monitor(context, provider: provider, token: token)
        })
    }

    func shutdown() async {
        let tasks = watches.values.map(\.task)
        watches.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func monitor(_ context: AgentWorkflowTurnContext, provider: any AgentWorkflowProviding, token: UUID) async {
        let id = context.invocation.id
        defer {
            if watches[id]?.token == token {
                watches.removeValue(forKey: id)
            }
        }
        do {
            let submissionOnly = context.candidate.kind == .submitted
            let parser = provider.workflowTranscript(
                conversationID: context.instance.conversationID,
                nativeTurnID: context.candidate.nativeTurnID,
                prompt: context.invocation.delivery.input.text,
                candidate: submissionOnly ? "" : context.candidate.text
            )
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: verificationTimeout)
            var transcript: AgentWorkflowTranscriptFile?
            while transcript == nil {
                try Task.checkCancellation()
                do {
                    transcript = try AgentWorkflowTranscriptFile(path: context.candidate.transcriptPath, parser: parser)
                } catch let error as CocoaError where error.code == .fileNoSuchFile && submissionOnly && clock.now < deadline {
                    // Claude creates its first transcript after UserPromptSubmit.
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let file = transcript else { return }
            var inspectionDeadline: ContinuousClock.Instant?
            while watches[id]?.token == token, !Task.isCancelled {
                guard
                    let run = try await store.snapshot().runs.first(where: { $0.id == context.runID }),
                    // A verified Stop can still archive an accepted task after
                    // the workflow ends; its scheduler remains stopped.
                    !run.status.isTerminal || !submissionOnly,
                    run.invocations.contains(where: {
                        $0.id == id && ($0.status == .running || (!submissionOnly && $0.status == .uncertain))
                    }) else { return }
                if let inspectionDeadline, clock.now >= inspectionDeadline {
                    throw AgentWorkflowError("Agent process inspection did not recover in time. The task remains unverified and was not sent again.")
                }
                let live: AgentWorkflowInstance
                do {
                    live = try await inspect(context.instance)
                    inspectionDeadline = nil
                } catch let error as AgentWorkflowInspectionUnavailable {
                    try Task.checkCancellation()
                    guard watches[id]?.token == token else { return }
                    if inspectionDeadline == nil {
                        inspectionDeadline = submissionOnly ? clock.now.advanced(by: verificationTimeout) : deadline
                        try await store.update(runID: context.runID) { $0.pause(reason: error.localizedDescription) }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                guard watches[id]?.token == token, !Task.isCancelled else { return }
                guard live.matchesBinding(context.instance) else {
                    throw AgentWorkflowError("The Agent identity changed while verifying its final answer.")
                }
                let poll = try await file.poll()
                guard watches[id]?.token == token, !Task.isCancelled else { return }
                if let outcome = poll.outcome {
                    switch outcome {
                    case let .succeeded(answer):
                        // Submission evidence can fail a call, but only a Stop
                        // candidate may authorize successful handoff.
                        guard !submissionOnly else { return }
                        try await runner.succeeded(runID: context.runID, result: .init(
                            invocationID: id, nativeTurnID: context.candidate.nativeTurnID,
                            text: answer, completedAt: Date()
                        ), instance: live)
                    case let .failed(reason):
                        try await runner.failed(
                            runID: context.runID,
                            invocationID: id,
                            instance: live,
                            nativeTurnID: context.candidate.nativeTurnID,
                            reason: reason
                        )
                    }
                    return
                }
                guard submissionOnly || clock.now < deadline else {
                    throw AgentWorkflowError("The Agent's final completion could not be verified. Nothing was handed downstream.")
                }
                if poll.reachedEnd {
                    try await Task.sleep(for: submissionOnly ? .seconds(10) : .milliseconds(200))
                } else {
                    await Task.yield()
                }
            }
        } catch is CancellationError {
            // A newer native candidate or shutdown owns the next decision.
        } catch {
            guard watches[id]?.token == token else { return }
            do {
                let reason = error.localizedDescription
                try await store.update(runID: context.runID) { $0.pause(reason: reason) }
            } catch {
                onFailure("Could not save workflow verification failure: \(error.localizedDescription)")
            }
        }
    }
}
