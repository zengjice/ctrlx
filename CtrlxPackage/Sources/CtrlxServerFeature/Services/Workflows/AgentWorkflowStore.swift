import CtrlxNetworking
import Foundation

struct AgentWorkflowObservation: Sendable {
    var pluginID: String
    var processID: Int32
    var processRuntimeID: String
    var workspacePane: WorkspacePaneIdentity
    var paneID: String
    var conversationID: String
    var displayName: String
    var workingDirectory: String
    var capabilities: AgentWorkflowCapabilities?
    var readiness: AgentWorkflowReadiness
    var capabilityIssue: String? = nil
    var inputIssue: String? = nil

    func matchesProcess(_ instance: AgentWorkflowInstance) -> Bool {
        pluginID == instance.pluginID && processID == instance.processID
            && processRuntimeID == instance.processRuntimeID
            && workspacePane.isSamePane(as: instance.workspacePane)
    }

    func instance(hostID: UUID, id: UUID) -> AgentWorkflowInstance {
        .init(
            id: id,
            hostID: hostID,
            pluginID: pluginID,
            processID: processID,
            processRuntimeID: processRuntimeID,
            workspacePane: workspacePane,
            paneID: paneID,
            conversationID: conversationID,
            displayName: displayName,
            workingDirectory: workingDirectory,
            capabilities: capabilities,
            readiness: readiness,
            capabilityIssue: capabilityIssue,
            inputIssue: inputIssue
        )
    }
}

extension AgentWorkflowObservation {
    init(_ instance: AgentWorkflowInstance) {
        self.pluginID = instance.pluginID
        self.processID = instance.processID
        self.processRuntimeID = instance.processRuntimeID
        self.workspacePane = instance.workspacePane
        self.paneID = instance.paneID
        self.conversationID = instance.conversationID
        self.displayName = instance.displayName
        self.workingDirectory = instance.workingDirectory
        self.capabilities = instance.capabilities
        self.readiness = instance.readiness
        self.capabilityIssue = instance.capabilityIssue
        self.inputIssue = instance.inputIssue
    }
}

struct AgentWorkflowContinuationFailure: Codable, Equatable, Sendable {
    let writer: AgentWorkflowInstance
    let submission: PluginWorkflowEvent
    let submittedAt: Date?
    let failure: PluginWorkflowEvent
    let failedAt: Date?

    var receipt: AgentWorkflowContinuationReceipt {
        .init(writer: writer, submission: submission, submittedAt: submittedAt, completion: failure, completedAt: failedAt)
    }
}

struct AgentWorkflowContinuationReceipt: Codable, Equatable, Sendable {
    let writer: AgentWorkflowInstance
    let submission: PluginWorkflowEvent
    let submittedAt: Date?
    var completion: PluginWorkflowEvent?
    var completedAt: Date?
    var isRetired: Bool?
    var nativeStart: AgentWorkflowTranscriptFile.SubmissionBoundary?

    func identifies(_ other: Self) -> Bool {
        writer.matchesBinding(other.writer) && submission == other.submission && submittedAt == other.submittedAt
    }
}

struct AgentWorkflowContinuationCompletion: Codable, Equatable, Sendable {
    let writer: AgentWorkflowInstance
    let event: PluginWorkflowEvent
    let startedAt: Date?
}

struct AgentWorkflowPendingReceipt: Codable, Equatable, Sendable {
    let conversationID: String
    let turn: PluginWorkflowTurn
    var submittedHookStartedAt: Date?
    var backgroundTurn: PluginWorkflowTurn?
    var completion: PluginWorkflowEvent?
    var stopBoundary: AgentWorkflowTranscriptFile.StopBoundary?
    var resumedHookStartedAt: Date?
    var completionHookStartedAt: Date?
    var needsResultRecovery: Bool?
    var continuationFailure: AgentWorkflowContinuationFailure?
    var continuations: [AgentWorkflowContinuationReceipt]?
    var continuationCompletions: [AgentWorkflowContinuationCompletion]?
    var selectedSubmission: AgentWorkflowContinuationReceipt?

    mutating func mergeContinuations(_ entries: [AgentWorkflowContinuationReceipt], completions: [AgentWorkflowContinuationCompletion]) {
        var saved = continuations ?? []
        var events = continuationCompletions ?? []
        for entry in saved + entries {
            if let completion = entry.completion {
                let event = AgentWorkflowContinuationCompletion(writer: entry.writer, event: completion, startedAt: entry.completedAt)
                if !events.contains(event) {
                    events.append(event)
                }
            }
        }
        for event in completions where !events.contains(event) {
            events.append(event)
        }
        for entry in entries where !saved.contains(where: { $0.identifies(entry) }) {
            saved.append(entry)
        }
        if saved.allSatisfy({ $0.submittedAt != nil }) {
            saved.sort { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
        }
        for index in saved.indices {
            let entry = saved[index]
            let owned = events.filter { event in
                guard
                    event.writer.matchesBinding(entry.writer),
                    AgentReplyEvidence.turn(event.event, id: entry.submission.nativeTurnID, path: entry.submission.transcriptPath) else { return false }
                let candidates = saved.indices.filter { candidate in
                    let receipt = saved[candidate]
                    guard
                        receipt.writer.matchesBinding(event.writer),
                        AgentReplyEvidence.turn(event.event, id: receipt.submission.nativeTurnID, path: receipt.submission.transcriptPath) else { return false }
                    guard let start = event.startedAt, let submittedAt = receipt.submittedAt else { return true }
                    return submittedAt < start
                }
                if
                    let latest = candidates.filter({ saved[$0].submittedAt != nil }).max(by: {
                        (saved[$0].submittedAt ?? .distantPast) < (saved[$1].submittedAt ?? .distantPast)
                    }) {
                    return latest == index
                }
                return candidates.last == index
            }
            // Failure wins within one submission regardless of hook delivery or launch order.
            let failures = owned.filter { $0.event.kind == .failed }
            let candidates = failures.isEmpty ? owned : failures
            let selected = candidates.max {
                if $0.startedAt != $1.startedAt {
                    return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
                }
                return $0.event.text < $1.event.text
            }
            if
                saved[index].completion != selected?.event || saved[index].completedAt != selected?.startedAt,
                selected?.event.kind == .failed || selected?.event.hasPendingWork == true {
                saved[index].isRetired = nil
            }
            saved[index].completion = selected?.event
            saved[index].completedAt = selected?.startedAt
        }
        continuations = saved.isEmpty ? nil : saved
        continuationCompletions = events.isEmpty ? nil : events
    }

    func completion(for turn: PluginWorkflowTurn) -> PluginWorkflowEvent? {
        guard let completion, AgentReplyEvidence.turn(completion, id: turn.nativeTurnID, path: turn.transcriptPath) else { return nil }
        return completion
    }
}

extension PluginWorkflowEvent {
    func corroboratesAnswer(_ answer: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .stopCandidate && !hasPendingWork && !candidate.isEmpty
            && candidate == answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AgentWorkflowArchive: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 11
    var schemaVersion = Self.currentSchemaVersion
    let hostID: UUID
    var definitions: [AgentWorkflowDefinition] = []
    var instances: [AgentWorkflowInstance] = []
    var runs: [AgentWorkflowRun] = []
    var attachments: [AgentWorkflowAttachment]?
    var bridgeEvidence: [AgentWorkflowBridgeEvidence]?
    var retainedRunIDs: [UUID]?
    var pendingReceipts: [UUID: AgentWorkflowPendingReceipt]?
    var earlyCompletions: [UUID: [AgentWorkflowContinuationCompletion]]?

    var instancesForNames: [AgentWorkflowInstance] {
        // Current locations win; history supplies names only for absent Agents.
        var seen = Set(instances.map(\.agentID))
        return instances + runs.reversed().flatMap(\.instances).filter { seen.insert($0.agentID).inserted }
    }

    func pendingFailure(for invocation: AgentWorkflowInvocation) -> PluginWorkflowEvent? {
        guard let receipt = pendingReceipts?[invocation.id] else { return nil }
        let turn: PluginWorkflowTurn
        if invocation.nativeTurnID == nil {
            turn = receipt.turn
        } else {
            guard let id = invocation.resultTurnID, let path = invocation.resultTranscriptPath else { return nil }
            turn = .init(nativeTurnID: id, transcriptPath: path)
        }
        guard let event = receipt.completion(for: turn), event.kind == .failed else { return nil }
        return event
    }

    func pendingFailure(in run: AgentWorkflowRun) -> PluginWorkflowEvent? {
        run.invocations.lazy.filter { $0.round == run.round }.compactMap {
            pendingFailure(for: $0) ?? pendingReceipts?[$0.id]?.continuationFailure?.failure
                ?? pendingReceipts?[$0.id]?.continuations?.first(where: { $0.completion?.kind == .failed })?.completion
        }.first
    }
}

struct AgentWorkflowCatalogChanged: LocalizedError, Sendable {
    var errorDescription: String? {
        "An Agent's conversation was confirmed during inspection. Refresh the Agent list."
    }
}

/// Owns the single-Host ledger. Each mutation writes a complete atomic snapshot
/// before exposing it; no await can interleave a check and its committed change.
/// Terminal writes happen outside this actor, after the writing intent is saved.
actor AgentWorkflowStore {
    enum SubmissionDisposition {
        case ready
        case superseded
        case deferred
    }

    private struct Submissions {
        let runID: UUID
        var conversationID: String
        var latest: PluginWorkflowTurn
        var paths: [String: String]
    }

    let fileURL: URL
    private let hostID: UUID
    private let onCompleted: @Sendable (AgentWorkflowRun) -> Void
    private var archive: AgentWorkflowArchive?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var writeAuthorizations: [UUID: AgentWorkflowWriteAuthorization] = [:]
    private var continuationAuthorizations: [UUID: (turnID: String, instance: AgentWorkflowInstance, authorization: AgentWorkflowWriteAuthorization)] = [:]
    private var submittedTurns: [UUID: Submissions] = [:]
    let attachmentUploads = HostFileUploads()
    var pendingAttachments: [UUID: PendingAttachment] = [:]
    var busyAttachmentUploads: Set<UUID> = []
    var attachmentExpiry: Task<Void, Never>?
    var attachmentUploadsClosed = false

    init(fileURL: URL, hostID: UUID, onCompleted: @escaping @Sendable (AgentWorkflowRun) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.hostID = hostID
        self.onCompleted = onCompleted
    }

    func snapshot() throws -> AgentWorkflowArchive {
        try load()
    }

    /// Called after the router has matched an authenticated peer and the exact delivery text.
    func recordPendingReceipt(_ context: AgentWorkflowTurnContext) throws -> Bool {
        var updated = try load()
        let id = context.invocation.id
        guard
            let run = updated.runs.first(where: { $0.id == context.runID }),
            let invocation = run.invocations.first(where: { $0.id == id }),
            invocation.round == run.round, invocation.nativeTurnID == nil,
            [.writing, .awaitingAcceptance, .uncertain].contains(invocation.status),
            let bound = run.instance(for: invocation), bound.matchesProcess(context.instance),
            AgentReplyEvidence.submission(context.candidate, prompt: invocation.submissionText(pluginID: bound.pluginID), acceptedTurnID: nil),
            !context.instance.conversationID.isEmpty, !context.candidate.nativeTurnID.isEmpty,
            !context.candidate.transcriptPath.isEmpty else { return false }
        var receipt = AgentWorkflowPendingReceipt(
            conversationID: context.instance.conversationID,
            turn: .init(nativeTurnID: context.candidate.nativeTurnID, transcriptPath: context.candidate.transcriptPath),
            submittedHookStartedAt: context.hookStartedAt
        )
        if let previous = updated.pendingReceipts?[id] {
            return previous.turn == receipt.turn && previous.conversationID == receipt.conversationID
        }
        let first = AgentWorkflowContinuationReceipt(writer: context.instance, submission: context.candidate, submittedAt: context.hookStartedAt)
        receipt.mergeContinuations([first], completions: updated.earlyCompletions?[id] ?? [])
        if let selected = receipt.continuations?.first {
            receipt.completion = selected.completion
            receipt.completionHookStartedAt = selected.completedAt
            receipt.backgroundTurn = selected.completion?.hasPendingWork == true ? receipt.turn : nil
        }
        receipt.continuations = nil
        updated.earlyCompletions?.removeValue(forKey: id)
        var receipts = updated.pendingReceipts ?? [:]
        receipts[id] = receipt
        updated.pendingReceipts = receipts
        try commit(updated)
        return true
    }

    enum CompletionEvidence {
        case ignored
        case recorded(previousStop: AgentWorkflowTranscriptFile.StopBoundary?)
    }

    func recordContinuationFailure(_ evidence: AgentWorkflowContinuationFailure, runID: UUID, invocationID: UUID) throws {
        var updated = try load()
        guard
            let run = updated.runs.first(where: { $0.id == runID }),
            let invocation = run.invocations.first(where: { $0.id == invocationID }),
            invocation.round == run.round, [.running, .uncertain].contains(invocation.status),
            let id = invocation.nativeTurnID, let path = invocation.nativeTranscriptPath,
            let bound = run.instance(for: invocation), bound.agentID == evidence.writer.agentID,
            bound.pluginID == evidence.writer.pluginID, bound.workspacePane.isSamePane(as: evidence.writer.workspacePane),
            evidence.submission.kind == .submitted, evidence.failure.kind == .failed,
            AgentReplyEvidence.turn(evidence.failure, id: evidence.submission.nativeTurnID, path: evidence.submission.transcriptPath) else { return }
        if let submittedAt = evidence.submittedAt, let failedAt = evidence.failedAt, failedAt <= submittedAt {
            return
        }
        var receipts = updated.pendingReceipts ?? [:]
        var receipt = receipts[invocationID] ?? .init(conversationID: bound.conversationID, turn: .init(nativeTurnID: id, transcriptPath: path))
        guard receipt.continuationFailure == nil else { return }
        if
            let resumedAt = receipt.resumedHookStartedAt,
            AgentReplyEvidence.turn(evidence.submission, id: invocation.resultTurnID, path: invocation.resultTranscriptPath) {
            guard let submittedAt = evidence.submittedAt, submittedAt >= resumedAt else { return }
        }
        receipt.continuationFailure = evidence
        receipts[invocationID] = receipt
        updated.pendingReceipts = receipts
        revokeWrites(in: run)
        try commit(updated)
    }

    func saveContinuations(_ entries: [AgentWorkflowContinuationReceipt], completions: [AgentWorkflowContinuationCompletion] = [], runID: UUID, invocationID: UUID) throws {
        guard !entries.isEmpty || !completions.isEmpty else { return }
        var updated = try load()
        guard
            let run = updated.runs.first(where: { $0.id == runID }),
            let call = run.invocations.first(where: { $0.id == invocationID }),
            [.writing, .awaitingAcceptance, .running, .uncertain].contains(call.status) else { return }
        let initial: AgentWorkflowPendingReceipt
        if let existing = updated.pendingReceipts?[invocationID] {
            initial = existing
        } else {
            guard let id = call.nativeTurnID, let path = call.nativeTranscriptPath, let bound = run.instance(for: call) else {
                var events = updated.earlyCompletions?[invocationID] ?? []
                for event in completions where !events.contains(event) {
                    events.append(event)
                }
                var early = updated.earlyCompletions ?? [:]
                early[invocationID] = events
                updated.earlyCompletions = early
                try commit(updated)
                return
            }
            initial = .init(conversationID: bound.conversationID, turn: .init(nativeTurnID: id, transcriptPath: path))
        }
        var receipt = initial
        if
            let bound = run.instance(for: call),
            let turn = call.stepTurn,
            entries.contains(where: { entry in
                guard let selected = receipt.selectedSubmission else { return !entry.writer.matchesProcess(bound) }
                return !selected.identifies(entry)
            }) {
            var selected = receipt.selectedSubmission ?? .init(
                writer: bound,
                submission: .init(kind: .submitted, nativeTurnID: turn.id, transcriptPath: turn.transcriptPath, text: turn.prompt),
                submittedAt: receipt.resumedHookStartedAt ?? (turn.id == call.nativeTurnID ? receipt.submittedHookStartedAt : nil)
            )
            selected.completion = receipt.completion(for: .init(nativeTurnID: turn.id, transcriptPath: turn.transcriptPath))
            selected.completedAt = receipt.completionHookStartedAt
            selected.isRetired = entries.allSatisfy { $0.writer.matchesProcess(bound) } ? true : nil
            if receipt.continuations?.contains(where: { $0.identifies(selected) }) != true {
                receipt.mergeContinuations([selected], completions: [])
            }
        }
        receipt.mergeContinuations(entries, completions: completions)
        var receipts = updated.pendingReceipts ?? [:]
        receipts[invocationID] = receipt
        updated.pendingReceipts = receipts
        if receipt.continuations?.contains(where: { $0.completion?.kind == .failed }) == true {
            revokeWrites(in: run)
        }
        try commit(updated)
    }

    func removeContinuations(_ entries: [AgentWorkflowContinuationReceipt], invocationID: UUID, keepingAccepted: Bool = false) throws {
        var updated = try load()
        guard var receipt = updated.pendingReceipts?[invocationID] else { return }
        let remaining = (receipt.continuations ?? []).filter { saved in
            (keepingAccepted && saved.isRetired == true) || !entries.contains(where: { $0.identifies(saved) })
        }
        receipt.continuations = remaining.isEmpty ? nil : remaining
        if let failure = receipt.continuationFailure, entries.contains(failure.receipt) {
            receipt.continuationFailure = nil
        }
        updated.pendingReceipts?[invocationID] = receipt
        try commit(updated)
    }

    func retireContinuation(
        _ entry: AgentWorkflowContinuationReceipt,
        invocationID: UUID,
        nativeEnd: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd
    ) throws {
        var archive = try load()
        guard let index = archive.pendingReceipts?[invocationID]?.continuations?.firstIndex(of: entry) else {
            throw AgentWorkflowError("The continuation changed while verifying its completion.")
        }
        try nativeEnd.validate()
        archive.pendingReceipts?[invocationID]?.continuations?[index].isRetired = true
        try commit(archive)
    }

    func rememberSubmission(_ proof: AgentWorkflowTranscriptFile.VerifiedSubmission, invocationID: UUID) throws {
        var archive = try load()
        guard
            let selected = archive.pendingReceipts?[invocationID]?.selectedSubmission,
            selected.nativeStart == nil,
            AgentReplyEvidence.turn(selected.submission, id: proof.turn.nativeTurnID, path: proof.turn.transcriptPath),
            proof.isCurrent else { return }
        archive.pendingReceipts?[invocationID]?.selectedSubmission?.nativeStart = proof.nativeStart
        try commit(archive)
    }

    func failContinuation(
        _ entry: AgentWorkflowContinuationReceipt,
        runID: UUID,
        invocationID: UUID,
        reason: String,
        nativeEnd: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?
    ) throws {
        var archive = try load()
        guard
            let runIndex = archive.runs.firstIndex(where: { $0.id == runID }),
            let invocation = archive.runs[runIndex].invocations.first(where: { $0.id == invocationID }),
            invocation.nativeTurnID != nil,
            [.running, .uncertain].contains(invocation.status),
            archive.pendingReceipts?[invocationID]?.continuations?.contains(entry) == true else {
            throw AgentWorkflowError("The continuation changed while verifying its failure.")
        }
        try nativeEnd?.validate()
        var execution = try AgentWorkflowExecution(validating: archive.runs[runIndex])
        try execution.failContinuation(
            invocationID: invocationID,
            instance: entry.writer,
            turn: .init(id: entry.submission.nativeTurnID, transcriptPath: entry.submission.transcriptPath, prompt: entry.submission.text),
            reason: reason
        )
        archive.runs[runIndex] = execution.run
        revokeWrites(in: execution.run)
        try commit(archive)
    }

    private func revokeWrites(in run: AgentWorkflowRun) {
        for call in run.invocations where call.round == run.round {
            writeAuthorizations.removeValue(forKey: call.id)?.revoke()
            continuationAuthorizations.removeValue(forKey: call.id)?.authorization.revoke()
        }
    }

    @discardableResult
    func recordCompletionEvidence(_ context: AgentWorkflowTurnContext) throws -> CompletionEvidence {
        let event = context.candidate
        guard event.kind != .submitted else { return .ignored }
        var updated = try load()
        let id = context.invocation.id
        guard
            let runIndex = updated.runs.firstIndex(where: { $0.id == context.runID }),
            let invocation = updated.runs[runIndex].invocations.first(where: { $0.id == id }),
            [.writing, .awaitingAcceptance, .uncertain, .running].contains(invocation.status) else { return .ignored }
        let run = updated.runs[runIndex]
        let turn = PluginWorkflowTurn(nativeTurnID: event.nativeTurnID, transcriptPath: event.transcriptPath)
        var receipts = updated.pendingReceipts ?? [:]
        let receipt = receipts[id]
        let savedCompletion = receipt?.completion(for: turn)
        let matchesAccepted = AgentReplyEvidence.turn(event, id: invocation.resultTurnID, path: invocation.resultTranscriptPath)
            && run.instance(for: invocation)?.matchesBinding(context.instance) == true
        guard
            matchesAccepted || (invocation.nativeTurnID == nil && receipt?.turn == turn
                && receipt?.conversationID == context.instance.conversationID) else { return .ignored }
        let previousStop = receipt?.resumedHookStartedAt == nil ? nil : receipt?.stopBoundary
        let recorded = CompletionEvidence.recorded(previousStop: previousStop)
        if let resumedAt = receipt?.resumedHookStartedAt {
            guard let hookStartedAt = context.hookStartedAt, hookStartedAt > resumedAt else { return .ignored }
        } else if
            event.kind == .stopCandidate, !event.hasPendingWork,
            receipt?.stopBoundary?.nativeRecord == true, invocation.stepTurn?.stopped == false {
            // An already-reopened ledger from an older Host has no Hook order.
            return .ignored
        }
        if event.kind != .failed, let lastHook = receipt?.completionHookStartedAt {
            guard let hook = context.hookStartedAt, hook >= lastHook else { return .ignored }
            if hook == lastHook, event != savedCompletion {
                return .ignored
            }
        }
        if savedCompletion?.kind == .failed {
            return savedCompletion == event ? recorded : .ignored
        }
        var updatedReceipt = receipt ?? .init(conversationID: context.instance.conversationID, turn: turn)
        let stopsStep = matchesAccepted && invocation.stepTurn?.stopped == false && !event.hasPendingWork
        if stopsStep {
            var execution = try AgentWorkflowExecution(validating: run)
            try execution.stopStepTurn(invocationID: id, turnID: turn.nativeTurnID)
            updated.runs[runIndex] = execution.run
        }
        updatedReceipt.backgroundTurn = event.hasPendingWork ? turn : nil
        updatedReceipt.completion = event
        updatedReceipt.completionHookStartedAt = context.hookStartedAt
        var events = updatedReceipt.continuationCompletions ?? []
        let observed = AgentWorkflowContinuationCompletion(writer: context.instance, event: event, startedAt: context.hookStartedAt)
        if !events.contains(observed) {
            events.append(observed)
        }
        updatedReceipt.continuationCompletions = events
        receipts[id] = updatedReceipt
        updated.pendingReceipts = receipts
        if event.kind == .failed, invocation.round == run.round {
            // A verified failure stops new writes across this round, even
            // while its invocation still awaits native writer inspection.
            revokeWrites(in: run)
        }
        if updatedReceipt != receipt || stopsStep {
            try commit(updated)
        }
        return recorded
    }

    func recordVerifiedAnswer(
        runID: UUID, result: AgentWorkflowResult, instance: AgentWorkflowInstance,
        nativeEnd: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?, now: Date
    ) throws {
        let archive = try load()
        let receipt = archive.pendingReceipts?[result.invocationID]
        guard receipt?.continuationFailure == nil, receipt?.continuations?.contains(where: { $0.isRetired != true }) != true else {
            throw AgentWorkflowError("A continuation failure is awaiting verification.")
        }
        try update(runID: runID) { execution in
            try nativeEnd?.validate()
            if
                let receipt, let id = result.nativeTurnID,
                let invocation = execution.run.invocations.first(where: { $0.id == result.invocationID }),
                let path = invocation.resultTranscriptPath {
                let turn = PluginWorkflowTurn(nativeTurnID: id, transcriptPath: path)
                guard receipt.backgroundTurn != turn, receipt.completion(for: turn)?.corroboratesAnswer(result.text) != false else {
                    throw AgentWorkflowError("The Agent's final reply does not match its latest completion event.")
                }
                if receipt.resumedHookStartedAt != nil, let previous = receipt.stopBoundary {
                    guard
                        receipt.completion(for: turn)?.corroboratesAnswer(result.text) == true,
                        nativeEnd?.follows(previous) == true else {
                        throw AgentWorkflowError("The Agent's final reply does not match this continuation.")
                    }
                }
            }
            if let failure = archive.pendingFailure(in: execution.run) {
                execution.pause(reason: failure.text)
            }
            try execution.succeed(result, instance: instance, now: now)
        }
    }

    func pauseForUnverifiedResult(runID: UUID, invocationID: UUID, turn: PluginWorkflowTurn, reason: String) throws {
        var updated = try load()
        guard
            let index = updated.runs.firstIndex(where: { $0.id == runID && !$0.status.isTerminal }),
            let invocation = updated.runs[index].invocations.first(where: { $0.id == invocationID }),
            invocation.status == .running,
            invocation.resultTurnID == turn.nativeTurnID, invocation.resultTranscriptPath == turn.transcriptPath,
            let instance = updated.runs[index].instance(for: invocation) else { return }
        var receipts = updated.pendingReceipts ?? [:]
        var receipt = receipts[invocationID] ?? .init(conversationID: instance.conversationID, turn: turn)
        receipt.needsResultRecovery = true
        receipts[invocationID] = receipt
        updated.pendingReceipts = receipts
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        execution.pause(reason: reason)
        updated.runs[index] = execution.run
        try commit(updated)
    }

    /// The same turn can still resume after a native question.
    func observeSubmission(
        _ submission: PluginWorkflowEvent, instance: AgentWorkflowInstance,
        verifiedTranscript: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil,
        isSuperseded: (@Sendable (PluginWorkflowTurn, Bool) async throws -> Bool?)? = nil
    ) async throws -> SubmissionDisposition {
        let turn = PluginWorkflowTurn(nativeTurnID: submission.nativeTurnID, transcriptPath: submission.transcriptPath)
        if let verifiedTranscript, verifiedTranscript.turn != turn || !verifiedTranscript.isCurrent {
            return .deferred
        }
        let runs = try load().runs
        // Historical receipts must not select the current turn of a later run.
        if
            runs.contains(where: { run in
                run.status.isTerminal && run.invocations.contains { invocation in
                    invocation.nativeTurnID == nil && [.writing, .awaitingAcceptance, .uncertain].contains(invocation.status)
                        && run.instance(for: invocation)?.matchesProcess(instance) == true
                        && AgentReplyEvidence.submission(submission, prompt: invocation.submissionText(pluginID: instance.pluginID), acceptedTurnID: nil)
                }
            }) {
            return .ready
        }
        guard
            let run = runs.first(where: { run in
                !run.status.isTerminal && run.definition.loopExit != nil
                    && run.instances.contains { $0.agentID == instance.agentID && $0.pluginID == instance.pluginID }
            }),
            let approval = run.invocations.last(where: {
                $0.nodeID == run.definition.loopExit?.source && $0.round == run.round
                    && run.instance(for: $0)?.agentID == instance.agentID
                    && [.writing, .awaitingAcceptance, .uncertain, .running].contains($0.status)
            }) else {
            guard
                let isSuperseded, runs.contains(where: { run in
                    !run.status.isTerminal && run.invocations.contains {
                        $0.round == run.round && $0.status == .running && $0.stepTurn?.completionRequested == false
                            && $0.resultTurnID != turn.nativeTurnID && run.instance(for: $0)?.matchesConversation(instance) == true
                    }
                }) else { return .ready }
            guard let newer = try await isSuperseded(turn, true) else { return .deferred }
            return newer ? .superseded : .ready
        }
        let history = submittedTurns[instance.id].flatMap { $0.runID == run.id ? $0 : nil }
        let prior = runs.lazy.flatMap { savedRun in
            savedRun.invocations.lazy.filter { invocation in
                guard
                    invocation.nativeTurnID == turn.nativeTurnID || invocation.resultTurnID == turn.nativeTurnID,
                    let writer = savedRun.instance(for: invocation), writer.agentID == instance.agentID else { return false }
                if writer.matchesConversation(instance) {
                    return true
                }
                // The initial receipt can precede a continuation in a different
                // native conversation. The original participant is still saved.
                return invocation.nativeTurnID == turn.nativeTurnID
                    && savedRun.instances.contains { $0.matchesConversation(instance) }
            }
        }.first
        let priorPath = prior.flatMap { $0.nativeTurnID == turn.nativeTurnID ? $0.nativeTranscriptPath : $0.resultTranscriptPath }
        if let path = history?.paths[turn.nativeTurnID] ?? priorPath, path != turn.transcriptPath {
            throw AgentWorkflowError("The native turn changed its transcript path.")
        }
        if verifiedTranscript == nil, let history, history.paths[turn.nativeTurnID] != nil {
            return history.conversationID == instance.conversationID && history.latest == turn ? .ready : .superseded
        }
        if let prior, prior.id != approval.id || approval.resultTurnID != turn.nativeTurnID {
            return .superseded
        }
        if
            verifiedTranscript == nil, let isSuperseded, prior == nil,
            let currentTurnID = approval.resultTurnID, currentTurnID != turn.nativeTurnID {
            guard let superseded = try await isSuperseded(turn, false) else { return .deferred }
            guard !superseded else { return .superseded }
            // The ledger and receipt cache may have advanced during the read.
            return try await observeSubmission(submission, instance: instance)
        }
        var paths = history?.paths ?? [:]
        paths[turn.nativeTurnID] = turn.transcriptPath
        submittedTurns[instance.id] = .init(runID: run.id, conversationID: instance.conversationID, latest: turn, paths: paths)
        return .ready
    }

    func loopExitTurn(invocationID: UUID) throws -> PluginWorkflowTurn {
        guard
            let invocation = try load().runs.lazy.flatMap(\.invocations).first(where: { $0.id == invocationID }),
            let turnID = invocation.resultTurnID, let path = invocation.resultTranscriptPath else {
            throw AgentWorkflowError("This step has no accepted Agent turn for loop exit.")
        }
        return .init(nativeTurnID: turnID, transcriptPath: path)
    }

    func requestLoopExit(
        runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance,
        verifiedTranscript: AgentWorkflowTranscriptFile.VerifiedSubmission, reason: String, now: Date
    ) throws -> AgentWorkflowRun {
        let turn = verifiedTranscript.turn
        let observed = submittedTurns[instance.id].flatMap { $0.runID == runID ? $0 : nil }
        return try update(runID: runID) { execution in
            guard
                verifiedTranscript.isCurrent,
                observed.map({ $0.conversationID == instance.conversationID && $0.latest == turn }) ?? true,
                let invocation = execution.run.invocations.first(where: { $0.id == invocationID }),
                invocation.resultTurnID == turn.nativeTurnID, invocation.resultTranscriptPath == turn.transcriptPath else {
                throw AgentWorkflowError("The current Agent turn does not match this workflow step. Request loop exit from the accepted workflow turn.")
            }
            try execution.requestFinish(invocationID: invocationID, instance: instance, reason: reason, now: now, exitsLoop: true)
        }
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func hasAskedQuestion(for instance: AgentWorkflowInstance) throws -> Bool {
        try load().runs.contains { $0.hasAskedQuestion(for: instance) }
    }

    /// Call only with a complete, verified process snapshot. Failed inspection
    /// must not be passed as an empty list (which means confirmed process exit).
    @discardableResult
    func reconcile(_ observations: [AgentWorkflowObservation]) throws -> [AgentWorkflowInstance] {
        let previous = try load()
        var updated = previous
        var paneIDs: Set<UUID> = []
        var processIDs: Set<Int32> = []
        for observation in observations {
            guard
                observation.processID > 1, !observation.processRuntimeID.isEmpty,
                !observation.pluginID.isEmpty, !observation.paneID.isEmpty,
                !observation.conversationID.isEmpty || CodexProcessSessionReader.supports(pluginID: observation.pluginID),
                paneIDs.insert(observation.workspacePane.paneID).inserted,
                processIDs.insert(observation.processID).inserted else {
                throw AgentWorkflowError("Cannot register ambiguous or unverified Agent processes.")
            }
        }
        updated.instances = try observations.map { observation in
            let existing = previous.instances.first { observation.matchesProcess($0) }
            // Readiness was checked against the old join key. Reinspect instead
            // of combining a confirmed conversation with that stale result.
            if observation.conversationID.isEmpty, let existing, !existing.conversationID.isEmpty {
                throw AgentWorkflowCatalogChanged()
            }
            return observation.instance(hostID: hostID, id: existing?.id ?? UUID())
        }
        for index in updated.runs.indices where !updated.runs[index].status.isTerminal && updated.runs[index].status != .paused {
            var execution = try AgentWorkflowExecution(validating: updated.runs[index])
            do { try execution.refreshBindings(instances: updated.instances) }
            catch let error as AgentWorkflowError { execution.pause(reason: error.localizedDescription) }
            updated.runs[index] = execution.run
        }
        if updated != previous {
            try commit(updated)
        }
        return updated.instances
    }

    @discardableResult
    func saveDefinition(_ definition: AgentWorkflowDefinition, expectedRevision: Int?) throws -> AgentWorkflowDefinition {
        var updated = try load()
        guard definition.hostID == hostID else { throw AgentWorkflowError("This workflow belongs to a different Host.") }
        try validateAttachments(definition.attachmentIDs, in: updated)
        let previousAttachments = updated.definitions.first { $0.id == definition.id }?.attachmentIDs ?? []
        var saved = definition
        saved.rememberTargets(from: updated.instances)
        saved.updateAgentNames(from: updated.instancesForNames)
        if let index = updated.definitions.firstIndex(where: { $0.id == definition.id }) {
            guard expectedRevision == updated.definitions[index].revision else {
                throw AgentWorkflowError("Another Viewer changed this workflow. Reload before saving.")
            }
            saved.revision = updated.definitions[index].revision + 1
            try AgentWorkflowWire.validate(saved)
            updated.definitions[index] = saved
        } else {
            guard expectedRevision == nil else { throw AgentWorkflowError("The workflow was deleted. Reload before saving.") }
            saved.revision = 1
            try AgentWorkflowWire.validate(saved)
            updated.definitions.append(saved)
        }
        try commit(updated)
        cleanUnreferencedAttachments(previousAttachments.subtracting(saved.attachmentIDs))
        return saved
    }

    func deleteDefinition(id: UUID, expectedRevision: Int) throws {
        var updated = try load()
        guard
            let index = updated.definitions.firstIndex(where: { $0.id == id }),
            updated.definitions[index].revision == expectedRevision else {
            throw AgentWorkflowError("The workflow changed. Reload before deleting.")
        }
        let removed = updated.definitions.remove(at: index)
        try commit(updated)
        cleanUnreferencedAttachments(removed.attachmentIDs)
    }

    @discardableResult
    func start(definitionID: UUID, expectedRevision: Int, requestID: UUID, now: Date, authorizationExpiresAt: Date, initialInput: AgentWorkflowInput? = nil, expectedInstances: [AgentWorkflowInstance]? = nil, retain: Bool = false) throws -> AgentWorkflowRun {
        var updated = try load()
        if let existing = updated.runs.first(where: { $0.id == requestID }) {
            guard
                existing.definition.id == definitionID, existing.definition.revision == expectedRevision,
                initialInput == nil || initialInput == existing.definition.initialInput else {
                throw AgentWorkflowError("This request ID already belongs to a different workflow start.")
            }
            return existing
        }
        guard var definition = updated.definitions.first(where: { $0.id == definitionID }), definition.revision == expectedRevision else {
            throw AgentWorkflowError("The workflow changed. Reload before starting.")
        }
        if let initialInput {
            definition.initialInput = initialInput
        }
        try AgentWorkflowWire.validate(definition)
        try validateAttachments(definition.attachmentIDs, in: updated)
        definition = definition.resolvingAgents(in: updated.instances)
        let instanceIDs = definition.agentInstanceIDs
        let conflicts = updated.runs.compactMap { run -> AgentWorkflowStartRejection.Conflict? in
            guard !run.status.isTerminal else { return nil }
            let conflictingIDs = Set(instanceIDs.compactMap { definition.instance(for: $0, in: run.instances)?.id })
            let agents = run.instances.filter { conflictingIDs.contains($0.id) }
            guard !agents.isEmpty else { return nil }
            return .init(run: .init(run), agentNames: agents.map(\.displayName))
        }
        guard conflicts.isEmpty else {
            throw AgentWorkflowStartRejection("These Agents already belong to an unfinished workflow.", conflicts: conflicts)
        }
        let instances = definition.agents.compactMap { participant in
            instanceIDs.contains(participant.id) ? definition.instance(for: participant.id, in: updated.instances) : nil
        }
        if let expectedInstances {
            guard
                instances.count == expectedInstances.count,
                instances.allSatisfy({ live in expectedInstances.contains { $0.matchesBinding(live) } }) else {
                throw AgentWorkflowStartRejection("The Agent process or conversation changed before submission. Nothing was sent.")
            }
        }
        let execution = try AgentWorkflowExecution(
            definition: definition,
            instances: instances,
            id: requestID,
            now: now,
            authorizationExpiresAt: authorizationExpiresAt
        )
        // Check Agent support after readiness so a missing capability is not
        // misreported as an unsupported image. No run has been committed yet.
        try validateStartAttachments(definition, instances: instances)
        updated.runs.append(execution.run)
        if retain {
            updated.retainedRunIDs = (updated.retainedRunIDs ?? []) + [requestID]
        }
        try commit(updated)
        return execution.run
    }

    @discardableResult
    func update(
        runID: UUID,
        expectedRevision: Int? = nil,
        _ transition: @Sendable (inout AgentWorkflowExecution) throws -> Void
    ) throws -> AgentWorkflowRun {
        var updated = try load()
        guard let index = updated.runs.firstIndex(where: { $0.id == runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        guard expectedRevision == nil || expectedRevision == updated.runs[index].revision else {
            throw AgentWorkflowError("The workflow run changed. Reload before applying this action.")
        }
        let previousStatus = updated.runs[index].status
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        try transition(&execution)
        let knownAttachments = Set((updated.attachments ?? []).map(\.id))
        guard execution.run.attachmentIDs.isSubset(of: knownAttachments) else {
            throw AgentWorkflowError("The workflow result references an attachment that was not imported.")
        }
        updated.runs[index] = execution.run
        try commit(updated)
        if previousStatus != .completed, execution.run.status == .completed {
            onCompleted(execution.run)
        }
        return execution.run
    }

    func authorizeWrite(_ invocation: AgentWorkflowInvocation, numberOfWrites: Int = 1) throws -> AgentWorkflowWriteAuthorization {
        let archive = try load()
        guard
            let run = archive.runs.first(where: { $0.id == invocation.delivery.runID }),
            run.status == .running, run.authorizationExpiresAt > Date(),
            archive.pendingFailure(in: run) == nil,
            run.invocations.contains(where: { $0.id == invocation.id && $0.status == .writing }),
            writeAuthorizations[invocation.id] == nil,
            (1...(AgentWorkflowWire.maximumAttachments + 1)).contains(numberOfWrites) else {
            throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
        }
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: run.authorizationExpiresAt, numberOfWrites: numberOfWrites)
        writeAuthorizations[invocation.id] = authorization
        return authorization
    }

    func modelSelection(for invocation: AgentWorkflowInvocation) throws -> AgentModelSelection? {
        guard
            let run = try load().runs.first(where: { $0.id == invocation.delivery.runID }),
            let stored = run.invocations.first(where: { $0.id == invocation.id }), stored.delivery == invocation.delivery,
            let node = run.definition.nodes.first(where: { $0.id == stored.nodeID }) else {
            throw AgentWorkflowError("The workflow step no longer exists.")
        }
        return node.modelSelection
    }

    func authorizeContinuation(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) throws -> AgentWorkflowWriteAuthorization? {
        let archive = try load()
        guard let currentRun = archive.runs.first(where: { $0.id == invocation.delivery.runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        if
            let current = currentRun.invocations.first(where: { $0.id == invocation.id }),
            let turnID = invocation.stepTurn?.id, current.continuationTurnID == turnID {
            return nil
        }
        guard archive.instances.contains(where: { $0.matchesBinding(instance) && $0.readiness == .ready }) else {
            throw AgentWorkflowError("The Agent is no longer ready for a continuation.")
        }
        guard let turn = invocation.stepTurn, continuationAuthorizations[invocation.id] == nil else {
            throw AgentWorkflowError("This step already has a continuation in flight.")
        }
        if let failure = archive.pendingFailure(in: currentRun) {
            throw AgentWorkflowError(failure.text)
        }
        let run = try update(runID: invocation.delivery.runID) {
            try $0.beginContinuation(invocation, instance: instance, now: Date())
        }
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: run.authorizationExpiresAt)
        continuationAuthorizations[invocation.id] = (turn.id, instance, authorization)
        return authorization
    }

    func resume(runID: UUID, expectedRevision: Int, roundLimit: Int?, now: Date) throws -> AgentWorkflowRun {
        let archive = try load()
        return try update(runID: runID, expectedRevision: expectedRevision) { execution in
            if let failure = archive.pendingFailure(in: execution.run) {
                execution.pause(reason: failure.text)
            } else {
                try execution.resume(instances: archive.instances, roundLimit: roundLimit, now: now)
            }
        }
    }

    func finishContinuation(_ invocation: AgentWorkflowInvocation, authorization: AgentWorkflowWriteAuthorization, written: Bool) throws {
        authorization.revoke()
        if continuationAuthorizations[invocation.id]?.authorization === authorization {
            continuationAuthorizations.removeValue(forKey: invocation.id)
        }
        if !written {
            try update(runID: invocation.delivery.runID) { try $0.continuationNotWritten(invocation) }
        }
    }

    func isStagingInput(for instance: AgentWorkflowInstance) throws -> Bool {
        try load().runs.contains { run in
            guard run.status == .running else { return false }
            let execution = try AgentWorkflowExecution(validating: run)
            return run.instances.contains { $0.matchesBinding(instance) || execution.canBindFirstConversation(instance) }
                && run.invocations.contains { $0.delivery.toAgentID == instance.id && $0.status == .writing && writeAuthorizations[$0.id]?.isStaging == true }
        }
    }

    func deleteRun(id: UUID, expectedRevision: Int) throws {
        var updated = try load()
        guard updated.retainedRunIDs?.contains(id) != true else {
            throw AgentWorkflowError("This execution is referenced by an Orbie task. Archive the task to hide it; its execution history is retained.")
        }
        guard let index = updated.runs.firstIndex(where: { $0.id == id }), updated.runs[index].revision == expectedRevision else {
            throw AgentWorkflowError("The workflow run changed. Reload before deleting.")
        }
        guard updated.runs[index].status.isTerminal else { throw AgentWorkflowError("End the workflow before deleting its history.") }
        let removed = updated.runs.remove(at: index)
        try commit(updated)
        cleanUnreferencedAttachments(removed.attachmentIDs)
    }

    func allowsInitialConversationBinding(for instance: AgentWorkflowInstance) throws -> Bool {
        try !load().runs.contains { run in
            !run.status.isTerminal && run.instances.contains(where: { $0.matchesProcess(instance) })
                && run.invocations.contains { $0.delivery.toAgentID == instance.id && $0.nativeTurnID != nil }
        }
    }

    /// Commit the verified first receipt and its catalog join key together.
    func accept(
        runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String,
        transcriptPath: String?, bindFirstConversation: Bool, confirmsSelectedResult: Bool = false
    ) throws {
        var updated = try load()
        guard let index = updated.runs.firstIndex(where: { $0.id == runID }) else {
            throw AgentWorkflowError("The workflow run does not exist.")
        }
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        try execution.accept(
            invocationID: invocationID, instance: instance, nativeTurnID: nativeTurnID, transcriptPath: transcriptPath,
            bindFirstConversation: bindFirstConversation, confirmsSelectedResult: confirmsSelectedResult
        )
        if
            updated.runs[index].status == .paused,
            updated.runs[index].invocations.first(where: { $0.id == invocationID })?.status == .uncertain,
            let transcriptPath {
            var receipts = updated.pendingReceipts ?? [:]
            var receipt = receipts[invocationID] ?? .init(
                conversationID: instance.conversationID, turn: .init(nativeTurnID: nativeTurnID, transcriptPath: transcriptPath)
            )
            receipt.needsResultRecovery = true
            receipts[invocationID] = receipt
            updated.pendingReceipts = receipts
        }
        updated.runs[index] = execution.run
        if
            updated.pendingReceipts?[invocationID]?.selectedSubmission == nil,
            let call = execution.run.invocations.first(where: { $0.id == invocationID }), call.resultTurnID == nativeTurnID,
            let path = transcriptPath {
            let submittedAt = updated.pendingReceipts?[invocationID]?.submittedHookStartedAt
            updated.pendingReceipts?[invocationID]?.selectedSubmission = .init(
                writer: instance,
                submission: .init(kind: .submitted, nativeTurnID: nativeTurnID, transcriptPath: path, text: call.stepTurn?.prompt ?? call.submissionText(pluginID: instance.pluginID)),
                submittedAt: submittedAt
            )
        }
        if
            bindFirstConversation, !execution.run.status.isTerminal,
            let catalog = updated.instances.firstIndex(where: { $0.matchesProcess(instance) }) {
            updated.instances[catalog].conversationID = instance.conversationID
        }
        try commit(updated)
    }

    @discardableResult
    func observeStepTurn(
        runID: UUID, invocationID: UUID, instance: AgentWorkflowInstance, turn: AgentWorkflowStepTurn,
        reopening: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil, expectedReceipt: AgentWorkflowPendingReceipt? = nil,
        hookStartedAt: Date? = nil, verifiedSubmission: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil
    ) throws -> Bool {
        var updated = try load()
        if let verifiedSubmission, !verifiedSubmission.isCurrent {
            return false
        }
        guard
            let index = updated.runs.firstIndex(where: { $0.id == runID }),
            let catalog = updated.instances.firstIndex(where: { $0.matchesProcess(instance) }) else {
            throw AgentWorkflowError("The Agent changed before its continuation could be recorded.")
        }
        var execution = try AgentWorkflowExecution(validating: updated.runs[index])
        guard let invocation = execution.run.invocations.first(where: { $0.id == invocationID }) else { return true }
        if let failure = updated.pendingReceipts?[invocationID]?.continuationFailure {
            guard
                AgentReplyEvidence.turn(failure.submission, id: turn.id, path: turn.transcriptPath),
                failure.submission.text == turn.prompt, failure.submittedAt == hookStartedAt,
                failure.writer.matchesBinding(instance) else { return false }
        }
        if let failure = updated.pendingFailure(for: invocation) {
            guard
                invocation.resultTurnID == failure.nativeTurnID,
                execution.run.instance(for: invocation)?.matchesBinding(instance) == true else { return true }
            try execution.fail(invocationID: invocationID, instance: instance, nativeTurnID: failure.nativeTurnID, reason: failure.text)
            updated.runs[index] = execution.run
            try commit(updated)
            return true
        }
        let previous = invocation.stepTurn
        let awaitingContinuation = invocation.continuationTurnID == turn.id && invocation.continuationInstance != nil
        if reopening != nil || (previous?.id == turn.id && (previous?.stopped == true || awaitingContinuation)) {
            guard previous?.id == turn.id, previous?.stopped == true || awaitingContinuation else { return true }
            guard
                let reopening, reopening.isCurrent,
                reopening.turn == PluginWorkflowTurn(nativeTurnID: turn.id, transcriptPath: turn.transcriptPath),
                reopening.afterStop != nil, updated.pendingReceipts?[invocationID] == expectedReceipt else { return false }
            if let stoppedAt = expectedReceipt?.completionHookStartedAt {
                guard let hookStartedAt else { return false }
                if hookStartedAt <= stoppedAt {
                    guard
                        expectedReceipt?.continuations?.contains(where: {
                            $0.writer.matchesBinding(instance) && $0.submission.nativeTurnID == turn.id
                                && $0.submission.text == turn.prompt && $0.submittedAt == hookStartedAt
                                && $0.completedAt == stoppedAt && $0.completion == expectedReceipt?.completion
                        }) == true else { return false }
                }
            }
        }
        try execution.observeStepTurn(
            invocationID: invocationID,
            instance: instance,
            turn: turn,
            confirmsContinuation: reopening != nil,
            allowingTerminal: updated.pendingReceipts?[invocationID]?.continuations?.contains(where: {
                $0.submission.nativeTurnID == turn.id && $0.completion?.kind == .failed
            }) == true || updated.pendingReceipts?[invocationID]?.continuationFailure != nil
        )
        if let selected = execution.run.invocations.first(where: { $0.id == invocationID })?.stepTurn, selected != previous || reopening != nil {
            var receipts = updated.pendingReceipts ?? [:]
            if let boundary = reopening?.afterStop, !selected.stopped {
                let initial = PluginWorkflowTurn(
                    nativeTurnID: invocation.nativeTurnID ?? turn.id, transcriptPath: invocation.nativeTranscriptPath ?? turn.transcriptPath
                )
                var receipt = receipts[invocationID] ?? .init(conversationID: instance.conversationID, turn: initial)
                receipt.completion = nil
                receipt.stopBoundary = boundary
                receipt.resumedHookStartedAt = hookStartedAt
                receipt.completionHookStartedAt = nil
                receipt.backgroundTurn = nil
                receipts[invocationID] = receipt
            } else if selected.id != previous?.id {
                receipts[invocationID]?.completion = nil
                receipts[invocationID]?.stopBoundary = nil
                receipts[invocationID]?.resumedHookStartedAt = nil
                receipts[invocationID]?.completionHookStartedAt = nil
                receipts[invocationID]?.backgroundTurn = nil
            }
            updated.pendingReceipts = receipts
        }
        updated.runs[index] = execution.run
        if
            let call = execution.run.invocations.first(where: { $0.id == invocationID }),
            invocation.stepTurn?.completionRequested != true,
            call.resultTurnID == turn.id, execution.run.instance(for: call)?.matchesBinding(instance) == true {
            let selected = AgentWorkflowContinuationReceipt(
                writer: instance,
                submission: .init(kind: .submitted, nativeTurnID: turn.id, transcriptPath: turn.transcriptPath, text: turn.prompt),
                submittedAt: hookStartedAt,
                nativeStart: verifiedSubmission?.nativeStart ?? reopening?.nativeStart
            )
            updated.pendingReceipts?[invocationID]?.selectedSubmission = selected
            if let queued = updated.pendingReceipts?[invocationID]?.continuations?.firstIndex(where: { $0.identifies(selected) }) {
                updated.pendingReceipts?[invocationID]?.continuations?[queued].nativeStart = selected.nativeStart
            }
        }
        updated.instances[catalog].conversationID = instance.conversationID
        try commit(updated)
        return true
    }

    func load() throws -> AgentWorkflowArchive {
        if let archive {
            return archive
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = AgentWorkflowArchive(hostID: hostID)
            archive = empty
            return empty
        }
        var loaded = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: fileURL))
        guard
            (1...AgentWorkflowArchive.currentSchemaVersion).contains(loaded.schemaVersion), loaded.hostID == hostID,
            Set(loaded.definitions.map(\.id)).count == loaded.definitions.count,
            Set(loaded.runs.map(\.id)).count == loaded.runs.count,
            Set(loaded.instances.map(\.id)).count == loaded.instances.count else {
            throw AgentWorkflowError("The saved workflows belong to another Host or use an unsupported format.")
        }
        let attachments = loaded.attachments ?? []
        guard Set(attachments.map(\.id)).count == attachments.count else {
            throw AgentWorkflowError("The saved workflow attachments contain duplicate identities.")
        }
        try validateConversions(in: loaded)
        if loaded.schemaVersion < 7 {
            let known = loaded.instances + loaded.runs.flatMap(\.instances)
            for index in loaded.definitions.indices {
                loaded.definitions[index].rememberTargets(from: known)
            }
        }
        for definition in loaded.definitions {
            try definition.validate()
            guard definition.hostID == hostID else { throw AgentWorkflowError("A saved workflow belongs to another Host.") }
        }
        for index in loaded.instances.indices {
            guard loaded.instances[index].hostID == hostID else { throw AgentWorkflowError("A saved Agent belongs to another Host.") }
            loaded.instances[index].readiness = .unavailable
            loaded.instances[index].inputIssue = nil
        }
        for index in loaded.runs.indices {
            guard loaded.runs[index].definition.hostID == hostID else { throw AgentWorkflowError("A saved run belongs to another Host.") }
            if loaded.schemaVersion < 4 {
                // Agent output sharing was removed. Discard its old references,
                // preserving input images, content outputs and native turn evidence.
                for invocationIndex in loaded.runs[index].invocations.indices {
                    let invocation = loaded.runs[index].invocations[invocationIndex]
                    guard
                        loaded.runs[index].definition.nodes.first(where: { $0.id == invocation.nodeID })?.kind == .agent,
                        let result = invocation.result, !result.attachmentIDs.isEmpty else { continue }
                    loaded.runs[index].invocations[invocationIndex].result = .init(
                        id: result.id, invocationID: result.invocationID, nativeTurnID: result.nativeTurnID,
                        text: result.text, completedAt: result.completedAt
                    )
                }
            }
            var execution = try AgentWorkflowExecution(restoring: loaded.runs[index])
            for invocation in execution.run.invocations {
                guard
                    [.running, .uncertain].contains(invocation.status),
                    let turn = invocation.stepTurn, !turn.stopped,
                    let receipt = loaded.pendingReceipts?[invocation.id], receipt.stopBoundary?.nativeRecord != true,
                    let stop = receipt.completion(for: .init(nativeTurnID: turn.id, transcriptPath: turn.transcriptPath)),
                    stop.kind == .stopCandidate, !stop.hasPendingWork else { continue }
                // Older Hosts saved the Stop before marking its explicit turn stopped.
                try execution.stopStepTurn(invocationID: invocation.id, turnID: turn.id)
            }
            loaded.runs[index] = execution.run
        }
        let namingInstances = loaded.instancesForNames
        for index in loaded.definitions.indices {
            let previous = loaded.definitions[index]
            var candidate = previous
            candidate.updateAgentNames(from: namingInstances)
            if candidate != previous {
                candidate.revision += 1
            }
            // Display metadata must not make an otherwise valid archive unreadable.
            if try JSONEncoder().encode(candidate).count > AgentWorkflowWire.maximumDefinitionBytes {
                try AgentWorkflowWire.validate(previous)
                continue
            }
            try AgentWorkflowWire.validate(candidate)
            loaded.definitions[index] = candidate
        }
        if loaded.schemaVersion < AgentWorkflowArchive.currentSchemaVersion {
            let backup = fileURL.appendingPathExtension("schema-\(loaded.schemaVersion).backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: fileURL, to: backup)
            }
        }
        loaded.schemaVersion = AgentWorkflowArchive.currentSchemaVersion
        try commit(loaded)
        return loaded
    }

    func commit(_ updated: AgentWorkflowArchive) throws {
        var updated = updated
        updated.schemaVersion = AgentWorkflowArchive.currentSchemaVersion
        if let receipts = updated.pendingReceipts {
            let waiting = Set(updated.runs.flatMap { run in
                run.invocations.filter {
                    [.writing, .awaitingAcceptance, .uncertain, .running].contains($0.status)
                }.map(\.id)
            })
            let retained = receipts.filter { waiting.contains($0.key) }
            updated.pendingReceipts = retained.isEmpty ? nil : retained
        }
        if let early = updated.earlyCompletions {
            let waiting = Set(updated.runs.flatMap(\.invocations).filter {
                [.writing, .awaitingAcceptance, .uncertain, .running].contains($0.status)
            }.map(\.id))
            let retained = early.filter { waiting.contains($0.key) }
            updated.earlyCompletions = retained.isEmpty ? nil : retained
        }
        guard updated != archive else { return }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        archive = updated
        let activeInstances = Set(updated.instances.map(\.id))
        let activeRuns = Set(updated.runs.filter { !$0.status.isTerminal }.map(\.id))
        submittedTurns = submittedTurns.filter { activeInstances.contains($0.key) && activeRuns.contains($0.value.runID) }
        for observer in observers.values {
            observer.yield(())
        }
        let writable = Set(updated.runs.filter { $0.status == .running }.flatMap {
            $0.invocations.filter { $0.status == .writing }.map(\.id)
        })
        for (id, authorization) in writeAuthorizations where !writable.contains(id) {
            authorization.revoke()
            writeAuthorizations.removeValue(forKey: id)
        }
        for (id, pending) in continuationAuthorizations {
            let valid = updated.runs.contains { run in
                run.status == .running && run.instances.contains { $0.matchesBinding(pending.instance) }
                    && updated.instances.contains { $0.matchesBinding(pending.instance) && $0.readiness == .ready }
                    && run.invocations.contains {
                        $0.id == id && $0.status == .running && $0.stepTurn?.id == pending.turnID
                            && $0.stepTurn?.completionRequested == false && $0.continuationTurnID == pending.turnID
                            && $0.continuationInstance?.matchesBinding(pending.instance) == true
                    }
            }
            if !valid {
                pending.authorization.revoke()
                continuationAuthorizations.removeValue(forKey: id)
            }
        }
    }
}

extension AgentWorkflowRun {
    func hasAskedQuestion(for instance: AgentWorkflowInstance) -> Bool {
        !status.isTerminal && instances.contains { $0.matchesBinding(instance) }
            && invocations.contains {
                $0.delivery.toAgentID == instance.id && $0.hasAskedQuestion == true
                    && [.writing, .awaitingAcceptance, .running].contains($0.status)
            }
    }
}
