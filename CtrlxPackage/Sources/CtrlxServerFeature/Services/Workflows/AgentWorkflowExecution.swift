import CtrlxNetworking
import Foundation

/// Pure transitions. The Host runner persists a changed value before performing
/// its terminal side effect; plugin adapters supply verified native turn events.
struct AgentWorkflowExecution: Sendable {
    private(set) var run: AgentWorkflowRun

    init(
        definition: AgentWorkflowDefinition,
        instances: [AgentWorkflowInstance],
        id: UUID = UUID(),
        now: Date,
        authorizationExpiresAt: Date
    ) throws {
        try definition.validate()
        var definition = definition.resolvingAgents(in: instances)
        definition.rememberTargets(from: instances)
        try definition.validate()
        guard authorizationExpiresAt > now else { throw AgentWorkflowError("The workflow authorization has expired.") }
        guard
            instances.count == definition.agentInstanceIDs.count,
            Set(instances.map(\.agentID)).count == instances.count,
            definition.agentInstanceIDs.allSatisfy({ definition.instance(for: $0, in: instances) != nil }) else {
            throw AgentWorkflowStartRejection("A participating Agent is no longer available. Edit the workflow and select a live Agent.")
        }
        for instance in instances {
            guard
                instance.hostID == definition.hostID, instance.processID > 1,
                !instance.processRuntimeID.isEmpty, !instance.conversationID.isEmpty || instance.pluginID == "codex" else {
                throw AgentWorkflowStartRejection("\(instance.displayName): The Agent's process or conversation could not be verified. Edit the workflow and select a live Agent.")
            }
            if let issue = instance.capabilityIssue {
                throw AgentWorkflowStartRejection("\(instance.displayName): \(issue)")
            }
            guard let capabilities = instance.capabilities, capabilities.maximumInputBytes > 0 else {
                throw AgentWorkflowStartRejection("\(instance.displayName): Workflow support could not be confirmed. Check the Agent's CtrlX plugin and CLI version, then try again.")
            }
            let issue: String? = switch instance.readiness {
            case .ready: nil
            case .busy: "The Agent is working or preparing input. Wait for it to finish, then try again."
            case .draft: "The terminal has unsent input or an open editor. Send or clear it in the Agent tab, then try again."
            case .awaitingHuman: "The Agent has a pending question, approval, or queued input. Resolve it in the Agent tab, then try again."
            case .unavailable: "The terminal input could not be verified as ready. Open the Agent tab and wait for its input prompt, then try again."
            }
            if let issue {
                throw AgentWorkflowStartRejection("\(instance.displayName): \(issue)")
            }
        }
        self.run = AgentWorkflowRun(
            id: id,
            definition: definition,
            instances: instances,
            createdAt: now,
            authorizationExpiresAt: authorizationExpiresAt
        )
    }

    init(validating run: AgentWorkflowRun) throws {
        var run = run
        run.definition.rememberTargets(from: run.instances)
        for index in run.invocations.indices where run.invocations[index].instance == nil {
            run.invocations[index].instance = run.instances.first { $0.id == run.invocations[index].delivery.toAgentID }
        }
        try run.definition.validate()
        guard
            run.round > 0, run.roundLimit >= run.round,
            Set(run.instances.map(\.agentID)).count == run.instances.count,
            run.definition.agentInstanceIDs.allSatisfy({ run.definition.instance(for: $0, in: run.instances) != nil }),
            run.instances.count == run.definition.agentInstanceIDs.count,
            Set(run.invocations.map(\.id)).count == run.invocations.count else {
            throw AgentWorkflowError("The saved workflow has inconsistent instance or invocation records.")
        }
        var slots: [String: AgentWorkflowInvocationStatus] = [:]
        for invocation in run.invocations {
            let node = run.definition.nodes.first { $0.id == invocation.nodeID }
            let attachments = invocation.result?.attachmentIDs ?? []
            guard
                let node, invocation.round > 0, invocation.round <= run.round,
                run.definition.activeNodeIDs(round: invocation.round).contains(node.id),
                slots["\(invocation.round):\(invocation.nodeID)"].map({ $0 == .failed }) ?? true,
                invocation.delivery.invocationID == invocation.id,
                invocation.delivery.runID == run.id,
                invocation.delivery.round == invocation.round,
                node.kind == .content ? invocation.delivery.toAgentID == nil && invocation.instance == nil
                : invocation.instance.map({ $0.id == invocation.delivery.toAgentID
                        && $0.agentID == run.definition.instance(for: node.agentInstanceID, in: run.instances)?.agentID }) == true,
                attachments.count <= AgentWorkflowWire.maximumAttachments,
                Set(attachments).count == attachments.count,
                (invocation.status == .succeeded) == (invocation.result != nil),
                invocation.result.map({ $0.invocationID == invocation.id && $0.nativeTurnID == invocation.resultTurnID }) ?? true else {
                throw AgentWorkflowError("The saved workflow contains an invalid invocation.")
            }
            slots["\(invocation.round):\(invocation.nodeID)"] = invocation.status
            if let turn = invocation.stepTurn {
                guard
                    node.completion == .explicit, invocation.nativeTurnID != nil,
                    !turn.id.isEmpty, !turn.transcriptPath.isEmpty,
                    invocation.result == nil || turn.completionRequested else {
                    throw AgentWorkflowError("The saved step completion has no matching native turn.")
                }
            }
            if node.kind == .content {
                guard
                    invocation.status == .succeeded, invocation.nativeTurnID == nil, invocation.nativeTranscriptPath == nil,
                    invocation.result?.text == invocation.delivery.input.text,
                    attachments == invocation.delivery.input.attachmentIDs else {
                    throw AgentWorkflowError("The saved content output is inconsistent.")
                }
            } else if invocation.status == .succeeded {
                guard invocation.result?.nativeTurnID?.isEmpty == false, attachments.isEmpty else {
                    throw AgentWorkflowError("A saved Agent result must contain text and a verified native turn.")
                }
            }
        }
        if let finish = run.finishRequest {
            guard
                let invocation = run.invocations.first(where: { $0.id == finish.invocationID }),
                run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.allowsFinish == true else {
                throw AgentWorkflowError("The saved finish request has no authorized invocation.")
            }
        }
        self.run = run
    }

    init(restoring run: AgentWorkflowRun) throws {
        try self.init(validating: run)
        if !run.status.isTerminal {
            for index in self.run.invocations.indices {
                let invocation = self.run.invocations[index]
                if invocation.status == .running, let turn = invocation.stepTurn, !turn.completionRequested {
                    continue // Accepted multi-reply work is waiting, not an uncertain delivery.
                }
                switch self.run.invocations[index].status {
                case .writing,
                     .awaitingAcceptance,
                     .running:
                    self.run.invocations[index].status = .uncertain
                    self.run.invocations[index].issue = "Host restarted. Verify the native turn before continuing; do not resend."
                default: break
                }
            }
            self.run.status = .paused
            self.run.issue = "Host restarted. Verify Agent identities and pending tasks before continuing."
            changed()
        }
    }

    var readyNodeIDs: [UUID] {
        guard run.status == .running, run.finishRequest == nil else { return [] }
        let active = run.definition.activeNodeIDs(round: run.round)
        return run.definition.nodes.compactMap { node in
            guard active.contains(node.id), invocation(nodeID: node.id, round: run.round).map({ $0.status == .failed }) ?? true else { return nil }
            if node.id == run.definition.entryNodeID(round: run.round) {
                if run.round == 1 {
                    return node.id
                }
                guard
                    let finalID = run.definition.loop?.finalNodeID,
                    invocation(nodeID: finalID, round: run.round - 1)?.result != nil else { return nil }
                return node.id
            }
            return run.definition.upstream(of: node.id).allSatisfy {
                invocation(nodeID: $0.id, round: run.round)?.status == .succeeded
            } ? node.id : nil
        }
    }

    mutating func prepareInvocation(nodeID: UUID, now: Date) throws -> AgentWorkflowInvocation {
        try requireScheduling(now: now)
        if let existing = invocation(nodeID: nodeID, round: run.round), existing.status != .failed {
            return existing
        }
        guard
            readyNodeIDs.contains(nodeID), let node = run.definition.nodes.first(where: { $0.id == nodeID }) else {
            throw AgentWorkflowError("This node is still waiting for its upstream results.")
        }
        let invocationID = UUID()
        let upstream: [AgentWorkflowInvocation]
        if nodeID == run.definition.entryNodeID(round: run.round), run.round > 1, let finalID = run.definition.loop?.finalNodeID {
            upstream = invocation(nodeID: finalID, round: run.round - 1).map { [$0] } ?? []
        } else {
            upstream = run.definition.upstream(of: nodeID).compactMap { invocation(nodeID: $0.id, round: run.round) }
        }
        var answers: [AgentWorkflowPrompt.Answer] = []
        var sources: [AgentWorkflowSource] = []
        for source in upstream {
            guard let result = source.result, let sourceNode = run.definition.nodes.first(where: { $0.id == source.nodeID }) else {
                throw AgentWorkflowError("An upstream result is missing.")
            }
            let includesResult = source.round < run.round
                ? run.definition.loop?.includesResult == true
                : run.definition.edges.contains { $0.source == sourceNode.id && $0.target == nodeID && $0.includesResult }
            if includesResult {
                answers.append(.init(role: sourceNode.name, round: source.round, text: result.text, attachmentIDs: result.attachmentIDs, kind: sourceNode.kind))
            }
            sources.append(.init(nodeID: sourceNode.id, agentInstanceID: source.delivery.toAgentID, resultID: result.id))
        }
        // Public correlation marker, not a credential. The adapter verifies the
        // submitted prompt and native conversation before trusting an event.
        let input = AgentWorkflowPrompt.compose(
            definition: run.definition, node: node, answers: answers, invocationReference: invocationID.uuidString
        )
        guard input.attachmentIDs.count <= AgentWorkflowWire.maximumAttachments else {
            throw AgentWorkflowError("The combined input exceeds 32 attachments. Nothing was sent.")
        }
        let limit: Int
        if node.kind == .content {
            limit = AgentWorkflowWire.maximumContentBytes
        } else {
            guard let capabilities = run.definition.instance(for: node.agentInstanceID, in: run.instances)?.capabilities else {
                throw AgentWorkflowError("The Agent's input capabilities are unavailable.")
            }
            limit = capabilities.maximumInputBytes
        }
        guard input.text.utf8.count <= limit else {
            throw AgentWorkflowError("The complete input exceeds \(node.name)'s input limit. Nothing was sent.")
        }
        let delivery = AgentWorkflowDelivery(
            runID: run.id,
            round: run.round,
            invocationID: invocationID,
            toAgentID: run.definition.instance(for: node.agentInstanceID, in: run.instances)?.id,
            sources: sources,
            input: input
        )
        var created = AgentWorkflowInvocation(
            id: invocationID,
            nodeID: nodeID,
            round: run.round,
            delivery: delivery,
            createdAt: now
        )
        created.instance = run.definition.instance(for: node.agentInstanceID, in: run.instances)
        if node.kind == .content {
            created.status = .succeeded
            created.result = .init(invocationID: invocationID, nativeTurnID: nil, text: input.text, attachmentIDs: input.attachmentIDs, completedAt: now)
        }
        run.invocations.append(created)
        if node.kind == .content {
            settle(now: now)
        }
        changed()
        return created
    }

    mutating func beginWriting(invocationID: UUID, instance: AgentWorkflowInstance, now: Date) throws {
        try requireScheduling(now: now)
        let index = try index(of: invocationID)
        try validate(instance, for: run.invocations[index])
        guard run.invocations[index].status == .pending, instance.readiness == .ready else {
            throw AgentWorkflowError("The Agent is not ready, or this input has already been written.")
        }
        guard
            !run.invocations.contains(where: {
                $0.id != invocationID && run.instance(for: $0)?.agentID == instance.agentID
                    && [.writing, .awaitingAcceptance, .running, .uncertain].contains($0.status)
            }) else { throw AgentWorkflowError("Another step is still using this Agent. Resolve it before sending more input.") }
        run.invocations[index].status = .writing
        run.invocations[index].hasAskedQuestion = nil
        changed()
    }

    mutating func recordImageInput(invocationID: UUID, numbers: [Int], now: Date) throws {
        try requireScheduling(now: now)
        let index = try index(of: invocationID)
        guard
            run.invocations[index].status == .writing,
            !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }), Set(numbers).count == numbers.count,
            numbers.count == run.invocations[index].delivery.input.attachmentIDs.count else {
            throw AgentWorkflowError("The Agent did not confirm this task's native images.")
        }
        run.invocations[index].nativeImageNumbers = numbers
        changed()
    }

    mutating func didWrite(invocationID: UUID) throws {
        let index = try index(of: invocationID)
        // A native submit/finish can arrive before the terminal write returns.
        guard run.invocations[index].status == .writing else { return }
        run.invocations[index].status = .awaitingAcceptance
        changed()
    }

    mutating func didNotWrite(invocationID: UUID, reason: String) throws {
        let index = try index(of: invocationID)
        guard run.invocations[index].status == .writing else { return }
        run.invocations[index].status = run.status.isTerminal ? .cancelled : .pending
        run.invocations[index].issue = reason
        if !run.status.isTerminal {
            run.status = .paused
            run.issue = reason
        }
        changed()
    }

    mutating func writeUncertain(invocationID: UUID, reason: String) throws {
        let index = try index(of: invocationID)
        guard [.writing, .awaitingAcceptance].contains(run.invocations[index].status) else { return }
        run.invocations[index].status = .uncertain
        run.invocations[index].issue = reason
        if !run.status.isTerminal {
            run.status = .paused
            run.issue = reason
        }
        changed()
    }

    func canBindFirstConversation(_ instance: AgentWorkflowInstance, invocationID: UUID? = nil) -> Bool {
        guard
            !run.status.isTerminal, instance.pluginID == "codex", UUID(uuidString: instance.conversationID) != nil,
            let bound = run.instances.first(where: { $0.id == instance.id }),
            bound.matchesProcess(instance), !bound.matchesBinding(instance) else { return false }
        let calls = run.invocations.filter { $0.delivery.toAgentID == instance.id }
        let written = calls.filter { [.writing, .awaitingAcceptance, .uncertain].contains($0.status) }
        return written.count == 1 && (invocationID == nil || written[0].id == invocationID)
            && calls.allSatisfy { $0.nativeTurnID == nil && $0.result == nil }
    }

    mutating func accept(invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, transcriptPath: String? = nil, bindFirstConversation: Bool = false) throws {
        let index = try index(of: invocationID)
        let invocation = run.invocations[index]
        let bindsConversation = bindFirstConversation && canBindFirstConversation(instance, invocationID: invocationID)
        if !bindsConversation {
            try validate(instance, for: invocation)
        }
        guard
            !nativeTurnID.isEmpty,
            invocation.nativeTurnID == nil || invocation.nativeTurnID == nativeTurnID,
            invocation.nativeTranscriptPath == nil || transcriptPath == nil || invocation.nativeTranscriptPath == transcriptPath else {
            throw AgentWorkflowError("The native turn does not match this workflow invocation.")
        }
        if [.running, .succeeded, .failed].contains(invocation.status) {
            if
                invocation.status == .running, invocation.resultTurnID == nativeTurnID,
                run.instance(for: invocation)?.matchesBinding(instance) != true {
                // A verified replay of this exact receipt confirms the resumed
                // writer; it does not select a different native turn.
                run.invocations[index].instance = instance
                run.invocations[index].delivery.toAgentID = instance.id
                changed()
            }
            return
        }
        guard [.writing, .awaitingAcceptance, .uncertain].contains(invocation.status) else {
            throw AgentWorkflowError("No written workflow task is awaiting this acceptance.")
        }
        if bindsConversation, let participant = run.instances.firstIndex(where: { $0.id == instance.id }) {
            run.instances[participant].conversationID = instance.conversationID
            // A live pane may have moved; keep the destination captured at delivery.
            run.invocations[index].instance?.conversationID = instance.conversationID
        }
        run.invocations[index].nativeTurnID = nativeTurnID
        run.invocations[index].nativeTranscriptPath = transcriptPath
        run.invocations[index].status = .running
        if
            run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit,
            let transcriptPath {
            run.invocations[index].stepTurn = .init(id: nativeTurnID, transcriptPath: transcriptPath, prompt: invocation.submissionText(pluginID: instance.pluginID))
        }
        run.invocations[index].issue = nil
        changed()
    }

    @discardableResult
    mutating func succeed(_ result: AgentWorkflowResult, instance: AgentWorkflowInstance, now: Date) throws -> Bool {
        let index = try index(of: result.invocationID)
        let invocation = run.invocations[index]
        try validate(instance, for: invocation)
        guard let nativeTurnID = result.nativeTurnID, !nativeTurnID.isEmpty, invocation.resultTurnID == nativeTurnID else {
            throw AgentWorkflowError("The result has no matching accepted native turn.")
        }
        if run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit {
            guard invocation.stepTurn?.completionRequested == true else { return false }
        }
        if invocation.status == .succeeded {
            return false
        }
        // A restart makes delivery uncertain, but a persisted receipt plus a
        // verified native result can settle that same call without resending it.
        guard [.running, .uncertain].contains(invocation.status) else {
            throw AgentWorkflowError("Verify the Agent's accepted task before recording a result.")
        }
        guard result.attachmentIDs.isEmpty else {
            throw AgentWorkflowError("Agent results contain text only. Reference files by their workspace paths.")
        }
        run.invocations[index].status = .succeeded
        run.invocations[index].result = result
        run.invocations[index].issue = nil
        settle(now: now)
        changed()
        return true
    }

    mutating func fail(invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, reason: String) throws {
        let index = try index(of: invocationID)
        try validate(instance, for: run.invocations[index])
        guard run.invocations[index].resultTurnID == nativeTurnID, !nativeTurnID.isEmpty else {
            throw AgentWorkflowError("The failure has no matching accepted native turn.")
        }
        if [.failed, .succeeded].contains(run.invocations[index].status) {
            return
        }
        guard [.running, .uncertain].contains(run.invocations[index].status) else {
            throw AgentWorkflowError("The failed task has not been verified.")
        }
        run.invocations[index].status = .failed
        run.invocations[index].issue = reason
        if !run.status.isTerminal {
            run.status = .paused
            run.issue = reason
        }
        changed()
    }

    /// Human turns are observed, not treated as new workflow deliveries.
    mutating func observeStepTurn(invocationID: UUID, instance: AgentWorkflowInstance, turn: AgentWorkflowStepTurn) throws {
        let index = try index(of: invocationID)
        let invocation = run.invocations[index]
        guard
            let bound = run.instance(for: invocation),
            bound.matchesProcess(instance) || (bound.agentID == instance.agentID && bound.pluginID == instance.pluginID) else {
            throw AgentWorkflowError("The Agent tab changed.")
        }
        guard
            !run.status.isTerminal, invocation.status == .running,
            run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit,
            invocation.nativeTurnID != nil, invocation.stepTurn?.completionRequested != true else { return }
        if invocation.stepTurn?.id == turn.id {
            guard invocation.stepTurn?.transcriptPath == turn.transcriptPath else {
                throw AgentWorkflowError("The native turn changed its transcript path.")
            }
            // An answer to an asynchronous question may continue the same turn.
            // Keep that turn's original prompt for transcript verification.
            run.invocations[index].stepTurn?.stopped = false
        } else {
            run.invocations[index].stepTurn = turn
        }
        // A verified human continuation can resume this step in the same tab.
        // Keep the original receipt, but bind the selected result turn to its writer.
        if bound.matchesProcess(instance) {
            // Moving the live pane must not rewrite the saved delivery target.
            run.invocations[index].instance?.conversationID = instance.conversationID
        } else {
            run.invocations[index].instance = instance
        }
        run.invocations[index].delivery.toAgentID = instance.id
        run.invocations[index].issue = nil
        changed()
    }

    mutating func beginContinuation(_ expected: AgentWorkflowInvocation, instance: AgentWorkflowInstance, now: Date) throws {
        try requireScheduling(now: now)
        let index = try index(of: expected.id)
        let invocation = run.invocations[index]
        guard
            invocation.status == .running, invocation.round == run.round,
            let turn = invocation.stepTurn, turn.id == expected.stepTurn?.id,
            turn.transcriptPath == expected.stepTurn?.transcriptPath, !turn.completionRequested,
            invocation.continuationTurnID != turn.id,
            let node = run.definition.nodes.first(where: { $0.id == invocation.nodeID }), node.completion == .explicit,
            let current = run.definition.instance(for: node.agentInstanceID, in: run.instances),
            current.matchesBinding(instance), instance.readiness == .ready else {
            throw AgentWorkflowError("The step changed or a continuation was already sent. Check the Agent tab before continuing again.")
        }
        run.invocations[index].continuationTurnID = turn.id
        run.invocations[index].issue = "Continuation requested. Waiting for the Agent to accept it; the original task will not be resent."
        changed()
    }

    mutating func continuationNotWritten(_ expected: AgentWorkflowInvocation) throws {
        let index = try index(of: expected.id)
        guard run.invocations[index].continuationTurnID == expected.stepTurn?.id else { return }
        run.invocations[index].continuationTurnID = nil
        run.invocations[index].issue = nil
        changed()
    }

    mutating func stopStepTurn(invocationID: UUID, turnID: String) throws {
        let index = try index(of: invocationID)
        guard run.invocations[index].stepTurn?.id == turnID else { return }
        run.invocations[index].stepTurn?.stopped = true
        changed()
    }

    mutating func requestStepCompletion(invocationID: UUID, instance: AgentWorkflowInstance, turnID: String?, now: Date) throws {
        let index = try index(of: invocationID)
        let invocation = run.invocations[index]
        try validate(instance, for: invocation)
        guard
            !run.status.isTerminal, now < run.authorizationExpiresAt,
            invocation.round == run.round, invocation.status == .running,
            run.instance(for: invocation)?.matchesBinding(instance) == true,
            run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit,
            let turn = invocation.stepTurn, turn.id == turnID,
            invocation.continuationTurnID != turn.id,
            !turn.stopped || turn.completionRequested else {
            throw AgentWorkflowError("This step needs a current accepted Agent turn before it can be completed.")
        }
        guard !turn.completionRequested else { return }
        run.invocations[index].stepTurn?.completionRequested = true
        changed()
    }

    mutating func recordQuestion(instance: AgentWorkflowInstance) {
        guard
            !run.status.isTerminal,
            run.instances.contains(where: { $0.matchesBinding(instance) }) || canBindFirstConversation(instance),
            let index = run.invocations.firstIndex(where: {
                $0.delivery.toAgentID == instance.id && [.writing, .awaitingAcceptance, .running].contains($0.status)
            }), run.invocations[index].hasAskedQuestion != true else { return }
        run.invocations[index].hasAskedQuestion = true
        changed()
    }

    mutating func pause(reason: String) {
        guard !run.status.isTerminal else { return }
        guard run.status != .paused || run.issue != reason else { return }
        run.status = .paused
        run.issue = reason
        changed()
    }

    mutating func waitForAgent(_ instance: AgentWorkflowInstance, reason: String) {
        guard
            !run.status.isTerminal,
            let index = run.instances.firstIndex(where: { $0.matchesBinding(instance) }) else { return }
        run.instances[index].readiness = .unavailable
        if run.status != .paused {
            run.issue = "Waiting for Agent: \(instance.displayName). \(reason)"
        }
        changed()
    }

    @discardableResult
    mutating func refreshBindings(instances: [AgentWorkflowInstance]) throws -> String? {
        var replacements: [AgentWorkflowInstance] = []
        var waiting: [String] = []
        for id in run.definition.agentInstanceIDs {
            guard var live = run.definition.instance(for: id, in: instances) ?? run.definition.instance(for: id, in: run.instances) else {
                throw AgentWorkflowError("The workflow has no saved Agent tab.")
            }
            let isPresent = run.definition.instance(for: id, in: instances) != nil
            if !isPresent {
                live.readiness = .unavailable
            }
            if isPresent, let issue = live.capabilityIssue {
                throw AgentWorkflowError("\(live.displayName): \(issue)")
            }
            if isPresent, (live.capabilities?.maximumInputBytes ?? 0) <= 0 {
                throw AgentWorkflowError("\(live.displayName): Workflow support is unavailable. Check the Agent's CtrlX plugin.")
            }
            if live.readiness == .unavailable {
                waiting.append(live.displayName)
            }
            replacements.append(live)
        }
        var updated = false
        for index in run.instances.indices {
            guard let live = replacements.first(where: { $0.agentID == run.instances[index].agentID }) else { continue }
            // First-conversation confirmation is committed with its receipt.
            if
                run.instances[index] != live,
                !canBindFirstConversation(live) {
                run.instances[index] = live
                updated = true
            }
        }
        let issue = waiting.isEmpty ? nil : "Waiting for Agent: \(waiting.joined(separator: "; ")). Resume the Agent in its existing tab; the workflow will continue automatically."
        if run.status != .paused {
            if run.issue != issue {
                run.issue = issue
                updated = true
            }
        }
        for index in run.invocations.indices where run.invocations[index].status == .pending {
            let invocation = run.invocations[index]
            guard
                let node = run.definition.nodes.first(where: { $0.id == invocation.nodeID }),
                let live = run.definition.instance(for: node.agentInstanceID, in: run.instances),
                run.instance(for: invocation)?.matchesBinding(live) != true else { continue }
            run.invocations[index].instance = live
            run.invocations[index].delivery.toAgentID = live.id
            updated = true
        }
        if updated {
            changed()
        }
        return issue
    }

    mutating func resume(instances: [AgentWorkflowInstance], roundLimit: Int? = nil, now: Date) throws {
        guard run.status == .paused, now < run.authorizationExpiresAt else {
            throw AgentWorkflowError("Only a paused workflow with valid authorization can continue.")
        }
        guard !run.invocations.contains(where: { $0.status == .uncertain }) else {
            throw AgentWorkflowError("Verify uncertain tasks before continuing. They will not be resent.")
        }
        let limit = roundLimit ?? run.roundLimit
        guard
            limit >= run.roundLimit,
            run.definition.loop != nil || limit == 1 else {
            throw AgentWorkflowError("The new round limit must preserve the configured loop.")
        }
        if run.finishRequest == nil, run.definition.loop != nil, roundSucceeded, limit <= run.round {
            throw AgentWorkflowError("Increase the round limit to continue this workflow.")
        }
        let issue = try refreshBindings(instances: instances)
        if let finish = run.finishRequest, run.invocations.first(where: { $0.id == finish.invocationID })?.status == .failed {
            run.finishRequest = nil
        }
        run.roundLimit = limit
        run.status = run.finishRequest == nil ? .running : .finishing
        run.issue = issue
        settle(now: now)
        changed()
    }

    mutating func requestFinish(invocationID: UUID, instance: AgentWorkflowInstance, reason: String, now: Date) throws {
        let index = try index(of: invocationID)
        let invocation = run.invocations[index]
        try validate(instance, for: invocation)
        guard run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.allowsFinish == true else {
            throw AgentWorkflowError("This Agent is not authorized to finish the workflow.")
        }
        guard
            !run.status.isTerminal,
            invocation.round == run.round, invocation.status == .running,
            run.instance(for: invocation)?.matchesBinding(instance) == true,
            now < run.authorizationExpiresAt, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentWorkflowError("This invocation cannot request workflow completion.")
        }
        if run.finishRequest?.invocationID == invocationID {
            return
        }
        guard run.finishRequest == nil else {
            throw AgentWorkflowError("Another invocation already requested workflow completion.")
        }
        if run.definition.nodes.first(where: { $0.id == invocation.nodeID })?.completion == .explicit {
            try requestStepCompletion(invocationID: invocationID, instance: instance, turnID: invocation.stepTurn?.id, now: now)
        }
        run.finishRequest = .init(invocationID: invocationID, reason: reason, requestedAt: now)
        if run.status != .paused {
            run.status = .finishing
            run.issue = nil
        }
        changed()
    }

    mutating func end() {
        guard !run.status.isTerminal else { return }
        run.status = .ended
        run.issue = nil
        for index in run.invocations.indices where run.invocations[index].status == .pending {
            run.invocations[index].status = .cancelled
        }
        changed()
    }

    private func invocation(nodeID: UUID, round: Int) -> AgentWorkflowInvocation? {
        run.invocations.last { $0.nodeID == nodeID && $0.round == round }
    }

    private func index(of invocationID: UUID) throws -> Int {
        guard let index = run.invocations.firstIndex(where: { $0.id == invocationID }) else {
            throw AgentWorkflowError("The workflow invocation does not exist.")
        }
        return index
    }

    private func validate(_ instance: AgentWorkflowInstance, for invocation: AgentWorkflowInvocation) throws {
        guard
            let bound = run.instance(for: invocation),
            bound.matchesBinding(instance) || (invocation.nativeTurnID != nil && bound.matchesConversation(instance)) else {
            throw AgentWorkflowError("The Agent instance or its conversation changed.")
        }
    }

    private func requireScheduling(now: Date) throws {
        guard run.status == .running, run.finishRequest == nil, now < run.authorizationExpiresAt else {
            throw AgentWorkflowError("The workflow is paused, ended or its authorization has expired.")
        }
    }

    private var roundSucceeded: Bool {
        run.definition.activeNodeIDs(round: run.round).allSatisfy { invocation(nodeID: $0, round: run.round)?.status == .succeeded }
    }

    private mutating func settle(now: Date) {
        guard !run.status.isTerminal, run.status != .paused else { return }
        if let finish = run.finishRequest {
            if run.invocations.first(where: { $0.id == finish.invocationID })?.status == .succeeded {
                run.status = .completed
                run.issue = nil
            }
            return
        }
        guard run.status == .running else { return }
        if roundSucceeded, run.definition.loop == nil {
            run.status = .completed
            run.issue = nil
        } else if now >= run.authorizationExpiresAt {
            run.status = .paused
            run.issue = "Workflow authorization expired. No further tasks will be sent."
        } else if roundSucceeded {
            if run.round < run.roundLimit {
                run.round += 1
            } else {
                run.status = .paused
                run.issue = "Round limit reached. Increase the limit to continue, or end this workflow."
            }
        }
    }

    private mutating func changed() {
        run.revision += 1
    }
}
