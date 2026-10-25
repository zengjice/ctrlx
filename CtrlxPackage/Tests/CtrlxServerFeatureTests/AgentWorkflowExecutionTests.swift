import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowExecutionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func execution(loop: Bool = false, limit: Int = 5) throws -> AgentWorkflowExecution {
        let hostID = UUID()
        let instances = ["Developer", "Review A", "Review B", "Summary"].enumerated().map { index, name in
            AgentWorkflowInstance(
                hostID: hostID,
                pluginID: index.isMultiple(of: 2) ? "codex" : "claude-code",
                processID: Int32(100 + index),
                processRuntimeID: "start-\(index)",
                workspacePane: .init(serverID: "tmux-1", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)",
                conversationID: UUID().uuidString,
                displayName: name,
                workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000),
                readiness: .ready
            )
        }
        let nodes = instances.enumerated().map { index, instance in
            AgentWorkflowNode(
                name: instance.displayName,
                agentInstanceID: instance.id,
                input: .init(text: index == 1 ? "$review-changes\nReview correctness." : instance.displayName),
                allowsFinish: index == 3
            )
        }
        let definition = AgentWorkflowDefinition(
            name: "Build and review",
            hostID: hostID,
            nodes: nodes,
            edges: [
                .init(source: nodes[0].id, target: nodes[1].id), .init(source: nodes[0].id, target: nodes[2].id),
                .init(source: nodes[1].id, target: nodes[3].id), .init(source: nodes[2].id, target: nodes[3].id),
            ],
            entryNodeID: nodes[0].id,
            initialInput: .init(text: "Fix the issue."),
            loop: loop ? .init(finalNodeID: nodes[3].id, maximumRounds: limit) : nil
        )
        return try .init(definition: definition, instances: instances, now: now, authorizationExpiresAt: now.addingTimeInterval(3_600))
    }

    private func start(_ index: Int, in execution: inout AgentWorkflowExecution) throws -> AgentWorkflowInvocation {
        let node = execution.run.definition.nodes[index]
        let instance = execution.run.instances[index]
        let invocation = try execution.prepareInvocation(nodeID: node.id, now: now)
        try execution.beginWriting(invocationID: invocation.id, instance: instance, now: now)
        try execution.didWrite(invocationID: invocation.id)
        try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: invocation.id.uuidString)
        return invocation
    }

    private func finish(
        _ index: Int,
        invocation: AgentWorkflowInvocation,
        text: String,
        in execution: inout AgentWorkflowExecution
    ) throws {
        try execution.succeed(.init(
            invocationID: invocation.id,
            nativeTurnID: invocation.id.uuidString,
            text: text,
            completedAt: now
        ), instance: execution.run.instances[index], now: now)
    }

    private func reachSummary(_ execution: inout AgentWorkflowExecution) throws -> AgentWorkflowInvocation {
        let developer = try start(0, in: &execution)
        try finish(0, invocation: developer, text: "Implementation complete", in: &execution)
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        try finish(2, invocation: b, text: "B's review", in: &execution)
        try finish(1, invocation: a, text: "A's review", in: &execution)
        return try start(3, in: &execution)
    }

    @Test
    func fanOutJoinsOnceInConfiguredOrder() throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        try finish(0, invocation: developer, text: "Changes ready", in: &execution)
        #expect(execution.readyNodeIDs == execution.run.definition.nodes[1...2].map(\.id))
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        #expect(a.delivery.sources == b.delivery.sources)
        #expect(a.delivery.id != b.delivery.id)
        #expect(a.delivery.input.text.hasPrefix("$review-changes\n"))
        try finish(2, invocation: b, text: "B result", in: &execution)
        #expect(execution.readyNodeIDs.isEmpty)
        try finish(1, invocation: a, text: "A result", in: &execution)
        let summary = try execution.prepareInvocation(nodeID: execution.run.definition.nodes[3].id, now: now)
        #expect(summary.delivery.sources.map(\.nodeID) == execution.run.definition.nodes[1...2].map(\.id))
        let input = summary.delivery.input.text
        #expect(try #require(input.range(of: "A result")).lowerBound < #require(input.range(of: "B result")).lowerBound)
        #expect(try execution.prepareInvocation(nodeID: summary.nodeID, now: now).id == summary.id)
        try finish(1, invocation: a, text: "duplicate must not replace", in: &execution)
        #expect(execution.run.invocations.count == 4)
        #expect(execution.run.invocations.first { $0.id == a.id }?.result?.text == "A result")
        #expect(execution.run.status == .running)
    }

    @Test(arguments: [true, false])
    func multipleTargetsJoinOnlyTheirOwnUpstreams(secondTargetWaitsForBoth: Bool) throws {
        let base = try execution()
        var definition = base.run.definition
        let extra = AgentWorkflowInstance(
            hostID: definition.hostID, pluginID: "codex", processID: 104,
            processRuntimeID: "start-4",
            workspacePane: .init(serverID: "tmux-1", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%4", conversationID: UUID().uuidString,
            displayName: "Test summary", workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )
        definition.nodes[3].input.text = "$summarize-review\nCombine both reviews."
        definition.nodes.append(.init(
            name: extra.displayName, agentInstanceID: extra.id,
            input: .init(text: "$summarize-tests\nAssess the supplied reviews.")
        ))
        let nodes = definition.nodes
        definition.edges.append(.init(source: nodes[1].id, target: nodes[4].id))
        if secondTargetWaitsForBoth {
            definition.edges.append(.init(source: nodes[2].id, target: nodes[4].id))
        }
        var execution = try AgentWorkflowExecution(
            definition: definition, instances: base.run.instances + [extra], now: now,
            authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
        let entry = try start(0, in: &execution)
        try finish(0, invocation: entry, text: "Changes ready", in: &execution)
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        try finish(1, invocation: a, text: "A result", in: &execution)
        #expect(execution.readyNodeIDs == (secondTargetWaitsForBoth ? [] : [nodes[4].id]))

        var secondTarget: AgentWorkflowInvocation?
        if !secondTargetWaitsForBoth {
            secondTarget = try start(4, in: &execution)
        }
        try finish(2, invocation: b, text: "B result", in: &execution)
        let firstTarget = try start(3, in: &execution)
        if secondTarget == nil {
            secondTarget = try start(4, in: &execution)
        }
        let other = try #require(secondTarget)
        #expect(firstTarget.delivery.id != other.delivery.id)
        #expect(firstTarget.delivery.sources.map(\.nodeID) == [nodes[1].id, nodes[2].id])
        if secondTargetWaitsForBoth {
            #expect(firstTarget.delivery.sources == other.delivery.sources)
        } else {
            #expect(other.delivery.sources.map(\.nodeID) == [nodes[1].id])
            #expect(!other.delivery.input.text.contains("B result"))
        }
        #expect(firstTarget.delivery.input.text.components(separatedBy: "$summarize-review").count == 2)
        #expect(other.delivery.input.text.components(separatedBy: "$summarize-tests").count == 2)
        #expect(!firstTarget.delivery.input.text.contains("$summarize-tests"))
        #expect(!other.delivery.input.text.contains("$summarize-review"))

        try finish(1, invocation: a, text: "Duplicate A", in: &execution)
        try finish(4, invocation: other, text: "Keep this completed target", in: &execution)
        try execution.fail(
            invocationID: firstTarget.id, instance: execution.run.instances[3],
            nativeTurnID: firstTarget.id.uuidString, reason: "Target failed"
        )
        #expect(execution.run.status == .paused)
        #expect(execution.run.invocations.count == 5)
        #expect(execution.run.invocations.filter { $0.nodeID == nodes[4].id }.count == 1)
        #expect(execution.run.invocations.first { $0.id == other.id }?.result?.text == "Keep this completed target")
        #expect(execution.run.invocations.first { $0.id == a.id }?.result?.text == "A result")
        #expect(execution.readyNodeIDs.isEmpty)
    }

    @Test
    func loopUsesOnlyPreviousFinalAnswerAndStopsAtLimit() throws {
        var execution = try execution(loop: true, limit: 2)
        let summary = try reachSummary(&execution)
        try finish(3, invocation: summary, text: "Fix remaining bug", in: &execution)
        #expect(execution.run.round == 2)
        let next = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        #expect(next.delivery.sources.count == 1)
        #expect(next.delivery.sources[0].nodeID == summary.nodeID)
        #expect(next.delivery.input.text.contains("Fix remaining bug"))
        #expect(!next.delivery.input.text.contains("B's review"))
        try finish(3, invocation: summary, text: "old duplicate", in: &execution)
        #expect(execution.run.round == 2)
        let lastSummary = try reachSummary(&execution)
        try finish(3, invocation: lastSummary, text: "Still more work", in: &execution)
        #expect(execution.run.status == .paused)
        #expect(execution.run.round == 2)
        #expect(throws: AgentWorkflowError.self) { try execution.resume(instances: execution.run.instances, now: now) }
        try execution.resume(instances: execution.run.instances, roundLimit: 3, now: now)
        #expect(execution.run.round == 3 && execution.run.status == .running)
    }

    @Test
    func pausePreservesParallelResultsAndBlocksNewDelivery() throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        try finish(0, invocation: developer, text: "Ready", in: &execution)
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        execution.pause(reason: "Human is answering a question")
        try finish(1, invocation: a, text: "A", in: &execution)
        try finish(2, invocation: b, text: "B", in: &execution)
        #expect(execution.readyNodeIDs.isEmpty)
        #expect(throws: AgentWorkflowError.self) {
            try execution.prepareInvocation(nodeID: execution.run.definition.nodes[3].id, now: now)
        }
        try execution.resume(instances: execution.run.instances, now: now)
        #expect(execution.readyNodeIDs == [execution.run.definition.nodes[3].id])
    }

    @Test
    func failureDoesNotSatisfyJoin() throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        try finish(0, invocation: developer, text: "Ready", in: &execution)
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        try execution.fail(invocationID: b.id, instance: execution.run.instances[2], nativeTurnID: b.id.uuidString, reason: "Provider failed")
        try finish(1, invocation: a, text: "Keep this result", in: &execution)
        #expect(execution.run.status == .paused)
        #expect(execution.run.invocations.first { $0.id == a.id }?.result?.text == "Keep this result")
        #expect(execution.readyNodeIDs.isEmpty)
        #expect(throws: AgentWorkflowError.self) { try execution.resume(instances: execution.run.instances, now: now) }
    }

    @Test
    func acceptanceCanPrecedeTerminalWriteCompletion() throws {
        var execution = try execution()
        let invocation = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        let instance = execution.run.instances[0]
        try execution.beginWriting(invocationID: invocation.id, instance: instance, now: now)
        try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn")
        try execution.didWrite(invocationID: invocation.id)
        try execution.writeUncertain(invocationID: invocation.id, reason: "Late write error")
        #expect(execution.run.invocations[0].status == .running)
        #expect(execution.run.status == .running)
    }

    @Test(arguments: ["pending", "writing", "awaitingAcceptance", "running"])
    func crashRecoveryNeverAutomaticallyReplaysInput(phase: String) throws {
        var execution = try execution()
        let invocation = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        let instance = execution.run.instances[0]
        if phase != "pending" {
            try execution.beginWriting(invocationID: invocation.id, instance: instance, now: now)
        }
        if phase == "awaitingAcceptance" {
            try execution.didWrite(invocationID: invocation.id)
        }
        if phase == "running" {
            try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn")
        }
        let encoded = try JSONEncoder().encode(execution.run)
        let saved = try JSONDecoder().decode(AgentWorkflowRun.self, from: encoded)
        #expect(saved == execution.run)
        var restored = try AgentWorkflowExecution(restoring: saved)
        #expect(restored.run.status == .paused)
        #expect(restored.readyNodeIDs.isEmpty)
        #expect(restored.run.invocations[0].delivery == invocation.delivery)
        if phase == "pending" {
            try restored.resume(instances: restored.run.instances, now: now)
            try restored.beginWriting(invocationID: invocation.id, instance: instance, now: now)
        } else {
            #expect(restored.run.invocations[0].status == .uncertain)
            #expect(throws: AgentWorkflowError.self) { try restored.resume(instances: restored.run.instances, now: now) }
            #expect(throws: AgentWorkflowError.self) { try restored.beginWriting(invocationID: invocation.id, instance: instance, now: now) }
            try restored.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn")
            try restored.resume(instances: restored.run.instances, now: now)
            #expect(restored.run.invocations[0].status == .running)
            #expect(throws: AgentWorkflowError.self) { try restored.beginWriting(invocationID: invocation.id, instance: instance, now: now) }
        }
    }

    @Test(arguments: ["conversation", "pane", "server", "plugin", "process", "host", "instance"])
    func staleIdentityCannotWriteOrComplete(kind: String) throws {
        var execution = try execution()
        let invocation = try start(0, in: &execution)
        let original = execution.run.instances[0]
        var pane = original.workspacePane
        if kind == "pane" {
            pane.paneID = UUID()
        }
        if kind == "server" {
            pane.serverID = "restarted"
        }
        let stale = AgentWorkflowInstance(
            id: kind == "instance" ? UUID() : original.id,
            hostID: kind == "host" ? UUID() : original.hostID,
            pluginID: kind == "plugin" ? "other" : original.pluginID,
            processID: original.processID,
            processRuntimeID: kind == "process" ? "new-start" : original.processRuntimeID,
            workspacePane: pane,
            paneID: original.paneID,
            conversationID: kind == "conversation" ? "other" : original.conversationID,
            displayName: original.displayName,
            workingDirectory: original.workingDirectory,
            capabilities: original.capabilities,
            readiness: .ready
        )
        #expect(throws: AgentWorkflowError.self) {
            try execution.succeed(.init(
                invocationID: invocation.id,
                nativeTurnID: invocation.id.uuidString,
                text: "Wrong result",
                completedAt: now
            ), instance: stale, now: now)
        }
        #expect(execution.run.invocations[0].result == nil)
    }

    @Test
    func paneMoveAndRenameKeepLiveBinding() throws {
        var execution = try execution()
        let invocation = try start(0, in: &execution)
        var moved = execution.run.instances[0]
        moved.workspacePane.windowID = UUID()
        moved.workspacePane.sessionID = UUID()
        moved.displayName = "Renamed"
        try execution.succeed(.init(
            invocationID: invocation.id,
            nativeTurnID: invocation.id.uuidString,
            text: "Valid",
            completedAt: now
        ), instance: moved, now: now)
        #expect(execution.readyNodeIDs.count == 2)
    }

    @Test
    func nativeTurnMustBeAcceptedBeforeResult() throws {
        var execution = try execution()
        let invocation = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        #expect(throws: AgentWorkflowError.self) {
            try execution.succeed(
                .init(invocationID: invocation.id, nativeTurnID: "unrelated", text: "Stop", completedAt: now),
                instance: execution.run.instances[0],
                now: now
            )
        }
        #expect(throws: AgentWorkflowError.self) {
            try execution.accept(invocationID: invocation.id, instance: execution.run.instances[0], nativeTurnID: "unsent")
        }
        let running = try start(0, in: &execution)
        #expect(throws: AgentWorkflowError.self) {
            try execution.accept(invocationID: running.id, instance: execution.run.instances[0], nativeTurnID: "different-turn")
        }
    }

    @Test
    func finishRequiresPermissionAndSuccessfulFinalAnswer() throws {
        var execution = try execution(loop: true)
        let developer = try start(0, in: &execution)
        #expect(!developer.delivery.input.text.contains("ctrlx workflow finish"))
        #expect(throws: AgentWorkflowError.self) {
            try execution.requestFinish(invocationID: developer.id, instance: execution.run.instances[0], reason: "Stop", now: now)
        }
        try finish(0, invocation: developer, text: "Done", in: &execution)
        let a = try start(1, in: &execution)
        let b = try start(2, in: &execution)
        try finish(1, invocation: a, text: "A", in: &execution)
        try finish(2, invocation: b, text: "B", in: &execution)
        let summary = try start(3, in: &execution)
        #expect(summary.delivery.input.text.contains("ctrlx workflow finish"))
        try execution.requestFinish(invocationID: summary.id, instance: execution.run.instances[3], reason: "Approved", now: now)
        #expect(execution.run.status == .finishing)
        #expect(execution.readyNodeIDs.isEmpty)
        let revision = execution.run.revision
        try execution.requestFinish(invocationID: summary.id, instance: execution.run.instances[3], reason: "Retry", now: now)
        #expect(execution.run.revision == revision)
        try finish(3, invocation: summary, text: "Final review", in: &execution)
        #expect(execution.run.status == .completed && execution.run.round == 1)
    }

    @Test
    func finishFollowedByFailureDoesNotReportSuccess() throws {
        var execution = try execution(loop: true)
        let summary = try reachSummary(&execution)
        try execution.requestFinish(invocationID: summary.id, instance: execution.run.instances[3], reason: "Approved", now: now)
        try execution.fail(invocationID: summary.id, instance: execution.run.instances[3], nativeTurnID: summary.id.uuidString, reason: "Failed before final answer")
        #expect(execution.run.status == .paused)
        #expect(execution.run.finishRequest != nil)
        #expect(execution.readyNodeIDs.isEmpty)
    }

    @Test
    func endArchivesLateResultWithoutDispatching() throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        execution.end()
        try finish(0, invocation: developer, text: "Late answer", in: &execution)
        #expect(execution.run.status == .ended)
        #expect(execution.run.invocations[0].result?.text == "Late answer")
        #expect(execution.readyNodeIDs.isEmpty)
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .busy, .awaitingHuman, .unavailable])
    func readinessIsRecheckedAtWrite(readiness: AgentWorkflowReadiness) throws {
        var execution = try execution()
        let pending = try execution.prepareInvocation(nodeID: execution.run.definition.entryNodeID, now: now)
        var instance = execution.run.instances[0]
        instance.readiness = readiness
        #expect(throws: AgentWorkflowError.self) { try execution.beginWriting(invocationID: pending.id, instance: instance, now: now) }
        #expect(execution.run.invocations[0].status == .pending)
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .awaitingHuman])
    func continueWaitsForHumanInputWithoutBlockingOtherBusyBranches(readiness: AgentWorkflowReadiness) throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        try finish(0, invocation: developer, text: "Changes ready", in: &execution)
        _ = try start(1, in: &execution)
        _ = try start(2, in: &execution)
        execution.pause(reason: "Resolve the human input first.")
        let paused = execution.run
        var live = paused.instances
        live[1].readiness = readiness
        live[2].readiness = .busy

        #expect(throws: AgentWorkflowError.self) {
            try execution.resume(instances: live, now: now)
        }
        #expect(execution.run == paused)

        live[1].readiness = .ready
        try execution.resume(instances: live, now: now)
        #expect(execution.run.status == .running)
        #expect(execution.run.invocations == paused.invocations)
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .awaitingHuman])
    func continueCanSettleAuthorizedFinishWithoutResumingHandoffs(readiness: AgentWorkflowReadiness) throws {
        var execution = try execution(loop: true)
        let summary = try reachSummary(&execution)
        execution.pause(reason: "Paused by the operator.")
        try execution.requestFinish(invocationID: summary.id, instance: execution.run.instances[3], reason: "Approved", now: now)
        try finish(3, invocation: summary, text: "Verified final answer", in: &execution)
        let paused = execution.run
        var live = paused.instances
        live[0].readiness = readiness

        try execution.resume(instances: live, now: now)

        #expect(execution.run.status == .completed)
        #expect(execution.run.invocations == paused.invocations)
        #expect(execution.readyNodeIDs.isEmpty)
    }

    @Test
    func expirationPreventsAnotherHandoff() throws {
        var execution = try execution()
        let developer = try start(0, in: &execution)
        let expired = execution.run.authorizationExpiresAt
        try execution.succeed(
            .init(invocationID: developer.id, nativeTurnID: developer.id.uuidString, text: "Done", completedAt: expired),
            instance: execution.run.instances[0],
            now: expired
        )
        #expect(execution.run.status == .paused)
        #expect(throws: AgentWorkflowError.self) { try execution.resume(instances: execution.run.instances, now: expired) }
    }

    @Test
    func inputLimitNeverTruncatesAnswer() throws {
        let original = try execution()
        var definition = original.run.definition
        definition.initialInput.text = String(repeating: "长", count: 100_000)
        var execution = try AgentWorkflowExecution(
            definition: definition,
            instances: original.run.instances,
            now: now,
            authorizationExpiresAt: now.addingTimeInterval(3_600)
        )
        #expect(throws: AgentWorkflowError.self) { try execution.prepareInvocation(nodeID: definition.entryNodeID, now: now) }
        #expect(execution.run.invocations.isEmpty)
    }

    @Test
    func oneShotCompletesOnlyAfterLastNode() throws {
        var execution = try execution()
        let summary = try reachSummary(&execution)
        #expect(execution.run.status == .running)
        try finish(3, invocation: summary, text: "Done", in: &execution)
        #expect(execution.run.status == .completed)
        #expect(try AgentWorkflowExecution(restoring: execution.run).run == execution.run)
    }
}
