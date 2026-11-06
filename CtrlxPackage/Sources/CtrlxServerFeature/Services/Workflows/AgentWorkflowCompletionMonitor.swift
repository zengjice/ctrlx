import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// One reader follows a native turn from its receipt through its final Stop.
/// Updating a Stop candidate preserves both the file cursor and parser state.
actor AgentWorkflowCompletionMonitor {
    private struct Watch {
        var context: AgentWorkflowTurnContext
        var revision = 0
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
        if let previous = watches[id] {
            // A deferred receipt must not supersede a Stop. A changed native
            // binding cannot inherit the old reader's completion evidence.
            guard context.candidate.kind != .submitted else { return }
            if
                previous.context.instance.matchesBinding(context.instance),
                previous.context.candidate.nativeTurnID == context.candidate.nativeTurnID,
                previous.context.candidate.transcriptPath == context.candidate.transcriptPath {
                watches[id]?.context = context
                watches[id]?.revision += 1
                return
            }
            previous.task.cancel()
        }
        let token = UUID()
        watches[id] = Watch(context: context, token: token, task: Task {
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

    private func monitor(_ initial: AgentWorkflowTurnContext, provider: any AgentWorkflowProviding, token: UUID) async {
        let id = initial.invocation.id
        defer {
            if watches[id]?.token == token {
                watches.removeValue(forKey: id)
            }
        }
        do {
            let parser = provider.workflowTranscript(
                conversationID: initial.instance.conversationID,
                nativeTurnID: initial.candidate.nativeTurnID,
                prompt: initial.invocation.stepTurn?.prompt ?? initial.invocation.submissionText(pluginID: initial.instance.pluginID),
                candidate: ""
            )
            let clock = ContinuousClock()
            let openDeadline = clock.now.advanced(by: verificationTimeout)
            var transcript: AgentWorkflowTranscriptFile?
            while transcript == nil {
                try Task.checkCancellation()
                do {
                    transcript = try AgentWorkflowTranscriptFile(path: initial.candidate.transcriptPath, parser: parser)
                } catch let error as CocoaError where error.code == .fileNoSuchFile && clock.now < openDeadline {
                    // Claude creates its first transcript after UserPromptSubmit.
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let file = transcript else { return }
            var revision = -1
            var deadline: ContinuousClock.Instant?
            var inspectionDeadline: ContinuousClock.Instant?
            var nextInspection = clock.now
            while let watch = watches[id], watch.token == token, !Task.isCancelled {
                let context = watch.context
                let submissionOnly = context.candidate.kind == .submitted || context.candidate.hasPendingWork
                let archive = try await store.snapshot()
                guard isCurrent(id, token: token, revision: watch.revision) else { continue }
                guard
                    let run = archive.runs.first(where: { $0.id == context.runID }),
                    !run.status.isTerminal || !submissionOnly,
                    run.invocations.contains(where: {
                        $0.id == id && $0.resultTurnID == context.candidate.nativeTurnID && ($0.status == .running || (!submissionOnly && $0.status == .uncertain))
                    }) else { return }
                if revision != watch.revision {
                    revision = watch.revision
                    deadline = nil
                    await file.updateCandidate(submissionOnly ? "" : context.candidate.text)
                }
                if let inspectionDeadline, clock.now >= inspectionDeadline {
                    throw AgentWorkflowError("Agent process inspection did not recover in time. The task remains unverified and was not sent again.")
                }
                // Inspect periodically while catching up, not once per MiB.
                // Completion is always checked against a fresh identity below.
                do {
                    if clock.now >= nextInspection {
                        let live = try await inspect(context.instance)
                        guard live.matchesBinding(context.instance) else {
                            throw AgentWorkflowError("The Agent identity changed while verifying its final answer.")
                        }
                        inspectionDeadline = nil
                        nextInspection = clock.now.advanced(by: .seconds(10))
                    }
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    let poll = try await file.poll()
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    if let outcome = poll.outcome {
                        if case .succeeded = outcome, submissionOnly {
                            // Keep the parser and its evidence for the Stop;
                            // transcript completion alone cannot authorize handoff.
                            continue
                        }
                        let live = try await inspect(context.instance)
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        guard live.matchesBinding(context.instance) else {
                            throw AgentWorkflowError("The Agent identity changed while verifying its final answer.")
                        }
                        switch outcome {
                        case let .succeeded(answer):
                            try await runner.succeeded(runID: context.runID, result: .init(
                                invocationID: id, nativeTurnID: context.candidate.nativeTurnID,
                                text: answer, completedAt: Date()
                            ), instance: live)
                        case let .failed(reason):
                            try await runner.failed(
                                runID: context.runID, invocationID: id, instance: live,
                                nativeTurnID: context.candidate.nativeTurnID, reason: reason
                            )
                        }
                        return
                    }
                    // Historical catch-up is not time spent waiting for native
                    // completion. Start that deadline only after reaching EOF.
                    if !submissionOnly, poll.reachedEnd, deadline == nil {
                        deadline = clock.now.advanced(by: verificationTimeout)
                    }
                    if let deadline, clock.now >= deadline {
                        throw AgentWorkflowError("The Agent's final completion could not be verified. Nothing was handed downstream.")
                    }
                    if poll.reachedEnd {
                        try await Task.sleep(for: .milliseconds(200))
                    } else {
                        await Task.yield()
                    }
                } catch let error as AgentWorkflowInspectionUnavailable {
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    if inspectionDeadline == nil {
                        inspectionDeadline = clock.now.advanced(by: verificationTimeout)
                        try await store.update(runID: context.runID) { $0.pause(reason: error.localizedDescription) }
                    }
                    nextInspection = clock.now
                    // A completed record may already have been consumed.
                    await file.updateCandidate(submissionOnly ? "" : context.candidate.text)
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        } catch is CancellationError {
            // Shutdown or a different binding owns the next decision.
        } catch {
            guard watches[id]?.token == token else { return }
            do {
                let reason = error.localizedDescription
                try await store.update(runID: initial.runID) { $0.pause(reason: reason) }
            } catch {
                onFailure("Could not save workflow verification failure: \(error.localizedDescription)")
            }
        }
    }

    private func isCurrent(_ id: UUID, token: UUID, revision: Int) -> Bool {
        !Task.isCancelled && watches[id]?.token == token && watches[id]?.revision == revision
    }
}
