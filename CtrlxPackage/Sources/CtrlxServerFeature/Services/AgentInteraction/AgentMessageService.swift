import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Ordinary Agent messages share the workflow writer and native reply verifier.
/// No graph, node, run, step-completion command or automatic replay lives here.
actor AgentMessageService {
    let store: AgentMessageStore
    let catalog: AgentRuntimeCatalog
    private let writer: AgentInputWriter
    private let files: AgentInputFiles
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let occupied: @Sendable (AgentID) async throws -> String?
    private let provider: @Sendable (String) async -> (any AgentWorkflowProviding)?
    private let onFailure: @Sendable (String) -> Void
    private let verificationTimeout: Duration
    private var monitor: AgentReplyMonitor?
    private var nextCatalogRefresh = ContinuousClock.now
    private var events: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var acknowledgements: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        store: AgentMessageStore,
        catalog: AgentRuntimeCatalog,
        writer: AgentInputWriter,
        temporaryDirectory: URL,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        occupied: @escaping @Sendable (AgentID) async throws -> String?,
        provider: @escaping @Sendable (String) async -> (any AgentWorkflowProviding)?,
        verificationTimeout: Duration = .seconds(60),
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.catalog = catalog
        self.writer = writer
        self.files = AgentInputFiles(directory: temporaryDirectory)
        self.inspect = inspect
        self.occupied = occupied
        self.provider = provider
        self.verificationTimeout = verificationTimeout
        self.onFailure = onFailure
    }

    func start() async throws {
        monitor = AgentReplyMonitor(state: { [weak self] context in
            guard let self else { throw CancellationError() }
            return try await self.replyState(context)
        }, completed: { [store] context, live, outcome in
            try await store.update(context.id) { message in
                guard
                    message.isPending, message.instance.matchesConversation(live),
                    message.nativeEvent == context.candidate else { return }
                switch outcome {
                case let .succeeded(text): message.status = .succeeded
                    message.answer = text
                    message.issue = nil
                case let .failed(reason): message.status = .failed
                    message.issue = reason
                }
                message.completedAt = Date()
            }
        }, waiting: { [store] context, reason, temporary in
            try await store.update(context.id) { message in
                guard message.isPending else { return }
                message.issue = reason
                if !temporary {
                    message.status = .uncertain
                }
            }
        }, inspect: inspect, verificationTimeout: verificationTimeout, missingRuntimeTimeout: verificationTimeout, onFailure: onFailure)
        for message in try await store.pending() {
            // A process restart is never evidence that a saved write was unsent.
            if message.status == .pending || message.status == .writing || message.status == .awaitingAcceptance {
                try await store.update(message.id) {
                    $0.status = .uncertain
                    $0.issue = "Submission was interrupted. Check the Agent terminal; this message was not sent again."
                }
            }
            if let event = message.nativeEvent {
                await verify(message, event: event)
            }
        }
    }

    /// Refreshing a role may retry verification, never terminal submission.
    func resumePendingReplies() async throws {
        guard !stopped else { return }
        for message in try await store.pending() {
            if let event = message.nativeEvent {
                await verify(message, event: event)
            }
        }
    }

    private func replyState(_ context: AgentReplyContext) async throws -> AgentReplyState {
        let message = try await store.message(context.id)
        guard message?.isPending == true, message?.nativeEvent?.nativeTurnID == context.candidate.nativeTurnID else {
            return AgentReplyState(isPending: false, instance: nil)
        }
        // Pending replies must not depend on a visible panel or an active
        // workflow to populate the directory after startup or Agent restart.
        let refresh = ContinuousClock.now >= nextCatalogRefresh
        let instances = try await catalog.snapshot(refresh: refresh)
        if refresh {
            // Failed scans remain due so the verifier's bounded retry cannot
            // accidentally accept an old directory as a recovered inspection.
            nextCatalogRefresh = .now.advanced(by: .seconds(10))
        }
        return AgentReplyState(isPending: true, instance: instances.first {
            $0.matchesBinding(context.instance) || $0.matchesConversation(context.instance)
        })
    }

    func availability(_ agentID: AgentID) async throws -> String? {
        if let pending = try await store.pending().first(where: { $0.agentID == agentID }) {
            return pending.issue ?? "This Agent has an unfinished message. Open its terminal for questions or approvals."
        }
        return try await occupied(agentID)
    }

    func send(_ message: AgentMessage) async throws {
        guard !stopped else { throw AgentWorkflowError("Agent messaging is shutting down.") }
        if let issue = try await occupied(message.agentID) {
            throw AgentWorkflowError(issue)
        }
        try await AgentInputWriter.validate(message.prompt, instance: message.instance)
        let claim = await writer.gate.claim(paneID: message.instance.paneID)
        try await store.insert(message)
        let file: URL
        do { file = try await files.create(message.prompt) }
        catch {
            try await store.update(message.id) { $0.status = .failed
                $0.issue = error.localizedDescription
            }
            throw error
        }
        do {
            try await store.update(message.id) { $0.status = .writing }
            try await writer.write(instance: message.instance, file: file, images: [], claim: claim, authorize: { [occupied, store] in
                if let issue = try await occupied(message.agentID) {
                    throw AgentWorkflowError(issue)
                }
                return try await store.authorize(message.id)
            })
            try await store.update(message.id) {
                if $0.status == .writing {
                    $0.status = .awaitingAcceptance
                }
            }
            if try await store.message(message.id)?.status == .awaitingAcceptance {
                acknowledgements[message.id] = Task {
                    do {
                        try await Task.sleep(for: .seconds(30))
                        try await store.update(message.id) {
                            if $0.status == .awaitingAcceptance {
                                $0.status = .uncertain
                                $0.issue = "The Agent did not confirm this message. Check its terminal before sending again."
                            }
                        }
                    } catch is CancellationError {
                        // A receipt or shutdown owns the next decision.
                    } catch { onFailure(error.localizedDescription) }
                    acknowledgements.removeValue(forKey: message.id)
                }
            }
        } catch let error as AgentWorkflowInputNotWritten {
            try await store.update(message.id) { $0.status = .failed
                $0.issue = error.localizedDescription
            }
        } catch {
            try await store.update(message.id) {
                if $0.status == .writing {
                    $0.status = .uncertain
                    $0.issue = error.localizedDescription
                }
            }
        }
        do { try await files.remove(file) } catch { onFailure(error.localizedDescription) }
    }

    /// Stops watching; it cannot retract terminal bytes or terminate the Agent.
    func stopWaiting(_ id: UUID) async throws {
        try await store.update(id) {
            guard $0.isPending else { return }
            $0.status = .cancelled
            $0.issue = "Stopped waiting here. The Agent may still be running; continue in its terminal."
        }
        acknowledgements.removeValue(forKey: id)?.cancel()
    }

    func receive(_ event: PluginEvent, peer: PluginIngressPeer) async throws {
        guard !stopped, let native = event.workflow else { return }
        for message in try await store.pending() where AgentReplyEvidence.owns(event, instance: message.instance, peer: peer) {
            if native.kind == .submitted {
                guard
                    AgentReplyEvidence.submission(native, prompt: message.prompt, acceptedTurnID: message.nativeEvent?.nativeTurnID),
                    message.instance.conversationID.isEmpty || message.instance.conversationID == event.sessionID else { continue }
            } else {
                guard
                    AgentReplyEvidence.turn(native, id: message.nativeEvent?.nativeTurnID, path: message.nativeEvent?.transcriptPath),
                    message.instance.conversationID == event.sessionID else { continue }
            }
            if native.kind == .submitted, message.nativeEvent == nil {
                try await store.update(message.id) {
                    guard $0.isPending else { return }
                    $0.nativeEvent = native
                    $0.instance.conversationID = event.sessionID
                }
            }
            let previous = events[message.id]?.task
            let token = UUID()
            events[message.id] = (token, Task {
                await previous?.value
                await accept(message.id, event: event, native: native)
                if events[message.id]?.token == token {
                    events.removeValue(forKey: message.id)
                }
            })
        }
    }

    private func accept(_ id: UUID, event: PluginEvent, native: PluginWorkflowEvent) async {
        do {
            guard var message = try await store.message(id), message.isPending else { return }
            var observed = message.instance
            observed.conversationID = event.sessionID
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            while true {
                do {
                    let live = try await inspect(observed)
                    guard live.matchesBinding(observed), live.capabilityIssue == nil else { return }
                    observed = live
                    break
                } catch is AgentWorkflowInspectionUnavailable where clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            let verified = observed
            try await store.update(id) { saved in
                guard saved.isPending else { return }
                if native.kind == .submitted {
                    guard saved.nativeEvent == nil || saved.nativeEvent?.nativeTurnID == native.nativeTurnID else { return }
                    saved.instance = verified
                    if saved.nativeEvent?.kind != .stopCandidate {
                        saved.nativeEvent = native
                    }
                    saved.status = .running
                    saved.issue = nil
                } else if saved.nativeEvent?.nativeTurnID == native.nativeTurnID {
                    saved.nativeEvent = native
                }
            }
            acknowledgements.removeValue(forKey: id)?.cancel()
            await catalog.confirm(verified)
            guard let current = try await store.message(id), current.isPending, let evidence = current.nativeEvent else { return }
            message = current
            await verify(message, event: evidence)
        } catch is CancellationError {
            // The saved request remains available for reconciliation after restart.
        } catch {
            do { try await store.update(id) {
                if $0.isPending {
                    $0.status = .uncertain
                    $0.issue = error.localizedDescription
                }
            } } catch { onFailure(error.localizedDescription) }
        }
    }

    private func verify(_ message: AgentMessage, event: PluginWorkflowEvent) async {
        if event.kind == .failed {
            do {
                try await store.update(message.id) {
                    guard $0.isPending, $0.nativeEvent == event else { return }
                    $0.status = .failed
                    $0.issue = event.text
                    $0.completedAt = Date()
                }
                acknowledgements.removeValue(forKey: message.id)?.cancel()
                await monitor?.cancel(message.id)
            } catch { onFailure(error.localizedDescription) }
            return
        }
        guard let provider = await provider(message.instance.pluginID) else { return }
        await monitor?.verify(.init(id: message.id, instance: message.instance, prompt: message.prompt, candidate: event), provider: provider)
    }

    func observationCounts() async -> (receipts: Int, acknowledgements: Int, transcripts: Int) {
        (events.count, acknowledgements.count, await monitor?.activeCount ?? 0)
    }

    func shutdown() async {
        stopped = true
        let work = events.values.map(\.task) + Array(acknowledgements.values)
        events.removeAll()
        acknowledgements.removeAll()
        for task in work {
            task.cancel()
        }
        for task in work {
            await task.value
        }
        await monitor?.shutdown()
    }
}
