import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// One reader follows a native turn from its receipt through its final Stop.
/// Updating a Stop candidate preserves both the file cursor and parser state.
struct AgentReplyContext: Sendable {
    let id: UUID
    let instance: AgentWorkflowInstance
    let prompt: String
    let candidate: PluginWorkflowEvent
}

struct AgentReplyState: Sendable {
    let isPending: Bool
    let instance: AgentWorkflowInstance?
}

actor AgentReplyMonitor {
    private struct Watch {
        var context: AgentReplyContext
        var revision = 0
        let token: UUID
        let task: Task<Void, Never>
    }

    private let state: @Sendable (AgentReplyContext) async throws -> AgentReplyState
    private let completed: @Sendable (AgentReplyContext, AgentWorkflowInstance, AgentWorkflowTranscriptOutcome) async throws -> Void
    private let waiting: @Sendable (AgentReplyContext, String, Bool) async throws -> Void
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let onFailure: @Sendable (String) -> Void
    private let missingRuntimeTimeout: Duration?
    private let verificationTimeout: Duration
    private var watches: [UUID: Watch] = [:]

    init(
        state: @escaping @Sendable (AgentReplyContext) async throws -> AgentReplyState,
        completed: @escaping @Sendable (AgentReplyContext, AgentWorkflowInstance, AgentWorkflowTranscriptOutcome) async throws -> Void,
        waiting: @escaping @Sendable (AgentReplyContext, String, Bool) async throws -> Void,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        missingRuntimeTimeout: Duration? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.state = state
        self.completed = completed
        self.waiting = waiting
        self.inspect = inspect
        self.verificationTimeout = verificationTimeout
        self.missingRuntimeTimeout = missingRuntimeTimeout
        self.onFailure = onFailure
    }

    func verify(_ context: AgentReplyContext, provider: any AgentWorkflowProviding) {
        let id = context.id
        if let previous = watches[id] {
            // A deferred receipt must not supersede a Stop. A changed native
            // binding cannot inherit the old reader's completion evidence.
            guard context.candidate.kind != .submitted else { return }
            if
                previous.context.instance.matchesBinding(context.instance) || previous.context.instance.matchesConversation(context.instance),
                previous.context.candidate.nativeTurnID == context.candidate.nativeTurnID,
                previous.context.candidate.transcriptPath == context.candidate.transcriptPath {
                guard previous.context.candidate != context.candidate else { return }
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

    var activeCount: Int {
        watches.count
    }

    func cancel(_ id: UUID) {
        watches.removeValue(forKey: id)?.task.cancel()
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

    private func monitor(_ initial: AgentReplyContext, provider: any AgentWorkflowProviding, token: UUID) async {
        let id = initial.id
        defer {
            if watches[id]?.token == token {
                watches.removeValue(forKey: id)
            }
        }
        do {
            let parser = provider.workflowTranscript(
                conversationID: initial.instance.conversationID,
                nativeTurnID: initial.candidate.nativeTurnID,
                prompt: initial.prompt,
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
            var missingDeadline: ContinuousClock.Instant?
            var nextInspection = clock.now
            while let watch = watches[id], watch.token == token, !Task.isCancelled {
                let context = watch.context
                let submissionOnly = context.candidate.kind == .submitted || context.candidate.hasPendingWork
                do {
                    let currentState = try await state(context)
                    guard isCurrent(id, token: token, revision: watch.revision) else { continue }
                    guard currentState.isPending else { return }
                    guard let current = currentState.instance else {
                        // Logging out or restarting does not invalidate an accepted
                        // turn. Wait for its conversation to return to the same tab.
                        if missingDeadline == nil, let missingRuntimeTimeout {
                            missingDeadline = clock.now.advanced(by: missingRuntimeTimeout)
                        }
                        if let missingDeadline, clock.now >= missingDeadline {
                            throw AgentWorkflowError("The Agent is unavailable. Check its terminal; the accepted message was not sent again.")
                        }
                        deadline = nil
                        inspectionDeadline = nil
                        nextInspection = clock.now
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    }
                    missingDeadline = nil
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
                    if clock.now >= nextInspection {
                        let live = try await inspect(current)
                        guard live.matchesBinding(current) else {
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
                        let latest = try await state(context).instance
                        guard let latest else {
                            await file.updateCandidate(context.candidate.text)
                            continue
                        }
                        let live = try await inspect(latest)
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        guard live.matchesBinding(latest) else {
                            throw AgentWorkflowError("The Agent identity changed while verifying its final answer.")
                        }
                        try await completed(context, live, outcome)
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
                    guard isCurrent(id, token: token, revision: watch.revision) else { continue }
                    if let inspectionDeadline, clock.now >= inspectionDeadline {
                        throw AgentWorkflowError("Agent process inspection did not recover in time. The task remains unverified and was not sent again.")
                    }
                    if inspectionDeadline == nil {
                        inspectionDeadline = clock.now.advanced(by: verificationTimeout)
                        try await waiting(context, error.localizedDescription, true)
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
                try await waiting(initial, reason, false)
            } catch {
                onFailure("Could not save Agent reply verification failure: \(error.localizedDescription)")
            }
        }
    }

    private func isCurrent(_ id: UUID, token: UUID, revision: Int) -> Bool {
        !Task.isCancelled && watches[id]?.token == token && watches[id]?.revision == revision
    }
}
