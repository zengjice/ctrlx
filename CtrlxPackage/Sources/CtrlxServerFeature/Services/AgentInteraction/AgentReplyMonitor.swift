import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// One reader follows a native turn from its receipt through verified completion.
/// Updating a Stop candidate preserves both the file cursor and parser state.
struct AgentReplyContext: Sendable {
    let id: UUID
    let instance: AgentWorkflowInstance
    let prompt: String
    let candidate: PluginWorkflowEvent
    var savedActivity: [AgentTurnActivity] = []
    var savedActivitySource: AgentActivitySnapshot.Source?
    var hookStartedAt: Date?
    var previousStop: AgentWorkflowTranscriptFile.StopBoundary?

    func matchesTurn(_ other: Self) -> Bool {
        (instance.matchesBinding(other.instance) || instance.matchesConversation(other.instance))
            && candidate.nativeTurnID == other.candidate.nativeTurnID
            && candidate.transcriptPath == other.candidate.transcriptPath
    }

    func activitySource(in file: AgentWorkflowTranscriptFile.FileIdentity, entries: [AgentTurnActivity], evicted: Set<String>) -> AgentActivitySnapshot.Source {
        // A still-present tail may already have left the parser's display window.
        if
            savedActivitySource == .file(file), !entries.isEmpty, let tail = savedActivity.last?.id,
            !evicted.contains(tail), !entries.contains(where: { $0.id == tail }) {
            return .rotated
        }
        return .file(file)
    }
}

struct AgentReplyState: Sendable {
    let isPending: Bool
    let instance: AgentWorkflowInstance?
    var needsFailureActivity = false
}

struct AgentActivitySnapshot: Sendable {
    enum Source: Codable, Equatable, Sendable {
        case file(AgentWorkflowTranscriptFile.FileIdentity)
        case rotated
    }

    let entries: [AgentTurnActivity]
    let evictedActivityIDs: Set<String>
    let isComplete: Bool
    let source: Source?

    var prefersTimestamps: Bool {
        source == .rotated
    }

    func merging(with saved: [AgentTurnActivity]) -> [AgentTurnActivity] {
        AgentTurnActivity.merging(entries, into: saved.filter { !evictedActivityIDs.contains($0.id) }, preferTimestamps: prefersTimestamps)
    }
}

actor AgentReplyMonitor {
    struct UnconfirmedSubmission: LocalizedError {
        var errorDescription: String? {
            "The native transcript could not confirm this workflow submission. Nothing was handed downstream."
        }
    }

    private struct Watch {
        var context: AgentReplyContext
        var revision = 0
        var transcript: AgentWorkflowTranscriptFile?
        let token: UUID
        let provider: any AgentWorkflowProviding
        let task: Task<Void, Never>
    }

    private struct ActivityRecovery {
        let context: AgentReplyContext
        var drains: [(file: AgentWorkflowTranscriptFile, activity: AgentWorkflowTranscriptFile.ActivityDrain)] = []
        var pendingReaders: [AgentWorkflowTranscriptFile] = []
        var currentIsComplete = false

        var result: AgentActivitySnapshot {
            let activities = drains.map(\.activity)
            let evicted = activities.reduce(into: Set<String>()) { $0.formUnion($1.evictedActivityIDs) }
            // Rebuild from each file, using the latest file as the base for records without timestamps.
            let entries = activities.reversed().reduce(into: [AgentTurnActivity]()) { entries, drain in
                let retained = drain.entries.filter { !evicted.contains($0.id) }
                entries = AgentTurnActivity.merging(retained, into: entries, preferTimestamps: true)
            }
            let source: AgentActivitySnapshot.Source? = activities.count > 1 ? .rotated : activities.first.map {
                context.activitySource(in: $0.fileIdentity, entries: $0.entries, evicted: $0.evictedActivityIDs)
            }
            return .init(entries: entries, evictedActivityIDs: evicted, isComplete: currentIsComplete && pendingReaders.isEmpty, source: source)
        }

        mutating func read(_ file: AgentWorkflowTranscriptFile) async throws -> AgentWorkflowTranscriptFile.ActivityDrain {
            let index = drains.firstIndex { file.referencesSameFile(as: $0.activity) }
            let candidates = Set(context.savedActivity.map(\.id)).union(drains.flatMap { $0.activity.entries.map(\.id) })
            let drain = try await file.drainActivity(reusing: index.map { drains[$0].activity }, checking: candidates)
            if let index {
                drains[index] = (file, drain)
            } else {
                drains.append((file, drain))
            }
            return drain
        }

        mutating func checkEvictionsAcrossFiles() async throws {
            guard drains.count > 1 else { return }
            let candidates = Set(drains.flatMap { $0.activity.entries.map(\.id) })
            for index in drains.indices {
                let (file, drain) = drains[index]
                drains[index].activity = try await file.checkEvictions(in: drain, for: candidates)
            }
        }
    }

    private let state: @Sendable (AgentReplyContext) async throws -> AgentReplyState
    private let completed: @Sendable (AgentReplyContext, AgentWorkflowInstance, AgentWorkflowTranscriptOutcome, AgentActivitySnapshot, AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?) async throws -> Void
    private let waiting: @Sendable (AgentReplyContext, String, Bool) async throws -> Void
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let onFailure: @Sendable (String) -> Void
    private let missingRuntimeTimeout: Duration?
    private let verificationTimeout: Duration
    private let synchronizeRecovery: (@Sendable (UUID) async throws -> Void)?
    private let synchronizeCompletion: @Sendable () async throws -> Void
    private let prepareTranscript: (@Sendable (AgentReplyContext, any AgentWorkflowProviding, AgentWorkflowTranscriptFile) async throws -> Void)?
    private let verifyFinalTranscript: Bool
    private let matchesAnswer: @Sendable (PluginWorkflowEvent, String) -> Bool
    private let activityChanged: (@Sendable (AgentReplyContext, AgentActivitySnapshot) async throws -> AgentMessage?)?
    private var watches: [UUID: Watch] = [:]
    private var activityDrains: [UUID: ActivityRecovery] = [:]

    init(
        state: @escaping @Sendable (AgentReplyContext) async throws -> AgentReplyState,
        completed: @escaping @Sendable (AgentReplyContext, AgentWorkflowInstance, AgentWorkflowTranscriptOutcome, AgentActivitySnapshot, AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?) async throws -> Void,
        waiting: @escaping @Sendable (AgentReplyContext, String, Bool) async throws -> Void,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        verificationTimeout: Duration = .seconds(60),
        missingRuntimeTimeout: Duration? = nil,
        synchronizeRecovery: (@Sendable (UUID) async throws -> Void)? = nil,
        synchronizeCompletion: @escaping @Sendable () async throws -> Void = { },
        verifyFinalTranscript: Bool = false,
        prepareTranscript: (@Sendable (AgentReplyContext, any AgentWorkflowProviding, AgentWorkflowTranscriptFile) async throws -> Void)? = nil,
        matchesAnswer: @escaping @Sendable (PluginWorkflowEvent, String) -> Bool = { _, _ in true },
        activityChanged: (@Sendable (AgentReplyContext, AgentActivitySnapshot) async throws -> AgentMessage?)? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.state = state
        self.completed = completed
        self.waiting = waiting
        self.inspect = inspect
        self.verificationTimeout = verificationTimeout
        self.missingRuntimeTimeout = missingRuntimeTimeout
        self.synchronizeRecovery = synchronizeRecovery
        self.synchronizeCompletion = synchronizeCompletion
        self.verifyFinalTranscript = verifyFinalTranscript
        self.prepareTranscript = prepareTranscript
        self.matchesAnswer = matchesAnswer
        self.activityChanged = activityChanged
        self.onFailure = onFailure
    }

    func verify(_ context: AgentReplyContext, provider: any AgentWorkflowProviding) {
        let id = context.id
        if let previous = watches[id] {
            // A deferred receipt must not supersede a Stop. A changed native
            // binding cannot inherit the old reader's completion evidence.
            guard context.candidate.kind != .submitted else { return }
            if previous.context.matchesTurn(context) {
                if let current = previous.context.hookStartedAt, let incoming = context.hookStartedAt, incoming < current {
                    return
                }
                guard
                    previous.context.candidate != context.candidate
                    || previous.context.hookStartedAt != context.hookStartedAt else { return }
                // Only this watch publishes activity for its live reader. A
                // receipt can carry a snapshot read before the latest save.
                var context = context
                context.savedActivity = previous.context.savedActivity
                context.savedActivitySource = previous.context.savedActivitySource
                watches[id]?.context = context
                watches[id]?.revision += 1
                return
            }
            previous.task.cancel()
        }
        let token = UUID()
        watches[id] = Watch(context: context, token: token, provider: provider, task: Task {
            await monitor(context, provider: provider, token: token)
        })
    }

    var activeCount: Int {
        watches.count
    }

    func cachedActivity(for context: AgentReplyContext) -> AgentActivitySnapshot? {
        activityRecovery(for: context)?.result
    }

    private func activityRecovery(for context: AgentReplyContext) -> ActivityRecovery? {
        activityDrains[context.id].flatMap { $0.context.matchesTurn(context) ? $0 : nil }
    }

    func finishActivity(_ context: AgentReplyContext, provider: (any AgentWorkflowProviding)?) async throws -> AgentActivitySnapshot? {
        let watch = watches.removeValue(forKey: context.id)
        // Recovery may be awaiting this receipt. Cancel without joining it.
        watch?.task.cancel()
        let matchingWatch = watch.flatMap { $0.context.matchesTurn(context) ? $0 : nil }
        guard let provider = provider ?? matchingWatch?.provider else { return nil }
        var recovery = activityRecovery(for: context) ?? ActivityRecovery(context: context)
        if let transcript = matchingWatch?.transcript {
            // Opening the replacement can fail while the original descriptor is still needed.
            recovery.currentIsComplete = false
            recovery.pendingReaders.append(transcript)
            activityDrains[context.id] = recovery
        }
        let readers = recovery.pendingReaders
        var readerContext = context
        if let previous = cachedActivity(for: context) {
            readerContext.savedActivity = previous.merging(with: context.savedActivity)
        }
        let current: AgentWorkflowTranscriptFile?
        do {
            // Reopen to verify the current contents, including same-inode rewrites.
            current = try await openTranscript(readerContext, provider: provider)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            if readers.isEmpty, recovery.drains.isEmpty {
                throw error
            }
            current = nil
        } catch {
            // Preserve readable archives before reporting the replacement's open error.
            recovery.currentIsComplete = false
            for reader in readers {
                let drain = try await recovery.read(reader)
                if !drain.hasPartialRecord {
                    recovery.pendingReaders.removeAll { $0 === reader }
                }
                activityDrains[context.id] = recovery
            }
            try await recovery.checkEvictionsAcrossFiles()
            activityDrains[context.id] = recovery
            throw error
        }
        guard let file = current ?? readers.last else { return recovery.result }
        let archived = readers.filter { !$0.referencesSameFile(as: file) }
        var pendingReaders: [AgentWorkflowTranscriptFile] = []
        for reader in archived {
            let recovered = try await recovery.read(reader)
            if recovered.hasPartialRecord {
                pendingReaders.append(reader)
            }
        }
        if !archived.isEmpty {
            recovery.currentIsComplete = false
            recovery.pendingReaders = pendingReaders + [file]
            activityDrains[context.id] = recovery
            await current?.alignActivity(with: recovery.result.merging(with: context.savedActivity))
        }
        let drain = try await recovery.read(file)
        if drain.hasPartialRecord {
            pendingReaders.append(file)
        }
        recovery.currentIsComplete = false
        recovery.pendingReaders = pendingReaders
        activityDrains[context.id] = recovery
        try await recovery.checkEvictionsAcrossFiles()
        recovery.currentIsComplete = drain.isComplete
        activityDrains[context.id] = recovery
        return recovery.result
    }

    func didSaveActivity(_ context: AgentReplyContext) {
        guard
            let drain = activityDrains[context.id], drain.context.matchesTurn(context),
            drain.result.isComplete else { return }
        activityDrains.removeValue(forKey: context.id)
    }

    func shutdown() async {
        let tasks = watches.values.map(\.task)
        watches.removeAll()
        activityDrains.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func monitor(_ initial: AgentReplyContext, provider: any AgentWorkflowProviding, token: UUID) async {
        let id = initial.id
        var keepForFailure = false
        defer {
            if !keepForFailure, watches[id]?.token == token {
                watches.removeValue(forKey: id)
            }
        }
        do {
            let clock = ContinuousClock()
            let openDeadline = clock.now.advanced(by: verificationTimeout)
            var transcript: AgentWorkflowTranscriptFile?
            while transcript == nil {
                try Task.checkCancellation()
                do {
                    transcript = try await openTranscript(initial, provider: provider)
                } catch is UnconfirmedSubmission where clock.now < openDeadline {
                    try await Task.sleep(for: .milliseconds(200))
                } catch let error as CocoaError where error.code == .fileNoSuchFile && clock.now < openDeadline {
                    // Claude creates its first transcript after UserPromptSubmit.
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            guard var file = transcript, watches[id]?.token == token else { return }
            watches[id]?.transcript = file
            var revision = -1
            var deadline: ContinuousClock.Instant?
            var inspectionDeadline: ContinuousClock.Instant?
            var missingDeadline: ContinuousClock.Instant?
            var nextInspection = clock.now
            var partialEnd: (outcome: AgentWorkflowTranscriptOutcome, version: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd)?
            var publishedActivity: [AgentTurnActivity] = []
            var activityWriteFailed = false
            while let watch = watches[id], watch.token == token, !Task.isCancelled {
                let context = watch.context
                let submissionOnly = context.candidate.kind == .submitted || context.candidate.hasPendingWork
                let recoverNative = synchronizeRecovery != nil && context.candidate.kind == .submitted && !context.candidate.hasPendingWork
                do {
                    let currentState = try await state(context)
                    guard isCurrent(id, token: token, revision: watch.revision) else { continue }
                    guard currentState.isPending else {
                        // The settled failure may still be waiting for its provider.
                        keepForFailure = currentState.needsFailureActivity
                        return
                    }
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
                        partialEnd = nil
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
                        nextInspection = clock.now.advanced(by: .seconds(10))
                    }
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    let poll = if recoverNative {
                        try await file.pollRecovery()
                    } else {
                        try await file.poll()
                    }
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    let (entries, evicted) = if activityChanged != nil, poll.reachedEnd || poll.outcome != nil {
                        await file.activityWindow
                    } else {
                        ([AgentTurnActivity](), Set<String>())
                    }
                    let source = context.activitySource(in: file.fileIdentity, entries: entries, evicted: evicted)
                    let activity = AgentActivitySnapshot(entries: entries, evictedActivityIDs: evicted, isComplete: poll.outcome != nil, source: source)
                    if let activityChanged, !entries.isEmpty, entries != publishedActivity {
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        do {
                            let saved = try await activityChanged(context, activity)
                            guard watches[id]?.token == token else { continue }
                            if let saved {
                                let savedActivity = saved.activity ?? []
                                watches[id]?.context.savedActivity = savedActivity
                                watches[id]?.context.savedActivitySource = saved.activitySource
                                await file.trackSavedActivityEvictions(savedActivity)
                            }
                            publishedActivity = entries
                            activityWriteFailed = false
                        } catch {
                            if !activityWriteFailed {
                                activityWriteFailed = true
                                onFailure("Could not save Agent activity: \(error.localizedDescription)")
                            }
                        }
                    }
                    guard isCurrent(id, token: token, revision: revision) else { continue }
                    let retry = if poll.reachedEnd, let partialEnd, !partialEnd.version.isCurrent {
                        partialEnd.outcome
                    } else {
                        nil as AgentWorkflowTranscriptOutcome?
                    }
                    if var outcome = poll.outcome ?? retry {
                        partialEnd = nil
                        if case let .succeeded(answer) = outcome, !matchesAnswer(context.candidate, answer) {
                            // Later records of this turn can still corroborate the current Stop.
                            continue
                        }
                        if case .succeeded = outcome, submissionOnly, !(recoverNative && poll.reachedEnd) {
                            // Ordinary messages can recover a lost Stop only after
                            // catching up with durable native completion. Workflow
                            // handoff and explicit pending work still require Stop.
                            continue
                        }
                        if recoverNative {
                            // Native completion may precede processing of an
                            // acknowledged Stop, including its pending-work guard.
                            try await synchronizeRecovery?(id)
                            guard isCurrent(id, token: token, revision: revision) else { continue }
                        }
                        let latest = try await state(context).instance
                        guard let latest else {
                            await file.updateCandidate(context.candidate.text)
                            continue
                        }
                        var nativeEnd: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?
                        if verifyFinalTranscript {
                            // The Stop may match an earlier completion of this
                            // turn. Check the latest native outcome at EOF.
                            let path = context.candidate.transcriptPath
                            let final = if await file.hasCurrentReadRevision(at: path) {
                                file
                            } else {
                                try await openTranscript(context, provider: provider)
                            }
                            if final !== file {
                                await final.updateCandidate(submissionOnly ? "" : context.candidate.text)
                            }
                            let verified = try await final.verifiedOutcome(at: path, hasStop: !submissionOnly)
                            guard isCurrent(id, token: token, revision: revision) else { continue }
                            if let (latest, end) = verified {
                                guard let latest else {
                                    if end.hasPartialRecord {
                                        partialEnd = (outcome, end)
                                    }
                                    continue
                                }
                                if let previousStop = context.previousStop, !end.follows(previousStop) {
                                    continue
                                }
                                if case let .succeeded(answer) = latest, submissionOnly || !matchesAnswer(context.candidate, answer) {
                                    continue
                                }
                                outcome = latest
                                nativeEnd = end
                            }
                        }
                        try await synchronizeCompletion()
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        let live = try await inspect(latest)
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        guard live.matchesBinding(latest) else {
                            throw AgentWorkflowError("The Agent identity changed while verifying its final answer.")
                        }
                        if verifyFinalTranscript, nativeEnd?.isCurrent != true {
                            if deadline == nil {
                                deadline = clock.now.advanced(by: verificationTimeout)
                            }
                            if let deadline, clock.now >= deadline {
                                throw AgentWorkflowError("The Agent's final completion could not be verified. Nothing was handed downstream.")
                            }
                            await file.updateCandidate(context.candidate.text)
                            try await Task.sleep(for: .milliseconds(200))
                            continue
                        }
                        try await completed(context, live, outcome, activity, nativeEnd)
                        guard isCurrent(id, token: token, revision: revision) else { continue }
                        return
                    }
                    inspectionDeadline = nil
                    // Historical catch-up is not time spent waiting for native
                    // completion. Start that deadline only after reaching EOF.
                    if !submissionOnly, poll.reachedEnd, deadline == nil {
                        deadline = clock.now.advanced(by: verificationTimeout)
                    }
                    if let deadline, clock.now >= deadline {
                        throw AgentWorkflowError("The Agent's final completion could not be verified. Nothing was handed downstream.")
                    }
                    if poll.reachedEnd {
                        if verifyFinalTranscript, !file.stillAtPath(context.candidate.transcriptPath) {
                            do {
                                let replacement = try await openTranscript(context, provider: provider)
                                file = replacement
                                watches[id]?.transcript = replacement
                                await replacement.updateCandidate(submissionOnly ? "" : context.candidate.text)
                                continue
                            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                                // A new file may be briefly absent during rotation.
                            }
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    } else {
                        await Task.yield()
                    }
                } catch is UnconfirmedSubmission {
                    guard isCurrent(id, token: token, revision: watch.revision) else { continue }
                    if deadline == nil {
                        deadline = clock.now.advanced(by: verificationTimeout)
                    }
                    if let deadline, clock.now >= deadline {
                        throw UnconfirmedSubmission()
                    }
                    await file.updateCandidate(submissionOnly ? "" : context.candidate.text)
                    try await Task.sleep(for: .milliseconds(200))
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
            guard let watch = watches[id], watch.token == token else { return }
            do {
                let reason = error.localizedDescription
                try await waiting(watch.context, reason, false)
            } catch {
                onFailure("Could not save Agent reply verification failure: \(error.localizedDescription)")
            }
        }
    }

    private func openTranscript(_ context: AgentReplyContext, provider: any AgentWorkflowProviding) async throws -> AgentWorkflowTranscriptFile {
        var parser = provider.workflowTranscript(
            conversationID: context.instance.conversationID,
            nativeTurnID: context.candidate.nativeTurnID,
            prompt: context.prompt,
            candidate: ""
        )
        if activityChanged != nil {
            parser.captureActivity(aligningWith: context.savedActivity)
        }
        let file = try AgentWorkflowTranscriptFile(path: context.candidate.transcriptPath, parser: parser)
        if let prepareTranscript, !parser.startMarkers.isEmpty {
            try await prepareTranscript(context, provider, file)
        }
        return file
    }

    private func isCurrent(_ id: UUID, token: UUID, revision: Int) -> Bool {
        !Task.isCancelled && watches[id]?.token == token && watches[id]?.revision == revision
    }
}
