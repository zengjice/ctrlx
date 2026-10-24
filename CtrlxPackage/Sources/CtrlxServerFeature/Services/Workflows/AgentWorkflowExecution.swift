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
        guard authorizationExpiresAt > now else { throw AgentWorkflowError("The workflow authorization has expired.") }
        guard
            instances.count == definition.agentInstanceIDs.count,
            Set(instances.map(\.id)) == definition.agentInstanceIDs else {
            throw AgentWorkflowError("Every Agent node must have a distinct live Agent binding.")
        }
        for instance in instances {
            guard
                instance.hostID == definition.hostID, instance.processID > 1,
                !instance.processRuntimeID.isEmpty, !instance.conversationID.isEmpty,
                let capabilities = instance.capabilities, capabilities.maximumInputBytes > 0,
                instance.readiness == .ready else {
                throw AgentWorkflowError("\(instance.displayName) is not ready for an authenticated workflow task.")
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
        try run.definition.validate()
        guard
            run.round > 0, run.roundLimit >= run.round,
            Set(run.instances.map(\.id)) == run.definition.agentInstanceIDs,
            run.instances.count == run.definition.agentInstanceIDs.count,
            Set(run.invocations.map(\.id)).count == run.invocations.count else {
            throw AgentWorkflowError("The saved workflow has inconsistent instance or invocation records.")
        }
        var slots: Set<String> = []
        for invocation in run.invocations {
            let node = run.definition.nodes.first { $0.id == invocation.nodeID }
            let shared = invocation.sharedAttachmentIDs ?? []
            guard
                let node, invocation.round > 0, invocation.round <= run.round,
                slots.insert("\(invocation.round):\(invocation.nodeID)").inserted,
                invocation.delivery.invocationID == invocation.id,
                invocation.delivery.runID == run.id,
                invocation.delivery.round == invocation.round,
                invocation.delivery.toAgentID == node.agentInstanceID,
                shared.count <= AgentWorkflowWire.maximumAttachments,
                Set(shared).count == shared.count,
                invocation.result.map({ $0.attachmentIDs == shared }) ?? true,
                (invocation.status == .succeeded) == (invocation.result != nil),
                invocation.result.map({ $0.invocationID == invocation.id && $0.nativeTurnID == invocation.nativeTurnID }) ?? true else {
                throw AgentWorkflowError("The saved workflow contains an invalid invocation.")
            }
            if node.kind == .content {
                guard
                    invocation.status == .succeeded, invocation.nativeTurnID == nil, invocation.nativeTranscriptPath == nil,
                    invocation.result?.text == invocation.delivery.input.text,
                    shared == invocation.delivery.input.attachmentIDs else {
                    throw AgentWorkflowError("The saved content output is inconsistent.")
                }
            } else if invocation.status == .succeeded, invocation.result?.nativeTurnID?.isEmpty != false {
                throw AgentWorkflowError("The saved Agent result has no verified native turn.")
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
        return run.definition.nodes.compactMap { node in
            guard invocation(nodeID: node.id, round: run.round) == nil else { return nil }
            if node.id == run.definition.entryNodeID {
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
        if let existing = invocation(nodeID: nodeID, round: run.round) {
            return existing
        }
        guard
            readyNodeIDs.contains(nodeID), let node = run.definition.nodes.first(where: { $0.id == nodeID }) else {
            throw AgentWorkflowError("This node is still waiting for its upstream results.")
        }
        let invocationID = UUID()
        let upstream: [AgentWorkflowInvocation]
        if nodeID == run.definition.entryNodeID, run.round > 1, let finalID = run.definition.loop?.finalNodeID {
            upstream = run.invocations.filter { $0.nodeID == finalID && $0.round == run.round - 1 }
        } else {
            upstream = run.definition.upstream(of: nodeID).compactMap { invocation(nodeID: $0.id, round: run.round) }
        }
        var answers: [AgentWorkflowPrompt.Answer] = []
        var sources: [AgentWorkflowSource] = []
        for source in upstream {
            guard let result = source.result, let sourceNode = run.definition.nodes.first(where: { $0.id == source.nodeID }) else {
                throw AgentWorkflowError("An upstream result is missing.")
            }
            answers.append(.init(role: sourceNode.name, round: source.round, text: result.text, attachmentIDs: result.attachmentIDs, kind: sourceNode.kind))
            sources.append(.init(nodeID: sourceNode.id, agentInstanceID: sourceNode.agentInstanceID, resultID: result.id))
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
            guard let capabilities = run.instances.first(where: { $0.id == node.agentInstanceID })?.capabilities else {
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
            toAgentID: node.agentInstanceID,
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
        if node.kind == .content {
            created.status = .succeeded
            created.sharedAttachmentIDs = input.attachmentIDs
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
        run.invocations[index].status = .writing
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

    mutating func accept(invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, transcriptPath: String? = nil) throws {
        let index = try index(of: invocationID)
        let invocation = run.invocations[index]
        try validate(instance, for: invocation)
        guard
            !nativeTurnID.isEmpty,
            invocation.nativeTurnID == nil || invocation.nativeTurnID == nativeTurnID,
            invocation.nativeTranscriptPath == nil || transcriptPath == nil || invocation.nativeTranscriptPath == transcriptPath else {
            throw AgentWorkflowError("The native turn does not match this workflow invocation.")
        }
        if [.running, .succeeded, .failed].contains(invocation.status) {
            return
        }
        guard [.writing, .awaitingAcceptance, .uncertain].contains(invocation.status) else {
            throw AgentWorkflowError("No written workflow task is awaiting this acceptance.")
        }
        run.invocations[index].nativeTurnID = nativeTurnID
        run.invocations[index].nativeTranscriptPath = transcriptPath
        run.invocations[index].status = .running
        run.invocations[index].issue = nil
        changed()
    }

    @discardableResult
    mutating func succeed(_ result: AgentWorkflowResult, instance: AgentWorkflowInstance, now: Date) throws -> Bool {
        let index = try index(of: result.invocationID)
        let invocation = run.invocations[index]
        try validate(instance, for: invocation)
        guard let nativeTurnID = result.nativeTurnID, !nativeTurnID.isEmpty, invocation.nativeTurnID == nativeTurnID else {
            throw AgentWorkflowError("The result has no matching accepted native turn.")
        }
        if invocation.status == .succeeded {
            return false
        }
        // A restart makes delivery uncertain, but a persisted receipt plus a
        // verified native result can settle that same call without resending it.
        guard [.running, .uncertain].contains(invocation.status) else {
            throw AgentWorkflowError("Verify the Agent's accepted task before recording a result.")
        }
        let shared = invocation.sharedAttachmentIDs ?? []
        guard result.attachmentIDs.isEmpty || result.attachmentIDs == shared else {
            throw AgentWorkflowError("Only explicitly shared snapshots can be included in a workflow result.")
        }
        run.invocations[index].status = .succeeded
        run.invocations[index].result = .init(
            id: result.id, invocationID: result.invocationID, nativeTurnID: result.nativeTurnID,
            text: result.text, attachmentIDs: shared, completedAt: result.completedAt
        )
        run.invocations[index].issue = nil
        settle(now: now)
        changed()
        return true
    }

    func authorizeArtifact(invocationID: UUID, instance: AgentWorkflowInstance, now: Date) throws {
        let invocation = try run.invocations[index(of: invocationID)]
        try validate(instance, for: invocation)
        guard
            !run.status.isTerminal,
            invocation.round == run.round, invocation.status == .running,
            now < run.authorizationExpiresAt else {
            throw AgentWorkflowError("This invocation is no longer authorized to share artifacts.")
        }
    }

    mutating func shareArtifact(_ id: UUID, invocationID: UUID, instance: AgentWorkflowInstance, now: Date) throws {
        try authorizeArtifact(invocationID: invocationID, instance: instance, now: now)
        let index = try index(of: invocationID)
        var shared = run.invocations[index].sharedAttachmentIDs ?? []
        if shared.contains(id) {
            return
        }
        guard shared.count < AgentWorkflowWire.maximumAttachments else {
            throw AgentWorkflowError("Share up to 32 artifacts per invocation.")
        }
        shared.append(id)
        run.invocations[index].sharedAttachmentIDs = shared
        changed()
    }

    mutating func fail(invocationID: UUID, instance: AgentWorkflowInstance, nativeTurnID: String, reason: String) throws {
        let index = try index(of: invocationID)
        try validate(instance, for: run.invocations[index])
        guard run.invocations[index].nativeTurnID == nativeTurnID, !nativeTurnID.isEmpty else {
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

    mutating func pause(reason: String) {
        guard !run.status.isTerminal else { return }
        guard run.status != .paused || run.issue != reason else { return }
        run.status = .paused
        run.issue = reason
        changed()
    }

    mutating func resume(instances: [AgentWorkflowInstance], roundLimit: Int? = nil, now: Date) throws {
        guard run.status == .paused, now < run.authorizationExpiresAt else {
            throw AgentWorkflowError("Only a paused workflow with valid authorization can continue.")
        }
        for bound in run.instances {
            guard let live = instances.first(where: { bound.matchesBinding($0) && $0.readiness != .unavailable }) else {
                throw AgentWorkflowError("An Agent instance changed. End this run and bind the replacement explicitly.")
            }
            if run.finishRequest == nil, live.readiness == .draft || live.readiness == .awaitingHuman {
                throw AgentWorkflowError("\(live.displayName) needs human input or has a draft. Resolve it before continuing.")
            }
        }
        guard !run.invocations.contains(where: { $0.status == .uncertain || $0.status == .failed }) else {
            throw AgentWorkflowError("Resolve uncertain tasks first. Failed runs require a new execution.")
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
        run.roundLimit = limit
        run.status = run.finishRequest == nil ? .running : .finishing
        run.issue = nil
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
            now < run.authorizationExpiresAt, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentWorkflowError("This invocation cannot request workflow completion.")
        }
        if run.finishRequest?.invocationID == invocationID {
            return
        }
        guard run.finishRequest == nil else {
            throw AgentWorkflowError("Another invocation already requested workflow completion.")
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
        run.invocations.first { $0.nodeID == nodeID && $0.round == round }
    }

    private func index(of invocationID: UUID) throws -> Int {
        guard let index = run.invocations.firstIndex(where: { $0.id == invocationID }) else {
            throw AgentWorkflowError("The workflow invocation does not exist.")
        }
        return index
    }

    private func validate(_ instance: AgentWorkflowInstance, for invocation: AgentWorkflowInvocation) throws {
        guard let bound = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }), bound.matchesBinding(instance) else {
            throw AgentWorkflowError("The Agent instance or its conversation changed.")
        }
    }

    private func requireScheduling(now: Date) throws {
        guard run.status == .running, run.finishRequest == nil, now < run.authorizationExpiresAt else {
            throw AgentWorkflowError("The workflow is paused, ended or its authorization has expired.")
        }
    }

    private var roundSucceeded: Bool {
        run.definition.nodes.allSatisfy { invocation(nodeID: $0.id, round: run.round)?.status == .succeeded }
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
