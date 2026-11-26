import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Continue reconciles saved evidence for the original delivery.
struct AgentWorkflowResultRecovery: Sendable {
    let store: AgentWorkflowStore
    let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    let provider: @Sendable (String) async -> (any AgentWorkflowProviding)?
    var synchronizeIngress: @Sendable () async throws -> Void = { }
    let readers = AgentWorkflowTranscriptReaders()
    var transcriptPath: @Sendable (AgentWorkflowInstance) async throws -> String? = { _ in nil }

    func recover(_ original: AgentWorkflowRun) async throws -> AgentWorkflowRun {
        guard original.status == .paused, !original.definition.agentInstanceIDs.isEmpty else { return original }
        try await synchronizeIngress()
        let archive = try await store.snapshot()
        var run = try archive.runAfterReceiptConfirmation(original)
        if run.hasNewFailure(since: original) {
            return run
        }
        let reconciled = run
        for invocation in reconciled.invocations {
            let receipt = archive.pendingReceipts?[invocation.id]
            guard
                receipt?.continuationFailure == nil,
                receipt?.continuations?.contains(where: { $0.isRetired != true }) != true,
                [.uncertain, .running].contains(invocation.status),
                var bound = reconciled.instance(for: invocation),
                let node = original.definition.nodes.first(where: { $0.id == invocation.nodeID }) else { continue }
            let turn: PluginWorkflowTurn
            var discovered: AgentWorkflowTranscriptFile.VerifiedSubmission?
            let needsAcceptance = invocation.nativeTurnID == nil
            if needsAcceptance {
                if let receipt {
                    bound.conversationID = receipt.conversationID
                    turn = receipt.turn
                } else {
                    guard invocation.status == .uncertain, archive.earlyCompletions?[invocation.id]?.isEmpty != false else { continue }
                    guard
                        let current = archive.instances.first(where: {
                            $0.agentID == bound.agentID && $0.pluginID == bound.pluginID && $0.workspacePane.isSamePane(as: bound.workspacePane)
                        }), !current.conversationID.isEmpty,
                        bound.conversationID.isEmpty || bound.conversationID == current.conversationID else {
                        throw AgentWorkflowError("\(bound.displayName): Restore the original task's conversation before continuing. Nothing was resent.")
                    }
                    let live = try await inspect(current)
                    guard live.matchesBinding(current) else { throw AgentWorkflowInspectionUnavailable() }
                    if let issue = live.capabilityIssue {
                        throw AgentWorkflowError(issue)
                    }
                    guard let path = try await transcriptPath(live), let plugin = await provider(live.pluginID) else {
                        throw AgentWorkflowError("\(bound.displayName): No verified native transcript is available to recover the missing submission receipt. Nothing was resent.")
                    }
                    let file = try AgentWorkflowTranscriptFile(path: path, parser: plugin.workflowTranscript(
                        conversationID: live.conversationID, nativeTurnID: "", prompt: invocation.submissionText(pluginID: live.pluginID), candidate: ""
                    ))
                    guard let proof = try await file.findSubmission(prompt: invocation.submissionText(pluginID: live.pluginID), notBefore: invocation.createdAt, path: path) else {
                        throw AgentWorkflowError("\(bound.displayName): The original task input was not found in the verified native transcript. Nothing was resent.")
                    }
                    discovered = proof
                    bound = live
                    turn = proof.turn
                }
            } else {
                guard let turnID = invocation.resultTurnID, let path = invocation.resultTranscriptPath else { continue }
                turn = .init(nativeTurnID: turnID, transcriptPath: path)
            }
            let canSucceed = node.completion != .explicit || invocation.stepTurn?.completionRequested == true
            let completion = receipt?.completion(for: turn)
            let knownFailure = completion?.kind == .failed
            guard
                !turn.nativeTurnID.isEmpty, receipt?.backgroundTurn != turn,
                invocation.status == .uncertain || receipt?.needsResultRecovery == true || knownFailure,
                canSucceed || needsAcceptance || knownFailure else { continue }
            let current: AgentWorkflowInstance
            if needsAcceptance {
                current = bound
            } else if let instance = archive.instances.first(where: { $0.matchesConversation(bound) }) {
                current = instance
            } else if archive.instances.contains(where: { $0.matchesProcess(bound) }) {
                current = bound
            } else {
                throw AgentWorkflowError("\(bound.displayName): Restore the accepted task's conversation in its Agent tab before continuing. Nothing was resent.")
            }
            let live = try await inspect(current)
            guard live.matchesBinding(current) else { throw AgentWorkflowError("The Agent changed while recovering its result.") }
            if needsAcceptance, let issue = live.capabilityIssue {
                throw AgentWorkflowError(issue)
            }
            guard
                let (outcome, nativeEnd) = try await nativeOutcome(
                    for: invocation, turn: turn, instance: live, receipt: receipt, completion: completion, discovered: discovered
                ) else { continue }
            try await synchronizeIngress()
            let verified = try await inspect(live)
            guard verified.matchesBinding(live) else { throw AgentWorkflowError("The Agent changed while recovering its result.") }
            if discovered != nil, try await transcriptPath(verified) != turn.transcriptPath {
                throw AgentWorkflowError("The Agent transcript changed while recovering its missing receipt. Try continuing again.")
            }
            try Task.checkCancellation()
            let result: AgentWorkflowTranscriptOutcome?
            if case .succeeded = outcome, !canSucceed {
                // Explicit steps can accept the delivery and wait for a completion request.
                result = nil
            } else {
                result = outcome
            }
            run = try await store.recoverResult(
                invocation: invocation, in: run, turn: turn, instance: verified,
                catalogConversation: archive.instances.first(where: { $0.matchesProcess(verified) })?.conversationID,
                completion: completion, outcome: result, nativeEnd: nativeEnd, now: Date(), discoveredSubmission: discovered
            )
            if run.hasNewFailure(since: original) {
                return run
            }
        }
        return run
    }

    private func nativeOutcome(
        for invocation: AgentWorkflowInvocation, turn: PluginWorkflowTurn, instance: AgentWorkflowInstance,
        receipt: AgentWorkflowPendingReceipt?, completion: PluginWorkflowEvent?, discovered: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil
    ) async throws -> (AgentWorkflowTranscriptOutcome, AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?)? {
        if let completion, completion.kind == .failed {
            return (.failed(completion.text), nil)
        }
        guard let provider = await provider(instance.pluginID) else { return nil }
        let candidate = completion?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = invocation.stepTurn?.prompt ?? invocation.submissionText(pluginID: instance.pluginID)
        let file: AgentWorkflowTranscriptFile
        do {
            let parser = provider.workflowTranscript(conversationID: instance.conversationID, nativeTurnID: turn.nativeTurnID, prompt: prompt, candidate: candidate ?? "")
            let proof: AgentWorkflowTranscriptFile.VerifiedSubmission?
            if discovered == nil, !parser.startMarkers.isEmpty, invocation.isOriginalDelivery(turn, receipt: receipt, pluginID: instance.pluginID) {
                guard let delivery = try await readers.delivery(for: invocation, turn: turn, instance: instance, receipt: receipt, provider: provider) else { return nil }
                proof = delivery
            } else {
                proof = nil
            }
            file = try AgentWorkflowTranscriptFile(path: turn.transcriptPath, parser: parser)
            if let proof {
                guard try await file.start(at: proof) else { return nil }
                try await store.rememberDelivery(proof, invocationID: invocation.id)
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        }
        let recovered = if let discovered {
            try await file.verifiedOutcome(for: discovered, hasStop: completion?.kind == .stopCandidate)
        } else {
            try await file.verifiedOutcome(at: turn.transcriptPath)
        }
        guard let (result, end) = recovered, let outcome = result else { return nil }
        if case let .succeeded(text) = outcome, completion?.corroboratesAnswer(text) == false {
            return nil
        }
        return (outcome, end)
    }
}

private extension AgentWorkflowRun {
    func hasNewFailure(since previous: Self) -> Bool {
        let failed = Set(previous.invocations.lazy.filter { $0.status == .failed }.map(\.id))
        return invocations.contains { $0.status == .failed && !failed.contains($0.id) }
    }
}

private extension AgentWorkflowArchive {
    func runAfterReceiptConfirmation(_ expected: AgentWorkflowRun) throws -> AgentWorkflowRun {
        let changed = AgentWorkflowError("The workflow run changed. Reload before applying this action.")
        guard
            let current = runs.first(where: { $0.id == expected.id }),
            current.controlRevision == expected.controlRevision else { throw changed }
        if current.revision == expected.revision {
            return current
        }
        var confirmed = try AgentWorkflowExecution(validating: expected)
        guard current.invocations.count == expected.invocations.count else { throw changed }
        var confirmedFailures = Set<String>()
        for (old, new) in zip(expected.invocations, current.invocations) where old != new {
            guard old.id == new.id, let writer = current.instance(for: new) else { throw changed }
            let receipt = pendingReceipts?[old.id]
            // Settling a failure removes its pending receipt. The failed call
            // already carries the verified writer, result turn and reason.
            let failure = new.status == .failed && old.status != .failed && new.round == expected.round ? new.issue : nil
            let result = new.status == .succeeded && old.status != .succeeded && new.round == expected.round ? new.result : nil
            guard new.status == .running || failure != nil || result != nil else { throw changed }
            if [.awaitingAcceptance, .uncertain].contains(old.status), old.nativeTurnID == nil || new.status == .running {
                guard let nativeTurnID = new.nativeTurnID, let path = new.nativeTranscriptPath else { throw changed }
                if old.nativeTurnID == nil, failure == nil, result == nil {
                    guard
                        let receipt,
                        receipt.conversationID == writer.conversationID,
                        receipt.turn == PluginWorkflowTurn(nativeTurnID: nativeTurnID, transcriptPath: path) else { throw changed }
                }
                let firstConversation = old.nativeTurnID == nil && expected.instance(for: old)?.conversationID != writer.conversationID
                try confirmed.accept(
                    invocationID: old.id, instance: writer, nativeTurnID: nativeTurnID,
                    transcriptPath: path, bindFirstConversation: firstConversation
                )
            }
            let recorded = confirmed.run.invocations.first { $0.id == new.id }?.stepTurn
            if let failure, let turn = new.stepTurn, recorded?.id != turn.id {
                try confirmed.failContinuation(invocationID: new.id, instance: writer, turn: .init(
                    id: turn.id, transcriptPath: turn.transcriptPath, prompt: turn.prompt
                ), reason: failure)
                confirmedFailures.insert(failure)
                continue
            }
            if let turn = new.stepTurn {
                let reopened = recorded?.stopped == true && (!turn.stopped || (receipt?.resumedHookStartedAt != nil
                        && receipt?.stopBoundary?.nativeRecord == true && recorded?.id == turn.id))
                let acceptedReminder = old.continuationInstance != nil && new.continuationInstance == nil && old.continuationTurnID == turn.id
                if reopened || acceptedReminder, recorded?.id == turn.id {
                    guard
                        receipt?.stopBoundary?.nativeRecord == true,
                        receipt?.completion == nil || turn.stopped else { throw changed }
                }
                if recorded?.id != turn.id || reopened || acceptedReminder {
                    try confirmed.observeStepTurn(invocationID: new.id, instance: writer, turn: .init(
                        id: turn.id, transcriptPath: turn.transcriptPath, prompt: turn.prompt
                    ), confirmsContinuation: acceptedReminder)
                }
                if turn.stopped, recorded?.id != turn.id || recorded?.stopped != true || reopened {
                    if failure == nil, result == nil {
                        guard
                            let stop = receipt?.completion(for: .init(nativeTurnID: turn.id, transcriptPath: turn.transcriptPath)),
                            !stop.hasPendingWork else { throw changed }
                    }
                    try confirmed.stopStepTurn(invocationID: new.id, turnID: turn.id)
                }
            }
            if let failure, let turnID = new.resultTurnID {
                try confirmed.fail(invocationID: new.id, instance: writer, nativeTurnID: turnID, reason: failure)
                confirmedFailures.insert(failure)
            }
            if let result {
                guard try confirmed.succeed(result, instance: writer, now: result.completedAt) else { throw changed }
            }
        }
        var comparable = confirmed.run
        if let issue = current.issue, confirmedFailures.contains(issue) {
            comparable.issue = issue
        }
        for (index, instance) in current.instances.enumerated() where comparable.instances.indices.contains(index) {
            comparable.instances[index].readiness = instance.readiness
        }
        comparable.revision = expected.revision
        if comparable == expected {
            guard
                current.invocations.contains(where: { call in
                    guard let receipt = pendingReceipts?[call.id] else { return false }
                    return receipt.resumedHookStartedAt != nil && receipt.stopBoundary?.nativeRecord == true
                        && receipt.completion?.kind == .stopCandidate && call.stepTurn?.stopped == true
                }) else { throw changed }
        }
        comparable.revision = current.revision
        guard comparable == current else { throw changed }
        return current
    }
}

extension AgentWorkflowStore {
    /// Check the revision and background status at the same write that settles the turn.
    func recoverResult(
        invocation: AgentWorkflowInvocation, in expected: AgentWorkflowRun, turn: PluginWorkflowTurn,
        instance: AgentWorkflowInstance, catalogConversation: String?,
        completion: PluginWorkflowEvent?, outcome: AgentWorkflowTranscriptOutcome?,
        nativeEnd: AgentWorkflowTranscriptFile.VerifiedRecoveryEnd?, now: Date,
        discoveredSubmission: AgentWorkflowTranscriptFile.VerifiedSubmission? = nil
    ) throws -> AgentWorkflowRun {
        var archive = try load()
        let changed = AgentWorkflowError("The workflow run changed. Reload before applying this action.")
        guard
            let runIndex = archive.runs.firstIndex(where: { $0.id == expected.id }),
            let index = expected.invocations.firstIndex(where: { $0.id == invocation.id }) else { throw changed }
        let current: AgentWorkflowRun
        do {
            current = try archive.runAfterReceiptConfirmation(expected)
        } catch {
            let stored = archive.runs[runIndex]
            // An identical completion of this call by the live monitor is benign.
            guard
                stored.controlRevision == expected.controlRevision,
                stored.invocations.indices.contains(index),
                case let .succeeded(text)? = outcome else { throw changed }
            let completed = stored.invocations[index]
            guard
                completed.id == invocation.id, completed.status == .succeeded, completed.result?.text == text,
                completed.resultTurnID == turn.nativeTurnID, completed.resultTranscriptPath == turn.transcriptPath,
                stored.instance(for: completed)?.matchesBinding(instance) == true else { throw changed }
            var comparable = stored
            comparable.revision = expected.revision
            comparable.invocations[index] = invocation
            guard comparable == expected else { throw changed }
            return stored
        }
        if current.hasNewFailure(since: expected) {
            return current
        }
        let invocation = current.invocations[index]
        if invocation.status == .succeeded {
            return current
        }
        if
            invocation.nativeTurnID != nil,
            invocation.resultTurnID != turn.nativeTurnID || invocation.resultTranscriptPath != turn.transcriptPath {
            return current
        }
        var receipt = archive.pendingReceipts?[invocation.id]
        if discoveredSubmission != nil, receipt != nil {
            return current
        }
        if receipt?.continuationFailure != nil || receipt?.continuations?.contains(where: { $0.isRetired != true }) == true {
            return current
        }
        try nativeEnd?.validate()
        guard receipt?.completion(for: turn) == completion else { throw changed }
        guard receipt?.backgroundTurn != turn else {
            throw AgentWorkflowError("The Agent still has background work. Wait for it to finish before continuing.")
        }
        if let previous = receipt?.stopBoundary, previous.nativeRecord == true {
            if let nativeEnd, !nativeEnd.follows(previous) {
                return current
            }
            if case .succeeded? = outcome, completion?.kind != .stopCandidate {
                return current
            }
        }
        var execution = try AgentWorkflowExecution(validating: current)
        if invocation.nativeTurnID == nil {
            if receipt == nil, let proof = discoveredSubmission {
                guard
                    proof.isCurrent, proof.turn == turn, proof.nativeStart != nil,
                    proof.submittedAt.map({ $0 >= invocation.createdAt }) == true,
                    archive.earlyCompletions?[invocation.id]?.isEmpty != false,
                    archive.instances.contains(where: { $0.matchesBinding(instance) }) else { return current }
                try execution.recoverAcceptance(invocationID: invocation.id, instance: instance, turn: turn)
                var recovered = AgentWorkflowPendingReceipt(conversationID: instance.conversationID, turn: turn)
                recovered.selectedSubmission = .init(writer: instance, submission: .init(kind: .submitted, nativeTurnID: turn.nativeTurnID, transcriptPath: turn.transcriptPath, text: invocation.submissionText(pluginID: instance.pluginID)), submittedAt: nil, nativeStart: proof.nativeStart)
                var receipts = archive.pendingReceipts ?? [:]
                receipts[invocation.id] = recovered
                archive.pendingReceipts = receipts
                receipt = recovered
            }
            guard receipt?.conversationID == instance.conversationID, receipt?.turn == turn else { throw changed }
            if let issue = instance.capabilityIssue {
                throw AgentWorkflowError(issue)
            }
            let catalog = archive.instances.firstIndex(where: { $0.workspacePane.isSamePane(as: instance.workspacePane) })
            if let catalog {
                let currentWriter = archive.instances[catalog]
                guard
                    currentWriter.matchesProcess(instance),
                    currentWriter.conversationID == catalogConversation || currentWriter.conversationID == instance.conversationID else { throw changed }
            }
            let bindFirstConversation = current.instance(for: invocation)?.conversationID != instance.conversationID
            if discoveredSubmission == nil {
                try execution.accept(
                    invocationID: invocation.id, instance: instance, nativeTurnID: turn.nativeTurnID,
                    transcriptPath: turn.transcriptPath, bindFirstConversation: bindFirstConversation
                )
            }
            if bindFirstConversation, let catalog {
                archive.instances[catalog].conversationID = instance.conversationID
            }
        }
        switch outcome {
        case let .succeeded(text)?:
            try execution.succeed(.init(invocationID: invocation.id, nativeTurnID: turn.nativeTurnID, text: text, completedAt: now), instance: instance, now: now)
        case let .failed(reason)?:
            try execution.fail(invocationID: invocation.id, instance: instance, nativeTurnID: turn.nativeTurnID, reason: reason)
        case nil:
            try execution.stopStepTurn(invocationID: invocation.id, turnID: turn.nativeTurnID)
            if let boundary = nativeEnd?.stopBoundary, execution.run.invocations[index].stepTurn?.id == turn.nativeTurnID {
                var receipts = archive.pendingReceipts ?? [:]
                var saved = receipt ?? .init(conversationID: instance.conversationID, turn: turn)
                saved.stopBoundary = boundary
                receipts[invocation.id] = saved
                archive.pendingReceipts = receipts
            }
        }
        archive.runs[runIndex] = execution.run
        try commit(archive)
        return execution.run
    }
}
