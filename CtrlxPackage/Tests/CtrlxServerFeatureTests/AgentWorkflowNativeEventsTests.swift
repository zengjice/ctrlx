import ClaudeCodePluginCore
import Clocks
import CodexPluginCore
import ConcurrencyExtras
import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

private struct WorkflowRetryTestClock: Clock {
    let clock = TestClock()
    let sleeps = AsyncStream<TestClock<Duration>.Instant>.makeStream()

    var now: TestClock<Duration>.Instant {
        clock.now
    }

    var minimumResolution: Duration {
        clock.minimumResolution
    }

    func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
        sleeps.continuation.yield(deadline)
        try await clock.sleep(until: deadline, tolerance: tolerance)
    }

    func advancePastNextSleep() async throws {
        var deadlines = sleeps.stream.makeAsyncIterator()
        let deadline = try #require(await deadlines.next())
        // Also wake a sleep that has announced its deadline but has yet to register.
        await clock.advance(to: deadline.advanced(by: .nanoseconds(1)))
    }
}

private struct NativeWorkflowTestParser: AgentWorkflowTranscriptParser {
    var onOutcome: @Sendable () -> Void = { }
    var outcome: AgentWorkflowTranscriptOutcome?

    mutating func updateCandidate(_: String) -> AgentWorkflowTranscriptOutcome? {
        outcome
    }

    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        let value = try JSONDecoder().decode([String: String].self, from: line)
        let result = value["failure"].map { AgentWorkflowTranscriptOutcome.failed($0) }
            ?? value["final"].map { .succeeded($0) }
        if result != nil {
            outcome = result
            onOutcome()
        }
        return result
    }
}

private actor NativeWorkflowTestProvider: AgentWorkflowProviding {
    nonisolated let onOutcome: @Sendable () -> Void

    init(onOutcome: @escaping @Sendable () -> Void = { }) {
        self.onOutcome = onOutcome
    }

    nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 10_000)
    }

    nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "test> ")
    }

    nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        NativeWorkflowTestParser(onOutcome: onOutcome)
    }
}

private struct AppendingCodexTestTranscript: AgentWorkflowTranscriptParser {
    var parser: CodexWorkflowTranscript
    let watchedTurn: String
    let onWatchedTurn: @Sendable () throws -> Void

    var startMarkers: [String] {
        parser.startMarkers
    }

    var readsSessionHeader: Bool {
        parser.readsSessionHeader
    }

    func isTurnStart(_ line: Data) throws -> Bool {
        try parser.isTurnStart(line)
    }

    mutating func submittedTurnID(in line: Data) throws -> String? {
        let turn = try parser.submittedTurnID(in: line)
        if turn == watchedTurn {
            try onWatchedTurn()
        }
        return turn
    }

    mutating func updateCandidate(_ candidate: String) -> AgentWorkflowTranscriptOutcome? {
        parser.updateCandidate(candidate)
    }

    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        try parser.consume(line)
    }
}

private actor AppendingCodexTestProvider: AgentWorkflowProviding {
    nonisolated let watchedTurn: String
    nonisolated let onWatchedTurn: @Sendable () throws -> Void

    init(watchedTurn: String, onWatchedTurn: @escaping @Sendable () throws -> Void) {
        self.watchedTurn = watchedTurn
        self.onWatchedTurn = onWatchedTurn
    }

    nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 10_000)
    }

    nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "test> ")
    }

    nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        AppendingCodexTestTranscript(
            parser: CodexWorkflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID),
            watchedTurn: watchedTurn, onWatchedTurn: onWatchedTurn
        )
    }
}

struct AgentWorkflowNativeEventsTests {
    @Test(arguments: ["refresh", "synchronize", "inspect"])
    func exitLoopRejectsARequestWhenExplicitTurnChanges(stage: String) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let changeTurn: @Sendable () async throws -> Void = {
            try f.writeCodexTurns("turn", "new-turn")
            _ = try await f.router.receive(f.event(.submitted, text: "Continue reviewing", turn: "new-turn"), peer: f.peer)
        }
        let service = AgentWorkflowAgentService(
            store: f.store,
            inspect: { instance in
                if stage == "inspect" {
                    try await changeTurn()
                }
                return instance
            },
            synchronizeEvents: { id in
                if stage == "synchronize" {
                    try await changeTurn()
                }
                try await f.router.requireVerifiedSubmission(id)
            },
            refreshInstances: {
                if stage == "refresh" {
                    try await changeTurn()
                }
            },
            provider: { _ in CodexPluginCore() }
        )
        let request = f.loopExitRequest()
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let run = try await f.store.snapshot().runs[0]
        #expect(run.loopExitRequest == nil)
        #expect(run.invocations[0].stepTurn?.id == "new-turn")
        #expect(await f.approvalService().handle(request, peer: f.peer).ok)
    }

    @Test(arguments: [false, true])
    func oldExplicitReceiptDoesNotReplaceTheCurrentApprovalTurn(replayContinuation: Bool) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = f.event(.submitted, text: f.invocation.delivery.input.text)
        let second = f.event(.submitted, text: "Second prompt", turn: "second")
        _ = try await f.router.receive(original, peer: f.peer)
        try f.writeCodexTurns("turn", "second")
        _ = try await f.router.receive(second, peer: f.peer)
        try f.writeCodexTurns("turn", "second", "third")
        _ = try await f.router.receive(f.event(.submitted, text: "Third prompt", turn: "third"), peer: f.peer)
        _ = try await f.router.receive(replayContinuation ? second : original, peer: f.peer)

        try f.writeCodexTurns("turn", "second", "third")
        #expect(await f.approvalService().handle(f.loopExitRequest(), peer: f.peer).ok)
        let run = try await f.store.snapshot().runs[0]
        #expect(run.invocations[0].stepTurn?.id == "third")
        #expect(run.invocations[0].stepTurn?.completionRequested == true)
    }

    @Test(arguments: ["turn", "previous-middle", "previous-result"])
    func archivedReceiptCannotReplaceApprovalInTheNextRun(replayedTurn: String) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = f.event(.submitted, text: f.invocation.delivery.input.text)
        let middle = f.event(.submitted, text: "Discuss the findings", turn: "previous-middle")
        let continuation = f.event(.submitted, text: "Finish the review", turn: "previous-result")
        _ = try await f.router.receive(original, peer: f.peer)
        try f.writeCodexTurns("turn", "previous-middle")
        _ = try await f.router.receive(middle, peer: f.peer)
        try f.writeCodexTurns("turn", "previous-middle", "previous-result")
        _ = try await f.router.receive(continuation, peer: f.peer)
        try f.writeCodexTurns("turn", "previous-middle", "previous-result")
        let service = f.approvalService()
        try #require(await service.handle(f.loopExitRequest(), peer: f.peer).ok)
        let summary = f.run.definition.nodes[2]
        let previous = try await f.store.update(runID: f.run.id) {
            try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "previous-result", text: "Approved", completedAt: .now), instance: f.instance, now: .now)
            _ = try $0.prepareInvocation(nodeID: summary.id, now: .now)
        }
        try #require(previous.status == .completed)
        let next = try await f.store.start(
            definitionID: f.run.definition.id, expectedRevision: f.run.definition.revision, requestID: UUID(),
            now: .now, authorizationExpiresAt: .now.addingTimeInterval(3_600)
        )
        let written = try await f.store.update(runID: next.id) {
            let invocation = try $0.prepareInvocation(nodeID: f.invocation.nodeID, now: .now)
            try $0.beginWriting(invocationID: invocation.id, instance: f.instance, now: .now)
        }
        let invocation = try #require(written.invocations.first)
        try f.writeCodexTurns("turn", "previous-middle", "previous-result", "current")
        _ = try await f.router.receive(f.event(.submitted, text: invocation.delivery.input.text, turn: "current"), peer: f.peer)
        let replay = try #require([original, middle, continuation].first { $0.workflow?.nativeTurnID == replayedTurn })
        _ = try await f.router.receive(replay, peer: f.peer)
        #expect(await service.handle(f.loopExitRequest(invocationID: invocation.id), peer: f.peer).ok)
        let archive = try await f.store.snapshot()
        #expect(archive.runs.first { $0.id == previous.id } == previous)
        let saved = try #require(archive.runs.first { $0.id == next.id })
        #expect(saved.loopExitRequest?.invocationID == invocation.id)
        #expect(saved.invocations.first?.stepTurn?.id == "current")
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func receiptOrderRecoversAfterHostRestart(progressAppends: Int, newerReceipt: Bool) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let middle = f.event(.submitted, text: "Discuss the findings", turn: "middle")
        try f.writeCodexTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.writeCodexTurns("turn", "middle")
        _ = try await f.router.receive(middle, peer: f.peer)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.id == "middle")
        try f.writeCodexTurns("turn", "middle", "current")
        _ = try await f.router.receive(f.event(.submitted, text: "Finish the review", turn: "current"), peer: f.peer)
        try f.writeCodexTurns("turn", "middle", "current")
        await f.router.shutdown()

        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        let restored = try await reopened.snapshot().runs[0]
        try #require(restored.status == .paused && restored.invocations[0].stepTurn?.id == "current")
        let runner = AgentWorkflowRunner(
            store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
                Issue.record("An accepted step must not be submitted again.")
            }), onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let expectedTurn = newerReceipt ? "next" : "current"
        let receipt = newerReceipt ? f.event(.submitted, text: "Continue the review", turn: expectedTurn) : middle
        if newerReceipt {
            try f.writeCodexTurns("turn", "middle", "current", expectedTurn)
        }
        let scans = LockIsolated(0)
        let allowStableRead = LockIsolated(progressAppends < 2)
        let provider = AppendingCodexTestProvider(watchedTurn: expectedTurn) {
            let scan = scans.withValue { count in
                count += 1
                return count
            }
            guard scan <= progressAppends || !allowStableRead.value else { return }
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            _ = try file.seekToEnd()
            try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8))
        }
        let router = AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: { $0 }, provider: { _ in provider })
        let service = AgentWorkflowAgentService(
            store: reopened, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            provider: { _ in CodexPluginCore() }
        )
        _ = try await router.receive(receipt, peer: f.peer)
        if progressAppends == 2 {
            #expect(scans.value >= 2)
            #expect(try await reopened.snapshot().runs[0] == restored)
            await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }
            if newerReceipt {
                let repeatReceipt = f.event(.submitted, text: "Finish the review", turn: "current")
                _ = try await router.receive(repeatReceipt, peer: f.peer)
            }
            allowStableRead.setValue(true)
            for _ in 0..<100 {
                if (try? await router.requireVerifiedSubmission(f.invocation.id)) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await router.requireVerifiedSubmission(f.invocation.id)
            #expect(scans.value >= 3)
        } else {
            #expect(scans.value >= progressAppends + 1)
        }
        let verified = try await reopened.snapshot().runs[0]
        #expect(verified.invocations[0].stepTurn?.id == expectedTurn)
        if !newerReceipt {
            #expect(verified == restored)
        }
        #expect(await service.handle(f.loopExitRequest(), peer: f.peer).ok)
        let saved = try await reopened.snapshot().runs[0]
        #expect(saved.loopExitRequest?.invocationID == f.invocation.id)
        #expect(saved.invocations[0].stepTurn?.id == expectedTurn)
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: ["restart", "restart-and-new", "new"])
    func changedAgentBindingCanReplaceAnInFlightPendingReceipt(change: String) async throws {
        let restarted = change != "new"
        let newConversation = change != "restart"
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeCodexTurns("turn")
        let original = f.event(.submitted, text: f.invocation.delivery.input.text)
        _ = try await f.router.receive(original, peer: f.peer)
        try f.appendCodexAnswer("Original discussion")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Original discussion"), peer: f.peer)
        try f.appendNativeTurn("pending")
        await f.router.shutdown()

        let oldInspection = AsyncStream<Void>.makeStream()
        defer { oldInspection.continuation.finish() }
        let inspectingOldWriter = LockIsolated(false)
        let oldInspectionEnded = LockIsolated(false)
        let changingOldRecord = LockIsolated(true)
        let unstable = AppendingCodexTestProvider(watchedTurn: "pending") {
            guard changingOldRecord.value else { return }
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            _ = try file.seekToEnd()
            try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8))
        }
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { instance in
            if instance.matchesBinding(f.instance) {
                inspectingOldWriter.setValue(true)
                defer { oldInspectionEnded.setValue(true) }
                for await _ in oldInspection.stream {
                    break
                }
                throw AgentWorkflowInspectionUnavailable()
            }
            return instance
        }, provider: { _ in unstable }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        _ = try await router.receive(f.event(.submitted, text: "Follow up before restart", turn: "pending"), peer: f.peer)
        for _ in 0..<100 {
            if inspectingOldWriter.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(inspectingOldWriter.value)
        #expect(!oldInspectionEnded.value)

        changingOldRecord.setValue(false)
        try f.appendCodexAnswer("Old discussion", turn: "pending")
        _ = try await router.receive(f.event(.stopCandidate, text: "Old discussion", turn: "pending"), peer: f.peer)

        var live = f.instance
        var peer = f.peer
        if restarted {
            var replacement = AgentWorkflowObservation(f.instance)
            replacement.processID = 20
            replacement.processRuntimeID = "501:20:200:0"
            live = try #require(await f.store.reconcile([replacement]).first)
            peer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
                pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
            })
        }
        let transcript = newConversation ? f.directory.appendingPathComponent("new-session.jsonl") : f.transcript
        if newConversation {
            live.conversationID = "new-conversation"
            try f.writeCodexTurns("resumed", conversationID: live.conversationID, to: transcript)
        } else {
            try f.appendNativeTurn("resumed")
        }
        let receipt = PluginEvent(pluginID: live.pluginID, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "resumed", transcriptPath: transcript.path, text: "Continue after restart"
        ))
        _ = try await router.receive(receipt, peer: peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let verified = try await f.store.snapshot().runs[0]
        #expect(verified.invocations[0].nativeTurnID == "turn")
        #expect(verified.invocations[0].nativeTranscriptPath == f.transcript.path)
        #expect(verified.invocations[0].stepTurn?.id == "resumed")
        #expect(verified.invocations[0].stepTurn?.transcriptPath == transcript.path)
        #expect(verified.instance(for: verified.invocations[0])?.matchesBinding(live) == true)
        for _ in 0..<100 {
            if oldInspectionEnded.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(oldInspectionEnded.value)
        let service = AgentWorkflowAgentService(
            store: f.store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            provider: { _ in CodexPluginCore() }
        )
        if restarted {
            #expect(await !service.handle(f.loopExitRequest(), peer: f.peer).ok)
        }
        #expect(await service.handle(f.loopExitRequest(), peer: peer).ok)
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.loopExitRequest?.invocationID == f.invocation.id)
        #expect(saved.invocations[0].stepTurn?.id == "resumed")
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func replayedPreviousConversationCannotBlockLoopExit(newReceiptPending: Bool) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        await f.router.shutdown()
        try f.writeCodexTurns("turn", "old-pending")

        let changingOldRecord = LockIsolated(true)
        let canInspectNewConversation = LockIsolated(!newReceiptPending)
        let provider = AppendingCodexTestProvider(watchedTurn: "old-pending") {
            guard changingOldRecord.value else { return }
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            _ = try file.seekToEnd()
            try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8))
        }
        let conversation = LockIsolated(AgentConversationEvidence(runtimeID: f.instance.processRuntimeID, conversationID: f.instance.conversationID))
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { instance in
            guard instance.conversationID == "new-conversation", canInspectNewConversation.value else {
                throw AgentWorkflowInspectionUnavailable()
            }
            return instance
        }, recheckConversation: { event, peer, admit in
            var evidence = conversation.value
            guard evidence.accept(event, nativeConversationID: nil, source: peer.processes.first) else { return .superseded }
            return admit ? .ready : .deferred
        }, provider: { _ in provider }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let dispatcher = PluginEventDispatcher(onWorkflow: { event, peer in
            do { _ = try await router.receive(event, peer: peer) }
            catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        }, onUnconfirmedSubmission: { event, peer in
            do { try await router.receiveUnconfirmedSubmission(event, peer: peer) }
            catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        }, withCurrentEvent: { event, peer, operation in
            // The process can retain both writers after /new.
            guard conversation.withValue({ $0.accept(event, nativeConversationID: nil, source: peer?.processes.first) }) else { return false }
            await operation()
            return true
        })
        let oldReceipt = f.event(.submitted, text: "Follow up in the old conversation", turn: "old-pending")
        await dispatcher.dispatch(oldReceipt, ingressPeer: f.peer)
        await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }

        changingOldRecord.setValue(false)
        try f.appendCodexAnswer("Old discussion", turn: "old-pending")
        await dispatcher.dispatch(f.event(.stopCandidate, text: "Old discussion", turn: "old-pending"), ingressPeer: f.peer)

        let transcript = f.directory.appendingPathComponent("new-session.jsonl")
        try f.writeCodexTurns("resumed", conversationID: "new-conversation", to: transcript)
        let newReceipt = PluginEvent(pluginID: f.instance.pluginID, sessionID: "new-conversation", tmuxPane: f.instance.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "resumed", transcriptPath: transcript.path, text: "Continue after /new"
        ))
        await dispatcher.dispatch(newReceipt, ingressPeer: f.peer)
        #expect(conversation.value.conversationID == newReceipt.sessionID)
        if !newReceiptPending {
            try await router.requireVerifiedSubmission(f.invocation.id)
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.id == (newReceiptPending ? "turn" : "resumed"))

        changingOldRecord.setValue(false)
        await dispatcher.dispatch(oldReceipt, ingressPeer: f.peer)
        #expect(conversation.value.conversationID == newReceipt.sessionID)
        canInspectNewConversation.setValue(true)
        for _ in 0..<100 {
            if (try? await router.requireVerifiedSubmission(f.invocation.id)) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let service = AgentWorkflowAgentService(
            store: f.store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            provider: { _ in CodexPluginCore() }
        )
        #expect(await service.handle(f.loopExitRequest(), peer: f.peer).ok)
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.invocations[0].nativeTurnID == "turn")
        #expect(saved.invocations[0].stepTurn?.id == "resumed")
        #expect(saved.loopExitRequest?.invocationID == f.invocation.id)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], ["first", "continue", "manual"])
    func submissionSurvivesUnavailableCurrentConversation(hostRestarted: Bool, submission: String) async throws {
        let continuing = submission != "first"
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.store.update(runID: f.run.id) { try $0.didWrite(invocationID: f.invocation.id) }
        if continuing {
            try f.writeCodexTurns("turn")
            _ = try await f.router.receive(f.event(.submitted, text: f.invocation.submissionText(pluginID: f.instance.pluginID)), peer: f.peer)
        }
        if submission == "continue" {
            let invocation = try await f.store.snapshot().runs[0].invocations[0]
            let authorization = try #require(await f.store.authorizeContinuation(invocation, instance: f.instance))
            try await f.store.finishContinuation(invocation, authorization: authorization, written: true)
        }
        let ledger = await f.store.fileURL
        let store = hostRestarted ? AgentWorkflowStore(fileURL: ledger, hostID: f.instance.hostID) : f.store
        let before = try await store.snapshot().runs[0]
        #expect(before.invocations[0].status == (continuing ? .running : hostRestarted ? .uncertain : .awaitingAcceptance))
        #expect(before.invocations[0].continuationInstance == (submission == "continue" ? f.instance : nil))

        let conversation = hostRestarted ? f.instance.conversationID : UUID().uuidString
        let writerAvailable = LockIsolated(false)
        let conversationAvailable = LockIsolated(false)
        let catalog = AgentRuntimeCatalog(hostID: f.instance.hostID, bridgeFile: f.directory.appendingPathComponent("bridges.json")) { _ in [] }
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("A written task must not be sent again.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, catalog: catalog, inspect: { instance in
            guard writerAvailable.value, instance.conversationID == conversation else { throw AgentWorkflowInspectionUnavailable() }
            var live = instance
            live.capabilityIssue = await catalog.bridgeIssue(for: instance, allowsFirstSubmission: false)
            return live
        }, recheckConversation: { event, _, admit in
            admit && conversationAvailable.value && event.sessionID == conversation ? .ready : .deferred
        }, provider: { _ in CodexPluginCore() }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let dispatcher = PluginEventDispatcher(onWorkflow: { event, peer in
            do { _ = try await router.receive(event, peer: peer) }
            catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        }, onUnconfirmedSubmission: { event, peer in
            do { try await router.receiveUnconfirmedSubmission(event, peer: peer) }
            catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        }, withCurrentEvent: { _, _, operation in
            guard writerAvailable.value else { return false }
            await operation()
            return true
        })
        let prompt = switch submission {
        case "manual": "Include the follow-up regression in your review."
        case "continue": AgentWorkflowPrompt.continuation(definition: before.definition, nodeID: f.invocation.nodeID, invocationID: f.invocation.id)
        default: f.invocation.submissionText(pluginID: f.instance.pluginID)
        }
        let turnID = continuing ? "resumed-turn" : "first-turn"
        let transcript = continuing && !hostRestarted ? f.directory.appendingPathComponent("new-session.jsonl") : f.transcript
        func receipt(_ text: String) -> PluginEvent {
            .init(pluginID: f.instance.pluginID, sessionID: conversation, tmuxPane: f.instance.paneID, workflow: .init(
                kind: .submitted, nativeTurnID: turnID, transcriptPath: transcript.path, text: text
            ), workflowBridgeVersion: PluginWorkflowHook.bridgeVersion)
        }
        if !continuing {
            await dispatcher.dispatch(receipt("Different task"), ingressPeer: f.peer)
        }
        let otherPeer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        await dispatcher.dispatch(receipt(prompt), ingressPeer: otherPeer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        #expect(await catalog.bridgeIssue(for: f.instance, allowsFirstSubmission: false) != nil)
        await dispatcher.dispatch(receipt(prompt), ingressPeer: f.peer)
        #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == (continuing ? "turn" : nil))
        await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }

        writerAvailable.setValue(true)
        if submission == "manual" {
            conversationAvailable.setValue(true)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
            conversationAvailable.setValue(false)
        }
        if continuing, hostRestarted {
            try f.writeCodexTurns("turn", turnID, conversationID: conversation)
        } else {
            try f.writeCodexTurns(turnID, conversationID: conversation, to: transcript)
        }
        if submission == "manual" {
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
            conversationAvailable.setValue(true)
        }
        for _ in 0..<100 {
            if (try? await router.requireVerifiedSubmission(f.invocation.id)) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let accepted = try await store.snapshot().runs[0]
        #expect(accepted.invocations[0].nativeTurnID == (continuing ? "turn" : turnID))
        #expect(accepted.invocations[0].nativeTranscriptPath == f.transcript.path)
        #expect(accepted.invocations[0].stepTurn?.id == turnID)
        #expect(accepted.invocations[0].resultTranscriptPath == transcript.path)
        let service = AgentWorkflowAgentService(
            store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            provider: { _ in CodexPluginCore() }
        )
        #expect(await service.handle(f.loopExitRequest(), peer: f.peer).ok)
        let saved = try await store.snapshot().runs[0]
        #expect(saved.loopExitRequest?.invocationID == f.invocation.id)
        await router.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], ["same", "newer", "partial", "changed-after-scan"])
    func firstApprovalAfterHostRestartUsesCurrentNativeRecord(plugin: String, transcriptState: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        func start(_ id: String) throws -> Data {
            let record: [String: Any] = plugin == "codex"
                ? ["type": "event_msg", "payload": ["type": "task_started", "turn_id": id]]
                : ["type": "user", "sessionId": f.instance.conversationID, "isSidechain": false, "promptId": id]
            return try JSONSerialization.data(withJSONObject: record) + Data([0x0A])
        }
        var bytes = Data()
        if plugin == "codex" {
            try bytes.append(JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": f.instance.conversationID]]))
            bytes.append(0x0A)
        }
        try bytes.append(start("turn"))
        let newer = try start("newer")
        if transcriptState == "newer" {
            bytes.append(newer)
        } else if transcriptState == "partial" {
            bytes.append(newer.dropLast())
        }
        try bytes.write(to: f.transcript)

        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        let restored = try await reopened.snapshot().runs[0]
        #expect(restored.status == .paused && restored.invocations[0].status == .running)
        #expect(restored.invocations[0].stepTurn?.completionRequested == false)
        let synchs = LockIsolated(0)
        let changed = bytes + newer
        let service = AgentWorkflowAgentService(store: reopened, inspect: { $0 }, synchronizeEvents: { _ in
            let count = synchs.withValue { value in
                value += 1
                return value
            }
            if transcriptState == "changed-after-scan", count == 2 {
                try changed.write(to: f.transcript)
            }
        }, provider: { plugin in
            if plugin == "codex" {
                return CodexPluginCore()
            }
            return ClaudeCodePluginCore()
        })
        let response = await service.handle(f.loopExitRequest(), peer: f.peer)
        let saved = try await reopened.snapshot().runs[0]
        if transcriptState == "same" {
            #expect(response.ok)
            #expect(saved.loopExitRequest?.invocationID == f.invocation.id)
            #expect(saved.invocations[0].stepTurn?.completionRequested == true)
        } else {
            #expect(response.error?.code == "workflow_denied")
            #expect(saved.loopExitRequest == nil)
        }
        #expect(saved.status == .paused)
    }

    @Test(arguments: [false, true])
    func laterNativeTurnCannotApproveAnEarlierReplyEndedStep(deliveredHook: Bool) async throws {
        let f = try await fixture(afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let earlier = try #require(await f.router.receive(f.event(.stopCandidate, text: "Changes required"), peer: f.peer))
        #expect(earlier.invocation.stepTurn == nil)
        if deliveredHook {
            try f.writeCodexTurns("turn")
            _ = try await f.router.receive(f.event(.submitted, text: "A separate prompt", turn: "new-turn"), peer: f.peer)
        } else {
            try f.writeCodexTurns("turn", "new-turn")
        }
        #expect(await f.approvalService().handle(f.loopExitRequest(), peer: f.peer).error?.code == "workflow_denied")
        let result = AgentWorkflowResult(invocationID: f.invocation.id, nativeTurnID: "turn", text: "Changes required", completedAt: .now)
        let saved = try await f.store.update(runID: f.run.id) { try $0.succeed(result, instance: f.instance, now: .now) }
        #expect(saved.loopExitRequest == nil)
        #expect(try AgentWorkflowExecution(validating: saved).readyNodeIDs == [f.run.definition.nodes[1].id])
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @MainActor
    @Test
    func continuesExplicitApprovalWithBothOutcomeCommands() async throws {
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Waiting for a decision"), peer: f.peer)
        let delivery = AgentWorkflowTerminalTransport(
            store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"),
            inspect: { $0 }, submit: { _, file, _, validate, _ in
                let prompt = try String(contentsOf: file, encoding: .utf8)
                let invocation = f.invocation.id.uuidString
                #expect(prompt.contains("approval condition is met, use ctrlx workflow exit-loop --invocation \(invocation)"))
                #expect(prompt.contains("approval condition is not met, run ctrlx workflow complete-step --invocation \(invocation)"))
                #expect(prompt.contains("[CtrlX workflow invocation: \(invocation)]"))
                try validate { }
            }, onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let service = AgentWorkflowService(store: f.store, scan: { _ in [AgentWorkflowObservation(f.instance)] }, schedule: { _ in }, resumeStep: {
            try await delivery.resumeStep($0, instance: $1)
        })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await service.pause(runID: current.id, expectedRevision: current.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.invocations[0].continuationTurnID == "turn")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test("A stale catalog conversation cannot swallow an accepted turn's result", arguments: ["codex", "claude-code"])
    func acceptedResultSurvivesStaleCatalog(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        var stale = AgentWorkflowObservation(f.instance)
        stale.conversationID = "before-new"
        stale.readiness = .unavailable
        _ = try await f.store.reconcile([stale])
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running && waiting.issue != nil)
        #expect(waiting.invocations[0].instance?.conversationID == f.instance.conversationID)

        let unrelated = PluginEvent(pluginID: plugin, sessionID: stale.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: "Unrelated"
        ))
        #expect(try await f.router.receive(unrelated, peer: f.peer) == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Wrong turn", turn: "other", plugin: plugin), peer: f.peer) == nil)
        let context = try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished", plugin: plugin), peer: f.peer))
        try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
        let inspections = LockIsolated(0)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { instance in
            #expect(instance.matchesBinding(f.instance))
            inspections.withValue { $0 += 1 }
            return instance
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(context, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
        let completed = try await f.store.snapshot().runs[0]
        #expect(completed.status == .completed)
        #expect(completed.invocations.count == 1)
        #expect(completed.invocations[0].result?.nativeTurnID == "turn")
        #expect(completed.invocations[0].result?.text == "Finished")
        #expect(inspections.value >= 2)
        #expect(try await f.store.snapshot().instances[0].conversationID == stale.conversationID)
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func restartedTabCanCompleteItsExplicitStep(plugin: String, newConversation: Bool) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit, allowsFinish: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        try f.appendNativeAnswer("Original discussion")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Original discussion", plugin: plugin), peer: f.peer)
        _ = try await f.store.reconcile([])
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running && waiting.issue?.contains("Waiting for Agent") == true)

        var observation = AgentWorkflowObservation(f.instance)
        observation.processID = 20
        observation.processRuntimeID = "501:20:200:0"
        if newConversation {
            observation.conversationID = "resumed-conversation"
        }
        let live = try #require(await f.store.reconcile([observation]).first)
        let peer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        let service = AgentWorkflowAgentService(store: f.store, inspect: { instance in
            #expect(instance.matchesBinding(live))
            return instance
        }, synchronizeEvents: { id in try await f.router.requireVerifiedSubmission(id) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await !service.handle(request, peer: f.peer).ok)
        // A new writer cannot select the old turn before its own receipt arrives.
        #expect(await !service.handle(request, peer: peer).ok)

        let inputs = LockIsolated<[String]>([])
        let delivery = await AgentWorkflowTerminalTransport(
            store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"),
            inspect: { $0 }, submit: { target, file, images, validate, _ in
                #expect(target.matchesBinding(live))
                #expect(images.isEmpty)
                let text = try String(contentsOf: file, encoding: .utf8)
                try validate { inputs.withValue { $0.append(text) } }
            }, onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        let management = AgentWorkflowService(
            store: f.store,
            scan: { _ in [AgentWorkflowObservation(live)] },
            schedule: { _ in },
            resumeStep: { try await delivery.resumeStep($0, instance: $1) }
        )
        for _ in 0..<2 {
            let current = try await f.store.snapshot().runs[0]
            let paused = try await management.pause(runID: current.id, expectedRevision: current.revision)
            let resumed = try await management.resume(runID: paused.id, expectedRevision: paused.revision)
            #expect(resumed.status == .running)
            #expect(resumed.invocations[0].continuationTurnID == "turn")
        }
        let prompt = try #require(inputs.value.first)
        #expect(inputs.value.count == 1)
        #expect(prompt.contains("complete-step --invocation \(f.invocation.id.uuidString)"))
        #expect(!prompt.contains("Initial task:"))
        let saved = try JSONDecoder().decode(AgentWorkflowArchive.self, from: Data(contentsOf: f.directory.appendingPathComponent("ledger.json")))
        #expect(saved.runs[0].invocations[0].continuationTurnID == "turn")
        let restored = try AgentWorkflowExecution(restoring: saved.runs[0])
        #expect(restored.run.invocations[0].continuationTurnID == "turn")
        let transcript = newConversation ? f.directory.appendingPathComponent("after-login.jsonl") : f.transcript
        let submitted = PluginEvent(pluginID: plugin, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "after-login", transcriptPath: transcript.path, text: prompt
        ))
        if newConversation {
            if plugin == "codex" {
                try f.writeCodexTurns("after-login", conversationID: live.conversationID, to: transcript)
            } else {
                let record: [String: Any] = [
                    "type": "user",
                    "uuid": "after-login-user",
                    "promptId": "after-login",
                    "sessionId": live.conversationID,
                    "isSidechain": false,
                ]
                try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: transcript)
            }
        } else {
            try f.appendNativeTurn("after-login")
        }
        _ = try await f.router.receive(submitted, peer: peer)
        try #require(await service.handle(request, peer: peer).ok)
        let continued = try await f.store.snapshot().runs[0]
        #expect(continued.status == .running && continued.issue == nil)
        #expect(continued.invocations.count == 1)
        #expect(continued.invocations[0].nativeTurnID == "turn")
        #expect(continued.invocations[0].stepTurn?.id == "after-login")
        #expect(continued.invocations[0].stepTurn?.completionRequested == true)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Old result", plugin: plugin), peer: f.peer) == nil)
        let stale = PluginEvent(pluginID: plugin, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: "Old result"
        ))
        #expect(try await f.router.receive(stale, peer: peer) == nil)
        let finish = JSONRPCRequest(id: "finish", method: "workflow.finish", params: [
            "invocationId": .string(f.invocation.id.uuidString), "reason": .string("Finished after login"),
        ])
        try #require(await service.handle(finish, peer: peer).ok)

        try Data("{\"final\":\"Finished after login\"}\n".utf8).write(to: transcript)
        let stop = PluginEvent(pluginID: plugin, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .stopCandidate, nativeTurnID: "after-login", transcriptPath: transcript.path, text: "Finished after login"
        ))
        let context = try #require(await f.router.receive(stop, peer: peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(context, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await f.store.snapshot().runs[0]
        #expect(completed.status == .completed)
        #expect(completed.invocations[0].result?.nativeTurnID == "after-login")
        #expect(completed.invocations[0].result?.text == "Finished after login")
        #expect(try AgentWorkflowExecution(validating: completed).run == completed)
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func finalVerificationWaitsForResumedConversation(plugin: String, moved: Bool) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished", plugin: plugin), peer: f.peer))
        _ = try await f.store.reconcile([])
        try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            #expect($0.processID == 20)
            return $0
        }, verificationTimeout: .milliseconds(30), onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        try await Task.sleep(for: .milliseconds(100))
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running && waiting.invocations[0].result == nil)
        var observation = AgentWorkflowObservation(f.instance)
        observation.processID = 20
        observation.processRuntimeID = "501:20:200:0"
        if moved {
            observation.workspacePane.windowID = UUID()
        }
        _ = try await f.store.reconcile([observation])
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await f.store.snapshot().runs[0].status == .completed)
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], ["receipt", "stop", "continuation"])
    func movedPaneAfterCatalogRefreshKeepsNativeEvents(plugin: String, stage: String) async throws {
        let f = try await fixture(plugin: plugin, completion: stage == "continuation" ? .explicit : .replyEnded)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if stage != "receipt" {
            _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        }
        var moved = AgentWorkflowObservation(f.instance)
        moved.workspacePane.windowID = UUID()
        moved.workspacePane.sessionID = UUID()
        let live = try #require(await f.store.reconcile([moved]).first)
        #expect(live.matchesBinding(f.instance))
        #expect(live.target != f.instance.target)
        var turn = "turn"
        if stage == "receipt" {
            _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        } else if stage == "continuation" {
            turn = "discussion"
            try f.writeNativeTurns("turn", turn)
            _ = try await f.router.receive(f.event(.submitted, text: "Continue this task", turn: turn, plugin: plugin), peer: f.peer)
            let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { _ in })
            let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
            try #require(await service.handle(request, peer: f.peer).ok)
        }
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished", turn: turn, plugin: plugin), peer: f.peer))
        try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == .completed)
        #expect(saved.invocations.count == 1)
        #expect(saved.invocations[0].result?.text == "Finished")
        #expect(saved.invocations[0].result?.nativeTurnID == turn)
        #expect(saved.invocations[0].instance?.target == f.instance.target)
        _ = try AgentWorkflowExecution(validating: saved)
    }

    @Test(arguments: ["submission", "stop", "inspection", "rotation"])
    func completionMonitorFollowsLivePaneMove(stage: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = try #require(await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer))
        let initial = stage == "submission" ? submission : try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished"), peer: f.peer))
        var observation = AgentWorkflowObservation(f.instance)
        observation.workspacePane.windowID = UUID()
        observation.workspacePane.sessionID = UUID()
        let moved = observation
        let inspected = LockIsolated(0), parsed = LockIsolated(0)
        let provider = NativeWorkflowTestProvider { parsed.withValue { $0 += 1 } }
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { instance in
            let count = inspected.withValue { $0 += 1
                return $0
            }
            if stage == "inspection", count == 1 {
                return try #require(await f.store.reconcile([moved]).first)
            }
            return instance
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        if stage != "stop", stage != "rotation" {
            try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
        }
        await monitor.verify(initial, provider: provider)
        if stage != "inspection" {
            for _ in 0..<200 {
                if stage == "submission" ? parsed.value > 0 : inspected.value > 0 {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(inspected.value > 0)
            _ = try await f.store.reconcile([moved])
            if stage == "submission" {
                let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished"), peer: f.peer))
                await monitor.verify(stop, provider: provider)
            } else {
                try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript, options: stage == "rotation" ? .atomic : [])
            }
        }
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == .completed && saved.invocations[0].result?.text == "Finished")
        #expect(parsed.value == 1)
        _ = try AgentWorkflowExecution(validating: saved)
    }

    @Test(arguments: ["process", "conversation"])
    func movedPaneCannotUseAnotherWriterOrConversation(change: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Finished"), peer: f.peer))
        var moved = AgentWorkflowObservation(f.instance)
        moved.workspacePane.windowID = UUID()
        if change == "process" {
            moved.processRuntimeID = "501:10:200:0"
        } else {
            moved.conversationID = "another-conversation"
        }
        _ = try await f.store.reconcile([moved])
        let peer = try #require(PluginIngressPeer.capture(peerPID: 10, userID: 501) { pid in
            pid == 10 ? .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: change == "process" ? 200 : 100, startMicroseconds: 0) : nil
        })
        let routed = try await f.router.receive(f.event(.stopCandidate, text: "Finished"), peer: peer)
        #expect((routed != nil) == (change == "conversation"))
        let event = PluginEvent(pluginID: "codex", sessionID: moved.conversationID, tmuxPane: "%1", workflow: .init(
            kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: "Finished"
        ))
        #expect(try await f.router.receive(event, peer: peer) == nil)
        if change == "process" {
            // The replacement cannot supply the old Stop. The previously verified
            // Stop may still finish its original turn after native Resume.
            await f.router.shutdown()
            await f.runner.shutdown()
            #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
            return
        }
        try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
        let inspections = LockIsolated(0)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            // The directory alone cannot reject a candidate. Native inspection
            // must still refuse a writer that actually switched conversations.
            #expect($0.conversationID == f.instance.conversationID)
            inspections.withValue { $0 += 1 }
            throw AgentWorkflowInspectionUnavailable()
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        try await Task.sleep(for: .milliseconds(100))
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
        #expect(inspections.value > 0)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
    }

    @Test
    func failedAttemptReceiptCannotInterruptItsRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await f.router.receive(f.event(.failed, text: "Quota exceeded"), peer: f.peer)
        let resumed = try await f.store.update(runID: f.run.id) {
            try $0.resume(instances: [f.instance], now: Date())
            let retry = try $0.prepareInvocation(nodeID: f.invocation.nodeID, now: Date())
            try $0.beginWriting(invocationID: retry.id, instance: f.instance, now: Date())
        }
        let retry = try #require(resumed.invocations.last)
        let unavailable = LockIsolated(true)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            if unavailable.value {
                throw AgentWorkflowInspectionUnavailable()
            }
            return $0
        })
        #expect(try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer) == nil)
        #expect(try await router.receive(f.event(.stopCandidate, text: "Old answer"), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0] == resumed)
        unavailable.setValue(false)
        _ = try await router.receive(f.event(.submitted, text: retry.delivery.input.text, turn: "retry"), peer: f.peer)
        let current = try await f.store.snapshot().runs[0]
        #expect(current.status == .running)
        #expect(current.invocations[0].status == .failed)
        #expect(current.invocations[1].nativeTurnID == "retry")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], ["ready", "busy", "draft", "question", "unavailable", "confirmed", "replyEnded"])
    @MainActor
    func continueOnlyNudgesReadyUnconfirmedStep(plugin: String, state: String) async throws {
        let f = try await fixture(plugin: plugin, completion: state == "replyEnded" ? .replyEnded : .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        if state == "confirmed" {
            try await f.store.update(runID: f.run.id) {
                try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
        }
        let readiness: AgentWorkflowReadiness = switch state {
        case "busy": .busy
        case "draft": .draft
        case "question": .awaitingHuman
        case "unavailable": .unavailable
        default: .ready
        }
        var observation = AgentWorkflowObservation(f.instance)
        observation.readiness = readiness
        let observed = observation
        let sent = LockIsolated(0)
        let delivery = AgentWorkflowTerminalTransport(store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"), inspect: { $0 }, submit: { _, _, images, validate, _ in
            #expect(images.isEmpty)
            try validate { sent.withValue { $0 += 1 } }
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let service = AgentWorkflowService(store: f.store, scan: { _ in [observed] }, schedule: { _ in }, resumeStep: { try await delivery.resumeStep($0, instance: $1) })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await service.pause(runID: current.id, expectedRevision: current.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.status == .running)
        #expect(sent.value == (state == "ready" ? 1 : 0))
        #expect(resumed.invocations.count == 1)
        #expect(resumed.invocations[0].nativeTurnID == "turn")
        #expect(resumed.invocations[0].delivery == f.invocation.delivery)
        #expect(resumed.invocations[0].result == nil)
        if state == "ready" {
            var execution = try AgentWorkflowExecution(validating: resumed)
            #expect(throws: AgentWorkflowError.self) {
                try execution.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
            // A Host restart retains the attempted marker; Continue cannot resend it.
            let recovered = AgentWorkflowStore(fileURL: f.directory.appendingPathComponent("ledger.json"), hostID: f.instance.hostID)
            let restored = try await recovered.snapshot().runs[0]
            let retry = AgentWorkflowService(store: recovered, scan: { _ in [observed] }, schedule: { _ in }, resumeStep: { _, _ in Issue.record("A persisted reminder must not be repeated") })
            _ = try await retry.resume(runID: restored.id, expectedRevision: restored.revision)
        }
    }

    @Test(arguments: ["codex", "claude-code"])
    @MainActor
    func continuationAcceptsStopArrivingDuringReadinessCheck(plugin: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        let writes = LockIsolated(0)
        let delivery = AgentWorkflowTerminalTransport(store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"), inspect: { instance in
            _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal awaiting confirmation", plugin: plugin), peer: f.peer)
            return instance
        }, submit: { _, _, _, validate, _ in
            try validate { writes.withValue { $0 += 1 } }
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let service = AgentWorkflowService(store: f.store, scan: { _ in [AgentWorkflowObservation(f.instance)] }, schedule: { _ in }, resumeStep: { try await delivery.resumeStep($0, instance: $1) })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await service.pause(runID: current.id, expectedRevision: current.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(writes.value == 1)
        #expect(resumed.invocations[0].stepTurn?.stopped == true)
        #expect(resumed.invocations[0].continuationTurnID == "turn")
        #expect(resumed.invocations[0].result == nil)
        #expect(resumed.status == .running)
    }

    @Test(arguments: [AgentWorkflowReadiness.busy, .draft, .awaitingHuman, .unavailable])
    @MainActor
    func continuationRechecksReadinessWithoutPausing(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let delivery = AgentWorkflowTerminalTransport(store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"), inspect: {
            var live = $0
            live.readiness = readiness
            return live
        }, submit: { _, _, _, _, _ in Issue.record("The input is no longer ready") }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let service = AgentWorkflowService(store: f.store, scan: { _ in [AgentWorkflowObservation(f.instance)] }, schedule: { _ in }, resumeStep: { try await delivery.resumeStep($0, instance: $1) })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await service.pause(runID: current.id, expectedRevision: current.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.status == .running)
        #expect(resumed.invocations[0].continuationTurnID == nil)
    }

    @Test
    @MainActor
    func concurrentContinuationsShareOneAttemptWithoutReplayingImagesOrModels() async throws {
        let f = try await fixture(imageCount: 1, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.submissionText(pluginID: "codex")), peer: f.peer)
        let invocation = try await f.store.snapshot().runs[0].invocations[0]
        let writes = LockIsolated(0)
        let delivery = AgentWorkflowTerminalTransport(
            store: f.store,
            gate: .init(),
            temporaryDirectory: f.directory.appendingPathComponent("input"),
            inspect: { $0 },
            loadModels: { _ in Issue.record("Continue must preserve the current model") },
            configureModel: { _, _, _ in Issue.record("Continue must preserve the current model") },
            submit: { _, file, images, validate, _ in
                #expect(images.isEmpty)
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("[Image #"))
                try validate { writes.withValue { $0 += 1 } }
            },
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        async let first: Void = delivery.resumeStep(invocation, instance: f.instance)
        async let second: Void = delivery.resumeStep(invocation, instance: f.instance)
        _ = try await (first, second)
        #expect(writes.value == 1)
        #expect(try await f.store.snapshot().runs[0].status == .running)
        #expect(try await f.store.snapshot().runs[0].invocations[0].nativeImageNumbers == [3])
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    @MainActor
    func continuationRetriesOnlyConfirmedRejection(plugin: String, rejected: Bool) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        let launches = LockIsolated(0)
        let inputs = LockIsolated<[String]>([])
        let delivery = AgentWorkflowTerminalTransport(store: f.store, gate: .init(), temporaryDirectory: f.directory.appendingPathComponent("input"), inspect: { $0 }, submit: { _, file, _, validate, _ in
            try validate { launches.withValue { $0 += 1 } }
            if launches.value == 1 {
                if rejected {
                    throw AgentWorkflowInputNotWritten(reason: "tmux rejected the changed cursor before paste")
                }
                throw AgentWorkflowError("Lost tmux response; the input may have been written")
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            inputs.withValue { $0.append(text) }
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let service = AgentWorkflowService(store: f.store, scan: { _ in [AgentWorkflowObservation(f.instance)] }, schedule: { _ in }, resumeStep: { try await delivery.resumeStep($0, instance: $1) })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await service.pause(runID: current.id, expectedRevision: current.revision)
        let failed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(failed.status == .paused)
        #expect(launches.value == 1)
        #expect(failed.invocations[0].continuationTurnID == (rejected ? nil : "turn"))
        if rejected {
            #expect(failed.invocations[0].issue == nil)
        }
        let retried = try await service.resume(runID: failed.id, expectedRevision: failed.revision)
        #expect(retried.status == .running)
        #expect(launches.value == (rejected ? 2 : 1))
        #expect(inputs.value.count == (rejected ? 1 : 0))
        #expect(retried.invocations.count == 1)
        #expect(retried.invocations[0].nativeTurnID == "turn")
        if rejected, let text = inputs.value.first {
            try f.writeNativeTurns("turn", "continued")
            _ = try await f.router.receive(f.event(.submitted, text: text, turn: "continued", plugin: plugin), peer: f.peer)
            let completed = try await f.store.update(runID: f.run.id) {
                try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "continued", now: Date())
            }
            #expect(completed.invocations[0].stepTurn?.completionRequested == true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("input").path).isEmpty)
    }

    @Test(arguments: ["pause", "end", "human", "turn", "completion", "replacement", "beforeWrite", "afterWrite"])
    @MainActor
    func continuationChecksFinalWriteBoundary(change: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let invocation = try await f.store.snapshot().runs[0].invocations[0]
        let gate = AgentWorkflowInputGate()
        let writes = LockIsolated(0)
        var human: Task<Void, Error>?
        let delivery = AgentWorkflowTerminalTransport(store: f.store, gate: gate, temporaryDirectory: f.directory.appendingPathComponent("input"), inspect: { $0 }, submit: { _, _, _, validate, _ in
            switch change {
            case "pause",
                 "end":
                try await f.store.update(runID: f.run.id) {
                    if change == "pause" {
                        $0.pause(reason: "operator")
                    } else {
                        $0.end()
                    }
                }
            case "human":
                let before = gate.claim(paneID: f.instance.paneID)
                human = Task { try await gate.human(paneID: f.instance.paneID) { } }
                while (try? gate.validate(before)) != nil {
                    await Task.yield()
                }
            case "turn":
                try f.writeNativeTurns("turn", "human")
                _ = try await f.router.receive(f.event(.submitted, text: "Human continuation", turn: "human"), peer: f.peer)
            case "completion":
                try await f.store.update(runID: f.run.id) {
                    try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
                }
            case "replacement":
                var observation = AgentWorkflowObservation(f.instance)
                observation.processRuntimeID = "new-process"
                _ = try await f.store.reconcile([observation])
            case "beforeWrite":
                throw AgentWorkflowInputNotWritten(reason: "capture failed")
            default: break
            }
            try validate { writes.withValue { $0 += 1 } }
            if change == "afterWrite" {
                throw AgentWorkflowError("Lost reply after paste")
            }
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await #expect(throws: (any Error).self) { try await delivery.resumeStep(invocation, instance: f.instance) }
        try await human?.value
        let updated = try await f.store.snapshot().runs[0]
        #expect(writes.value == (change == "afterWrite" ? 1 : 0))
        #expect(updated.invocations[0].continuationTurnID == (change == "afterWrite" ? "turn" : nil))
        #expect(updated.invocations[0].nativeTurnID == "turn")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("input").path).isEmpty)
    }

    private struct Fixture: Sendable {
        let directory: URL
        let transcript: URL
        let store: AgentWorkflowStore
        let runner: AgentWorkflowRunner
        let router: AgentWorkflowEventRouter
        let run: AgentWorkflowRun
        let instance: AgentWorkflowInstance
        let invocation: AgentWorkflowInvocation
        let peer: PluginIngressPeer

        func loopExitRequest(invocationID: UUID? = nil) -> JSONRPCRequest {
            .init(id: "exit", method: "workflow.exitLoop", params: [
                "invocationId": .string((invocationID ?? invocation.id).uuidString), "reason": .string("Approved"),
            ])
        }

        func approvalService() -> AgentWorkflowAgentService {
            AgentWorkflowAgentService(
                store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
                provider: { _ in CodexPluginCore() }
            )
        }

        func writeCodexTurns(_ ids: String..., conversationID: String? = nil, to destination: URL? = nil) throws {
            let path = destination ?? transcript
            let old = (try? Data(contentsOf: path))?.split(separator: 10).compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            } ?? []
            let sameConversation = (old.first?["payload"] as? [String: Any])?["id"] as? String == (conversationID ?? instance.conversationID)
            let starts = sameConversation ? old.filter { ($0["payload"] as? [String: Any])?["type"] as? String == "task_started" } : []
            var records: [[String: Any]] = [["type": "session_meta", "payload": ["id": conversationID ?? instance.conversationID]]]
            records += ids.enumerated().map { index, id in
                let previous = starts.indices.contains(index) && (starts[index]["payload"] as? [String: Any])?["turn_id"] as? String == id ? starts[index]["timestamp"] as? String : nil
                return [
                    "type": "event_msg",
                    "timestamp": previous ?? Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                    "payload": ["type": "task_started", "turn_id": id],
                ]
            }
            var bytes = Data()
            for record in records {
                try bytes.append(JSONSerialization.data(withJSONObject: record))
                bytes.append(0x0A)
            }
            try bytes.write(to: destination ?? transcript)
        }

        var nativeProvider: any AgentWorkflowProviding {
            if instance.pluginID == "claude-code" {
                ClaudeCodePluginCore()
            } else {
                CodexPluginCore()
            }
        }

        private func nativeTurn(_ id: String, index: Int) throws -> Data {
            let record: [String: Any] = if instance.pluginID == "claude-code" {
                ["type": "user", "sessionId": instance.conversationID, "isSidechain": false, "uuid": UUID().uuidString, "promptId": id]
            } else {
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": id]]
            }
            // Use the same logical timeline as hookPeer(startedAt:).
            let timed = record.merging(["timestamp": Date(timeIntervalSince1970: 100 + Double(index) * 2).formatted(.iso8601)]) { _, new in new }
            return try JSONSerialization.data(withJSONObject: timed) + Data([10])
        }

        func writeNativeTurns(_ ids: String...) throws {
            var bytes = Data()
            if instance.pluginID == "codex" {
                bytes = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": instance.conversationID]]) + Data([10])
            }
            for (index, id) in ids.enumerated() {
                try bytes.append(nativeTurn(id, index: index))
            }
            try bytes.write(to: transcript)
        }

        func appendNativeTurn(_ id: String) throws {
            let starts = try Data(contentsOf: transcript).split(separator: 10).filter { line in
                let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                return (record?["type"] as? String == "user" && record?["promptId"] is String)
                    || ((record?["payload"] as? [String: Any])?["type"] as? String == "task_started")
            }.count
            let file = try FileHandle(forWritingTo: transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: nativeTurn(id, index: starts))
        }

        func appendCodexAnswer(_ answer: String, turn: String = "turn") throws {
            let record: [String: Any] = [
                "type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": answer],
            ]
            var bytes = try JSONSerialization.data(withJSONObject: record)
            bytes.append(10)
            let file = try FileHandle(forWritingTo: transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: bytes)
        }

        func appendCodexAbort(_ turn: String) throws {
            let record: [String: Any] = ["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": turn]]
            let file = try FileHandle(forWritingTo: transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        }

        func replaceProcess(in store: AgentWorkflowStore) async throws -> PluginIngressPeer {
            var observation = AgentWorkflowObservation(instance)
            observation.processID = 20
            observation.processRuntimeID = "501:20:200:0"
            _ = try await store.reconcile([observation])
            return try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
                pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
            })
        }

        func runner(in store: AgentWorkflowStore) -> AgentWorkflowRunner {
            .init(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
                Issue.record("Recovery must not resend a task.")
            }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        }

        func appendNativeAnswer(_ answer: String, turn: String = "turn") throws {
            if instance.pluginID == "codex" {
                try appendCodexAnswer(answer, turn: turn)
                return
            }
            let user = try Data(contentsOf: transcript).split(separator: 10).reversed().compactMap { line -> String? in
                guard
                    let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    record["type"] as? String == "user", record["promptId"] as? String == turn else { return nil }
                return record["uuid"] as? String
            }.first
            let parent = try #require(user)
            let reply = UUID().uuidString
            let records: [[String: Any]] = [
                [
                    "type": "assistant",
                    "uuid": reply,
                    "parentUuid": parent,
                    "message": ["id": reply, "stop_reason": "end_turn", "content": [["type": "text", "text": answer]]],
                ],
                [
                    "type": "system",
                    "subtype": "stop_hook_summary",
                    "uuid": UUID().uuidString,
                    "parentUuid": reply,
                    "hookErrors": [],
                    "hookAdditionalContext": [],
                    "preventedContinuation": false,
                    "stopReason": "",
                ],
            ]
            let file = try FileHandle(forWritingTo: transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            for record in records {
                let native = record.merging(["sessionId": instance.conversationID, "isSidechain": false]) { current, _ in current }
                try file.write(contentsOf: JSONSerialization.data(withJSONObject: native) + Data([10]))
            }
        }

        func event(
            _ kind: PluginWorkflowEvent.Kind, text: String, turn: String = "turn", plugin: String = "codex", hasPendingWork: Bool = false
        ) -> PluginEvent {
            .init(pluginID: plugin, sessionID: "conversation", tmuxPane: "%1", workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: transcript.path, text: text, hasPendingWork: hasPendingWork
            ))
        }

        func hookPeer(startedAt: UInt64, source: PluginIngressPeer? = nil) throws -> PluginIngressPeer {
            let writer = try #require((source ?? peer).processes.first)
            let hookPID = Int32(startedAt)
            return try #require(PluginIngressPeer.capture(peerPID: hookPID, userID: writer.userID) { pid in
                if pid == hookPID {
                    return .init(processID: hookPID, parentProcessID: writer.processID, userID: writer.userID, startSeconds: startedAt, startMicroseconds: 0)
                }
                return pid == writer.processID ? writer : nil
            })
        }
    }

    private func fixture(conversation: String = "conversation", imageCount: Int = 0, plugin: String = "codex", completion: AgentWorkflowNode.Completion = .replyEnded, allowsFinish: Bool = false, afterLoop: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-events-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("native.jsonl")
        try Data().write(to: transcript)
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID)
        let instance = try #require(await store.reconcile([.init(
            pluginID: plugin, processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: conversation, displayName: "Developer", workingDirectory: directory.path,
            capabilities: .init(maximumInputBytes: 10_000, mediaTypes: ["image/png"]), readiness: .ready
        )]).first)
        var imageIDs: [UUID] = []
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=")!
        for _ in 0..<imageCount {
            let id = UUID(), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            _ = try await store.uploadAttachment(.image(id: id, name: "task.png", mediaType: "image/png", data: bytes, sha256: hash))
            imageIDs.append(id)
        }
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id, allowsFinish: allowsFinish, completion: completion)
        var draft = AgentWorkflowDefinition(name: "Test", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(attachmentIDs: imageIDs))
        if afterLoop {
            let repair = AgentWorkflowNode(name: "Repair", content: .init(text: "Fix findings"))
            let summary = AgentWorkflowNode(name: "Summary", content: .init(text: "Summarize review"))
            draft.nodes += [repair, summary]
            draft.edges = [.init(source: node.id, target: repair.id), .init(source: node.id, target: summary.id)]
            draft.loop = .init(finalNodeID: repair.id, exitNodeID: summary.id)
        }
        let definition = try await store.saveDefinition(draft, expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        let written = try await store.update(runID: run.id) {
            let invocation = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            if imageCount > 0 {
                try $0.recordImageInput(invocationID: invocation.id, numbers: (0..<imageCount).map { 3 + $0 * 2 }, now: Date())
            }
        }
        let invocation = try #require(written.invocations.first)
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("The fixture already wrote its task; it must not be submitted again.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { plugin in
            if plugin == "claude-code" {
                return ClaudeCodePluginCore()
            }
            return CodexPluginCore()
        })
        let peer = try #require(PluginIngressPeer.capture(peerPID: 10, userID: 501) { pid in
            pid == 10 ? .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0) : nil
        })
        return .init(
            directory: directory,
            transcript: transcript,
            store: store,
            runner: runner,
            router: router,
            run: run,
            instance: instance,
            invocation: invocation,
            peer: peer
        )
    }

    @Test(arguments: ["codex", "claude-code"], ["workflow.completeStep", "workflow.finish"])
    func completionWaitsForAcknowledgedHooks(plugin: String, method: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit, allowsFinish: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = LockIsolated(false), synchronizing = LockIsolated(false), completed = LockIsolated(false)
        let dispatcher = PluginEventDispatcher(onState: { _, session, _, _, _, _ in
            if session == "blocked" {
                entered.setValue(true)
                for await _ in gate.stream {
                    break
                }
            } else {
                do {
                    try f.writeNativeTurns("turn", "B")
                    _ = try await f.router.receive(f.event(.submitted, text: "Implement the design", turn: "B", plugin: plugin), peer: f.peer)
                } catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
            }
        })
        let core = EchoPluginCore()
        let path = "\(NSTemporaryDirectory())wf-\(UUID().uuidString.prefix(8)).sock"
        let ingress = IngressSocketServer(socketPath: path, coreLookup: { _ in core }, dispatcher: dispatcher)
        try await ingress.start()
        defer { Task { await ingress.stop() } }
        try await enqueueAcknowledgedHook(session: "blocked", path: path)
        try await enqueueAcknowledgedHook(session: "B", path: path)
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            synchronizing.setValue(true)
            try await ingress.waitForPendingFrames()
            try await f.router.requireVerifiedSubmission($0)
        })
        var params: [String: JSONValue] = ["invocationId": .string(f.invocation.id.uuidString)]
        if method == "workflow.finish" {
            params["reason"] = .string("Implemented")
        }
        let request = JSONRPCRequest(id: "complete", method: method, params: params)
        let response = Task {
            let result = await service.handle(request, peer: f.peer)
            completed.setValue(true)
            return result
        }
        for _ in 0..<100 {
            if entered.value && synchronizing.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.value && synchronizing.value)
        #expect(!completed.value)
        let before = try await f.store.snapshot().runs[0].invocations[0]
        #expect(before.stepTurn?.id == "turn" && before.stepTurn?.completionRequested == false)
        gate.continuation.finish()
        try #require(await response.value.ok)
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.invocations[0].nativeTurnID == "turn")
        #expect(saved.invocations[0].stepTurn?.id == "B" && saved.invocations[0].stepTurn?.completionRequested == true)
        #expect((saved.finishRequest != nil) == (method == "workflow.finish"))
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Old design proposal", plugin: plugin), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Implemented", turn: "B", plugin: plugin), peer: f.peer))
        #expect(stop.candidate.nativeTurnID == "B")
        await ingress.stop()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func resultCommitDrainsAcknowledgedStop(live: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        if !live {
            try await f.store.update(runID: f.run.id) {
                $0.waitForResult(invocationID: f.invocation.id, turnID: "turn", reason: "Waiting for final Stop")
            }
        }
        let original = try #require(await f.store.snapshot().runs.first)
        try f.writeCodexTurns("turn")
        try f.appendCodexAnswer("Background checks are running")
        let stop = PluginEvent(pluginID: "codex", sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: f.transcript.path,
            text: "Background checks are running", hasPendingWork: true
        ))
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let queued = LockIsolated(false), scheduled = LockIsolated(false)
        let activeMonitor = LockIsolated<AgentWorkflowCompletionMonitor?>(nil)
        let dispatcher = PluginEventDispatcher(onState: { _, _, _, _, _, _ in
            for await _ in gate.stream {
                break
            }
            do {
                if let context = try await f.router.receive(stop, peer: f.peer) {
                    await activeMonitor.value?.verify(context, provider: CodexPluginCore())
                }
            } catch { Issue.record(error) }
        })
        let path = "\(NSTemporaryDirectory())wf-\(UUID().uuidString.prefix(8)).sock"
        let ingress = IngressSocketServer(socketPath: path, coreLookup: { _ in EchoPluginCore() }, dispatcher: dispatcher)
        try await ingress.start()
        defer { Task { await ingress.stop() } }
        let passes = LockIsolated(0)
        let synchronize: @Sendable () async throws -> Void = {
            let pass = passes.withValue { $0 += 1
                return $0
            }
            if pass == (live ? 1 : 2) {
                try await enqueueAcknowledgedHook(session: "queued-stop", path: path)
                queued.setValue(true)
            }
            try await ingress.waitForPendingFrames()
        }
        let resume: Task<AgentWorkflowRun, any Error>?
        if live {
            let monitor = AgentWorkflowCompletionMonitor(
                store: f.store, runner: f.runner, inspect: { $0 }, synchronizeIngress: synchronize,
                onFailure: { Issue.record(Comment(rawValue: $0)) }
            )
            activeMonitor.setValue(monitor)
            let interim = try #require(await f.router.receive(f.event(.stopCandidate, text: "Background checks are running"), peer: f.peer))
            await monitor.verify(interim, provider: CodexPluginCore())
            resume = nil
        } else {
            let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in CodexPluginCore() }, synchronizeIngress: synchronize)
            let service = AgentWorkflowService(
                store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in scheduled.setValue(true) },
                recoverResults: { try await recovery.recover($0) }
            )
            resume = Task { try await service.resume(runID: original.id, expectedRevision: original.revision) }
        }
        for _ in 0..<100 {
            if queued.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queued.value)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        gate.continuation.finish()
        if let resume {
            await #expect(throws: AgentWorkflowError.self) { try await resume.value }
        }
        try await ingress.waitForPendingFrames()
        let archive = try await f.store.snapshot()
        #expect(archive.runs[0].status == (live ? .running : .paused))
        #expect(archive.runs[0].invocations[0].result == nil)
        #expect(archive.pendingReceipts?[f.invocation.id]?.backgroundTurn?.nativeTurnID == "turn")
        #expect(!scheduled.value)
        await activeMonitor.value?.shutdown()
        await ingress.stop()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func liveVerificationReadsPastAnEarlierAnswerForTheSameTurn() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.writeCodexTurns("turn")
        try f.appendCodexAnswer("Previous answer")
        try f.appendCodexAnswer("Final answer")
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final answer"), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: CodexPluginCore())
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].invocations[0].status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(await f.store.snapshot().runs.first)
        #expect(run.status == .completed && run.invocations[0].result?.text == "Final answer")
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    private func enqueueAcknowledgedHook(session: String, path: String) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try #require(path.utf8.count < MemoryLayout.size(ofValue: address.sun_path))
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                UnsafeMutableRawPointer($0).copyMemory(from: source, byteCount: path.utf8.count + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        let payload = try JSONEncoder().encode(EchoDirective(sessionID: session, state: .working))
        let bytes = try IngressFrame(pluginID: EchoPluginCore.pluginID, context: ["CTRLX_INGRESS_ACK": "1"], payload: payload).encodeFrame()
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try #require(written == bytes.count)
        try await awaitIngressAcknowledgement(fd)
    }

    @Test(arguments: ["codex", "claude-code"], ["active", "stopped", "timeout"])
    func laterReceiptSurvivesInspectionFailure(plugin: String, state: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit, allowsFinish: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(true), timedOut = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, verificationTimeout: state == "timeout" ? .milliseconds(250) : .seconds(5), provider: { _ in f.nativeProvider }, onFailure: { _ in timedOut.setValue(true) })
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        available.setValue(false)
        try f.writeNativeTurns("turn", "B")
        _ = try await router.receive(f.event(.submitted, text: "Implement", turn: "B", plugin: plugin), peer: f.peer)
        if state == "stopped" {
            try f.appendNativeAnswer("More discussion", turn: "B")
            _ = try await router.receive(f.event(.stopCandidate, text: "More discussion", turn: "B", plugin: plugin), peer: f.peer)
        }
        if state == "timeout" {
            for _ in 0..<100 {
                if timedOut.value {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(timedOut.value)
        }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        let finish = JSONRPCRequest(id: "finish", method: "workflow.finish", params: ["invocationId": .string(f.invocation.id.uuidString), "reason": .string("Done")])
        for request in [complete, finish] {
            #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.completionRequested == false)
        #expect(try await router.receive(f.event(.stopCandidate, text: "Old proposal", plugin: plugin), peer: f.peer) == nil)
        available.setValue(true)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            do {
                try await router.requireVerifiedSubmission(f.invocation.id)
                if try await f.store.snapshot().runs[0].invocations[0].stepTurn?.id == "B" {
                    break
                }
            } catch { continue }
        }
        let recovered = try await f.store.snapshot().runs[0]
        #expect(recovered.invocations[0].nativeTurnID == "turn")
        #expect(recovered.invocations[0].stepTurn?.id == "B")
        #expect(recovered.invocations[0].stepTurn?.stopped == (state == "stopped"))
        if state == "timeout" {
            try await f.store.update(runID: f.run.id) { try $0.resume(instances: [f.instance], now: Date()) }
        } else {
            #expect(recovered.status == .running)
        }
        if state == "stopped" {
            #expect(await service.handle(complete, peer: f.peer).error != nil)
            #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.completion?.text == "More discussion")
            _ = try await router.receive(f.event(.submitted, text: "Yes, implement", turn: "B", plugin: plugin), peer: f.peer)
            try f.appendNativeTurn("B")
            try await router.requireVerifiedSubmission(f.invocation.id)
            #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == false)
            try f.appendNativeTurn("C")
            _ = try await router.receive(f.event(.submitted, text: "Now implement", turn: "C", plugin: plugin), peer: f.peer)
        }
        try #require(await service.handle(complete, peer: f.peer).ok)
        let finalTurn = state == "stopped" ? "C" : "B"
        let final = try #require(await router.receive(f.event(.stopCandidate, text: "Implemented", turn: finalTurn, plugin: plugin), peer: f.peer))
        #expect(final.candidate.nativeTurnID == finalTurn)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func stoppedStepRechecksATranscriptProofOrRebuildsALegacyBoundary(legacy: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        if legacy {
            try f.appendCodexAnswer("Earlier proposal")
            try f.appendNativeTurn("turn")
        }
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.peer)
        var archive = try await f.store.snapshot()
        let store: AgentWorkflowStore
        if legacy {
            archive.schemaVersion = 9
            archive.pendingReceipts = nil
            let path = f.directory.appendingPathComponent("v9-ledger.json")
            try JSONEncoder().encode(archive).write(to: path)
            store = AgentWorkflowStore(fileURL: path, hostID: f.instance.hostID)
            _ = try await store.reconcile([.init(f.instance)])
        } else {
            store = f.store
        }
        try f.appendNativeTurn("turn")
        let nativeTurn = PluginWorkflowTurn(nativeTurnID: "turn", transcriptPath: f.transcript.path)
        let receipt = archive.pendingReceipts?[f.invocation.id]
        if !legacy {
            let file = try AgentWorkflowTranscriptFile(
                path: f.transcript.path, parser: CodexWorkflowTranscript(conversationID: f.instance.conversationID, nativeTurnID: "turn")
            )
            let proof = try #require(await file.verifyResumedSubmission(nativeTurn, after: receipt?.stopBoundary, matching: receipt?.completion))
            let handle = try FileHandle(forWritingTo: f.transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8))
            #expect(try await !store.observeStepTurn(
                runID: f.run.id, invocationID: f.invocation.id, instance: f.instance,
                turn: .init(id: "turn", transcriptPath: f.transcript.path, prompt: "Continue"), reopening: proof, expectedReceipt: receipt
            ))
            #expect(try await store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
        }
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("An explicit step must await its completion request.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        _ = try await router.receive(f.event(.submitted, text: "Continue"), peer: f.peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let saved = try await store.snapshot()
        #expect(saved.runs[0].invocations[0].stepTurn?.stopped == false)
        #expect(saved.pendingReceipts?[f.invocation.id]?.stopBoundary?.nativeRecord == true)
        await router.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func replayDoesNotReopenASecondIdenticalAnswer() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Done")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Done", hasPendingWork: true), peer: f.peer)
        let followup = f.event(.submitted, text: "Finish the background work")
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(followup, peer: f.peer)
        try f.appendCodexAnswer("Done")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Done"), peer: f.peer)
        _ = try await f.router.receive(followup, peer: f.peer)
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await f.router.requireVerifiedSubmission($0)
        })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error != nil)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func reopeningUsesANewNativeEndingBeforeApplyingStop(completionRequested: Bool, identicalReply: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Done")
        let stop = f.event(.stopCandidate, text: "Done")
        let oldPeer = try f.hookPeer(startedAt: 101)
        let submitPeer = try f.hookPeer(startedAt: 102)
        let finalPeer = try f.hookPeer(startedAt: 103)
        _ = try await f.router.receive(stop, peer: oldPeer)
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Check again"), peer: submitPeer)
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        let running = try await f.store.snapshot()
        #expect(running.runs[0].invocations[0].stepTurn?.stopped == false)

        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: {
            Issue.record(Comment(rawValue: $0))
        })
        #expect(try await f.router.receive(stop, peer: oldPeer) == nil)
        #expect(try await f.store.snapshot() == running)
        if completionRequested {
            _ = try await f.store.update(runID: f.run.id) {
                try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
        }
        let answer = identicalReply ? "Done" : "Implemented"
        if identicalReply {
            try f.appendCodexAnswer(answer)
            #expect(try await f.store.snapshot().runs[0].invocations[0].status == .running)
            #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.completion == nil)
        }
        let nextStop = try await f.router.receive(f.event(.stopCandidate, text: answer), peer: finalPeer)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
        if completionRequested {
            try await monitor.verify(#require(nextStop), provider: f.nativeProvider)
        } else {
            #expect(nextStop == nil)
            let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
                try await f.router.requireVerifiedSubmission($0)
            })
            let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
            #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        }
        #expect(try await f.router.receive(stop, peer: oldPeer) == nil)
        if !identicalReply {
            try f.appendCodexAnswer(answer)
        }
        for _ in 0..<100 {
            let call = try await f.store.snapshot().runs[0].invocations[0]
            if completionRequested ? call.status == .succeeded : call.stepTurn?.stopped == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let closed = try await f.store.snapshot()
        #expect(closed.runs[0].invocations[0].stepTurn?.stopped == true)
        if completionRequested {
            #expect(closed.runs[0].invocations[0].result?.text == answer)
        } else {
            #expect(closed.pendingReceipts?[f.invocation.id]?.completion?.text == answer)
            #expect(closed.runs[0].invocations[0].result == nil)
        }
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func backgroundStopSupersedesVerifiedAnswerAcrossRestart() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 101))
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Implement"), peer: f.hookPeer(startedAt: 102))
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        _ = try await f.store.update(runID: f.run.id) {
            try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
        }
        try f.appendCodexAnswer("Done")
        let final = try #require(await f.router.receive(f.event(.stopCandidate, text: "Done"), peer: f.hookPeer(startedAt: 103)))
        let flushed = LockIsolated(false)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, synchronizeIngress: {
            let background = f.event(.stopCandidate, text: "Done", hasPendingWork: true)
            _ = try await f.router.receive(background, peer: f.hookPeer(startedAt: 104))
            flushed.setValue(true)
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(final, provider: f.nativeProvider)
        for _ in 0..<100 {
            if flushed.value {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(flushed.value)
        await monitor.shutdown()
        let saved = try await f.store.snapshot()
        #expect(saved.runs[0].invocations[0].result == nil)
        #expect(saved.pendingReceipts?[f.invocation.id]?.completion?.hasPendingWork == true)
        let restarted = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID)
        _ = try await restarted.reconcile([.init(f.instance)])
        let run = try #require(await restarted.snapshot().runs.first)
        let recovery = AgentWorkflowResultRecovery(store: restarted, inspect: { $0 }, provider: { _ in CodexPluginCore() })
        let recovered = try await recovery.recover(run)
        #expect(recovered.invocations[0].status == .uncertain)
        #expect(recovered.invocations[0].result == nil)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func continueOnlyBypassesAVerifiedReplay(newSubmission: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(true)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.writeNativeTurns("turn")
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        let receipt = f.event(.submitted, text: "An earlier discussion")
        _ = try await router.receive(receipt, peer: f.hookPeer(startedAt: 102))
        try f.appendCodexAnswer("Proposal")
        _ = try await router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 103))
        available.setValue(false)
        if newSubmission {
            try f.appendNativeTurn("turn")
            _ = try await router.receive(f.event(.submitted, text: "Implement this"), peer: f.hookPeer(startedAt: 104))
        } else {
            _ = try await router.receive(receipt, peer: f.hookPeer(startedAt: 102))
        }
        let paused = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator paused") }
        await #expect(throws: AgentWorkflowError.self) {
            try await router.requireVerifiedSubmission(f.invocation.id)
        }
        let writes = LockIsolated<[String]>([])
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in },
            synchronizeEvents: { try await router.requireVerifiedSubmission($0, allowingStoppedReplay: true) },
            resumeStep: { invocation, _ in
                if let turn = invocation.stepTurn {
                    writes.withValue { $0.append(turn.id) }
                }
            }
        )
        if newSubmission {
            await #expect(throws: AgentWorkflowError.self) {
                try await service.resume(runID: paused.id, expectedRevision: paused.revision)
            }
            #expect(writes.value.isEmpty)
        } else {
            let continued = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
            #expect(continued.status == .running)
            #expect(writes.value == ["turn"])
        }
        await #expect(throws: AgentWorkflowError.self) {
            try await router.requireVerifiedSubmission(f.invocation.id)
        }
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func currentFailureWinsRegardlessOfStopArrivalOrder(failureFirst: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Implement"), peer: f.hookPeer(startedAt: 103))
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        _ = try await f.router.receive(f.event(.failed, text: "Expired failure"), peer: f.hookPeer(startedAt: 102))
        #expect(try await f.store.snapshot().runs[0].invocations[0].status == .running)
        _ = try await f.store.update(runID: f.run.id) {
            try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
        }
        let stop = f.event(.stopCandidate, text: "Done")
        let failure = f.event(.failed, text: "Current failure")
        if failureFirst {
            _ = try await f.router.receive(failure, peer: f.hookPeer(startedAt: 104))
            _ = try await f.router.receive(stop, peer: f.hookPeer(startedAt: 105))
        } else {
            _ = try #require(await f.router.receive(stop, peer: f.hookPeer(startedAt: 105)))
            _ = try await f.router.receive(failure, peer: f.hookPeer(startedAt: 104))
        }
        let call = try await f.store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.issue == "Current failure")
        #expect(call.result == nil)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["unconfirmed", "already-ended", "two-queued", "late-replay"])
    func sameTurnSubmissionsAreRetainedWhileTheWriterIsUnavailable(scenario: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(true)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, recheckConversation: { _, _, _ in available.value ? .ready : .deferred }, provider: { _ in f.nativeProvider })
        try f.writeNativeTurns("turn")
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        available.setValue(false)
        try f.appendNativeTurn("turn")
        let submit = f.event(.submitted, text: "Continue the discussion")
        if scenario == "unconfirmed" {
            try await router.receiveUnconfirmedSubmission(submit, peer: f.hookPeer(startedAt: 103))
        } else {
            _ = try await router.receive(submit, peer: f.hookPeer(startedAt: 103))
            try f.appendCodexAnswer("Clarification")
            _ = try await router.receive(f.event(.stopCandidate, text: "Clarification"), peer: f.hookPeer(startedAt: 104))
            #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.completion?.text == "Proposal")
            if scenario == "two-queued" {
                try f.appendNativeTurn("turn")
                _ = try await router.receive(f.event(.submitted, text: "Implement it"), peer: f.hookPeer(startedAt: 105))
            } else if scenario == "late-replay" {
                _ = try await router.receive(f.event(.submitted, text: "Earlier discussion"), peer: f.hookPeer(startedAt: 101))
            }
        }
        available.setValue(true)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let recovered = try await f.store.snapshot()
        let receipt = try #require(recovered.pendingReceipts?[f.invocation.id])
        let hasStop = scenario == "already-ended" || scenario == "late-replay"
        #expect(recovered.runs[0].invocations[0].stepTurn?.stopped == hasStop)
        #expect(receipt.resumedHookStartedAt == Date(timeIntervalSince1970: scenario == "two-queued" ? 105 : 103))
        #expect(receipt.completion?.text == (hasStop ? "Clarification" : nil))
        if hasStop {
            let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
            let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
                try await router.requireVerifiedSubmission($0)
            })
            #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        }
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func queuedReceiptsAreRecheckedAgainstTheLatestNativeTurn(afterLoop: Bool) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: afterLoop)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.appendNativeTurn("B")
        _ = try await router.receive(f.event(.submitted, text: "Current work", turn: "C"), peer: f.hookPeer(startedAt: 104))
        _ = try await router.receive(f.event(.submitted, text: "Earlier work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        available.setValue(true)
        await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
        try f.appendNativeTurn("C")
        try await router.requireVerifiedSubmission(f.invocation.id)
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await router.requireVerifiedSubmission($0)
        }, provider: { _ in f.nativeProvider })
        try #require(await service.handle(afterLoop ? f.loopExitRequest() : complete, peer: f.peer).ok)
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "C")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["later-submission", "host-restart"])
    func pendingContinuationFailureSurvivesLaterSubmissionOrRestart(scenario: String) async throws {
        let restart = scenario == "host-restart"
        let plugin = restart ? "claude-code" : "codex"
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(true)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.writeNativeTurns("turn")
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.hookPeer(startedAt: 101))
        try f.appendNativeAnswer("Proposal")
        _ = try await router.receive(f.event(.stopCandidate, text: "Proposal", plugin: plugin), peer: f.hookPeer(startedAt: 102))
        available.setValue(false)
        let failedTurn = restart ? "limited" : "turn"
        try f.appendNativeTurn(failedTurn)
        _ = try await router.receive(f.event(.submitted, text: "Start work", turn: failedTurn, plugin: plugin), peer: f.hookPeer(startedAt: 103))
        _ = try await router.receive(f.event(.failed, text: "Quota exceeded", turn: failedTurn, plugin: plugin), peer: f.hookPeer(startedAt: 104))
        #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.continuations?.first(where: { $0.completion?.kind == .failed })?.completion?.text == "Quota exceeded")
        if restart {
            await router.shutdown()
            let reopened = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID)
            _ = try await reopened.reconcile([.init(f.instance)])
            let paused = try #require(await reopened.snapshot().runs.first)
            let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
                Issue.record("The failed invocation must not be resent.")
            }), onFailure: { Issue.record(Comment(rawValue: $0)) })
            let restarted = AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
            let service = AgentWorkflowService(
                store: reopened, scan: { _ in [.init(f.instance)] }, schedule: { _ in Issue.record("The failure must stay paused.") },
                synchronizeEvents: { try await restarted.requireVerifiedSubmission($0, allowingStoppedReplay: true) },
                resumeStep: { _, _ in Issue.record("Continue must not send a reminder while recovering the failure.") }
            )
            let recovered = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
            #expect(recovered.status == .paused)
            #expect(recovered.invocations[0].status == .failed && recovered.invocations[0].issue == "Quota exceeded")
            await restarted.shutdown()
            await runner.shutdown()
        } else {
            try f.appendNativeTurn("turn")
            _ = try await router.receive(f.event(.submitted, text: "A later input"), peer: f.hookPeer(startedAt: 105))
            available.setValue(true)
            try await router.requireVerifiedSubmission(f.invocation.id)
            let call = try await f.store.snapshot().runs[0].invocations[0]
            #expect(call.status == .failed && call.issue == "Quota exceeded")
            await router.shutdown()
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aSingleQueuedReceiptCannotSelectAnOlderNativeTurn(afterLoop: Bool) async throws {
        let f = try await fixture(completion: .explicit, afterLoop: afterLoop)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.appendNativeTurn("B")
        _ = try await router.receive(f.event(.submitted, text: "Old work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try f.appendNativeTurn("C")
        available.setValue(true)
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await router.requireVerifiedSubmission($0)
        }, provider: { _ in f.nativeProvider })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(complete, peer: f.peer).error?.code == "workflow_denied")
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
        _ = try await router.receive(f.event(.submitted, text: "Current work", turn: "C"), peer: f.hookPeer(startedAt: 104))
        try #require(await service.handle(complete, peer: f.peer).ok)
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "C")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], ["live", "delayed", "restart", "v9-live", "v9-delayed", "v9-restart"])
    func aPendingContinuationStopSurvivesHostRestart(sameID: Bool, mode: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Old proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Old proposal"), peer: f.hookPeer(startedAt: 102))
        let upgraded: AgentWorkflowStore
        if mode.hasPrefix("v9-") {
            var ledger = try await f.store.snapshot()
            ledger.schemaVersion = 9
            ledger.pendingReceipts = nil
            try JSONEncoder().encode(ledger).write(to: await f.store.fileURL, options: .atomic)
            upgraded = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID)
            _ = try await upgraded.reconcile([.init(f.instance)])
        } else {
            upgraded = f.store
        }
        let available = LockIsolated(mode.hasSuffix("live"))
        let router = AgentWorkflowEventRouter(store: upgraded, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        let turn = sameID ? "turn" : "B"
        try f.appendNativeTurn(turn)
        _ = try await router.receive(f.event(.submitted, text: "Clarify it", turn: turn), peer: f.hookPeer(startedAt: 103))
        try f.appendNativeAnswer("New proposal", turn: turn)
        _ = try await router.receive(f.event(.stopCandidate, text: "New proposal", turn: turn), peer: f.hookPeer(startedAt: 104))
        if mode.hasSuffix("restart") {
            await router.shutdown()
        }
        available.setValue(true)
        let reopened = mode.hasSuffix("restart") ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : upgraded
        if mode.hasSuffix("restart") {
            _ = try await reopened.reconcile([.init(f.instance)])
        }
        let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("Recovery must not resend the task.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let restored = mode.hasSuffix("restart") ? AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        let service = AgentWorkflowAgentService(store: reopened, inspect: { $0 }, synchronizeEvents: {
            try await restored.requireVerifiedSubmission($0)
        })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(complete, peer: f.peer).error?.code == "workflow_denied")
        let state = try await reopened.snapshot()
        #expect(state.runs[0].invocations[0].stepTurn?.id == turn)
        #expect(state.runs[0].invocations[0].stepTurn?.stopped == true)
        #expect(state.runs[0].invocations[0].result == nil)
        #expect(state.pendingReceipts?[f.invocation.id]?.completion?.text == "New proposal")
        await restored.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], ["online", "restart", "ended-online", "ended-restart"])
    func aPendingFailureIsRecoveredBeforeOrAfterEnd(initialUnconfirmed: Bool, mode: String) async throws {
        let ended = mode.hasPrefix("ended")
        let restarted = mode.hasSuffix("restart")
        let f = try await fixture(plugin: "claude-code", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(!initialUnconfirmed)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.writeNativeTurns("turn")
        let first = f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "claude-code")
        if initialUnconfirmed {
            try await router.receiveUnconfirmedSubmission(first, peer: f.hookPeer(startedAt: 101))
        } else {
            _ = try await router.receive(first, peer: f.hookPeer(startedAt: 101))
        }
        available.setValue(false)
        try f.appendNativeTurn("B")
        _ = try await router.receive(f.event(.submitted, text: "Continue reviewing", turn: "B", plugin: "claude-code"), peer: f.hookPeer(startedAt: 103))
        _ = try await router.receive(f.event(.failed, text: "Quota exceeded", turn: "B", plugin: "claude-code"), peer: f.hookPeer(startedAt: 104))
        if ended {
            try await f.store.update(runID: f.run.id) { $0.end() }
        }
        if restarted {
            await router.shutdown()
        }
        available.setValue(true)
        let reopened = restarted ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        if restarted {
            _ = try await reopened.reconcile([.init(f.instance)])
        }
        let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("Failure recovery must not write a reminder.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let restored = restarted ? AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        try await restored.requireVerifiedSubmission(f.invocation.id)
        let run = try await reopened.snapshot().runs[0]
        #expect(run.status == (ended ? .ended : .paused))
        #expect(run.invocations[0].status == .failed && run.invocations[0].issue == "Quota exceeded")
        await restored.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func anOlderTaskFailureCannotTakeOverAnExplicitWorkflow(crossFile: Bool) async throws {
        let f = try await fixture(plugin: "claude-code", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("old", "turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "claude-code"), peer: f.hookPeer(startedAt: 105))
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, recheckConversation: { _, _, _ in .deferred }, provider: { _ in f.nativeProvider })
        let oldTranscript = crossFile ? f.directory.appendingPathComponent("older-conversation.jsonl") : f.transcript
        let oldConversation = crossFile ? "older-conversation" : f.instance.conversationID
        if crossFile {
            let record: [String: Any] = ["type": "user", "uuid": "old-user", "promptId": "old", "sessionId": oldConversation, "isSidechain": false]
            try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: oldTranscript)
        }
        func oldEvent(_ kind: PluginWorkflowEvent.Kind, text: String) -> PluginEvent {
            .init(pluginID: "claude-code", sessionID: oldConversation, tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: "old", transcriptPath: oldTranscript.path, text: text
            ))
        }
        try await router.receiveUnconfirmedSubmission(oldEvent(.submitted, text: "Previous task"), peer: f.hookPeer(startedAt: 101))
        _ = try await router.receive(oldEvent(.failed, text: "Previous quota error"), peer: f.hookPeer(startedAt: 102))
        available.setValue(true)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let run = try await f.store.snapshot().runs[0]
        #expect(run.invocations[0].resultTurnID == "turn")
        #expect(run.invocations[0].status == .running && run.invocations[0].issue == nil)
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func outOfOrderSameIDReceiptsKeepTheirOwnStopAfterRestart(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.appendNativeTurn("turn")
        try f.appendCodexAnswer("First discussion")
        try f.appendNativeTurn("turn")
        try f.appendCodexAnswer("Latest discussion")
        _ = try await router.receive(f.event(.submitted, text: "Latest question"), peer: f.hookPeer(startedAt: 105))
        _ = try await router.receive(f.event(.stopCandidate, text: "Latest discussion"), peer: f.hookPeer(startedAt: 106))
        _ = try await router.receive(f.event(.submitted, text: "First question"), peer: f.hookPeer(startedAt: 103))
        if restart {
            await router.shutdown()
        }
        available.setValue(true)
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        if restart {
            _ = try await store.reconcile([.init(f.instance)])
        }
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("No task should be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(complete, peer: f.peer).error?.code == "workflow_denied")
        let archive = try await store.snapshot()
        #expect(archive.runs[0].invocations[0].stepTurn?.stopped == true)
        #expect(archive.pendingReceipts?[f.invocation.id]?.completion?.text == "Latest discussion")
        #expect(archive.pendingReceipts?[f.invocation.id]?.resumedHookStartedAt == Date(timeIntervalSince1970: 105))
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func anOlderContinueCannotOverrideANewerOperatorPause(otherContinues: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Clarify"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Clarification")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Clarification"), peer: f.hookPeer(startedAt: 104))
        let other = AgentWorkflowService(store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in }, resumeStep: { _, _ in })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await other.pause(runID: f.run.id, expectedRevision: current.revision)
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in f.nativeProvider }, synchronizeIngress: {
            let current: AgentWorkflowRun
            if otherContinues {
                current = try await other.resume(runID: f.run.id, expectedRevision: paused.revision)
            } else {
                current = paused
            }
            _ = try await other.pause(runID: f.run.id, expectedRevision: current.revision)
        })
        let writes = LockIsolated(0)
        let first = AgentWorkflowService(
            store: f.store,
            scan: { _ in [.init(f.instance)] },
            schedule: { _ in writes.withValue { $0 += 1 } },
            resumeStep: { _, _ in writes.withValue { $0 += 1 } },
            recoverResults: { try await recovery.recover($0) }
        )
        await #expect(throws: AgentWorkflowError.self) { try await first.resume(runID: f.run.id, expectedRevision: paused.revision) }
        #expect(writes.value == 0)
        #expect(try await f.store.snapshot().runs[0].status == .paused)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aNewProcessCannotDiscardAnAuthenticatedFailure(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { instance in
            guard instance.processID != f.instance.processID else { throw AgentWorkflowInspectionUnavailable() }
            return instance
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: "Original continuation", turn: "B"), peer: f.hookPeer(startedAt: 103))
        _ = try await router.receive(f.event(.failed, text: "Saved failure", turn: "B"), peer: f.hookPeer(startedAt: 104))
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        var replacement = AgentWorkflowObservation(f.instance)
        replacement.processID = 20
        replacement.processRuntimeID = "501:20:200:0"
        let live = try #require(await store.reconcile([replacement]).first)
        let peer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("Failure verification must not resend tasks.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { instance in
            guard instance.matchesProcess(live) else { throw AgentWorkflowInspectionUnavailable() }
            return instance
        }, provider: { _ in f.nativeProvider }) : router
        try f.appendNativeTurn("C")
        _ = try await active.receive(f.event(.submitted, text: "New process work", turn: "C"), peer: peer)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(complete, peer: peer).error?.code == "workflow_denied")
        let saved = try await store.snapshot()
        #expect(saved.runs[0].invocations[0].issue == "Saved failure"
            || saved.pendingReceipts?[f.invocation.id]?.continuations?.contains(where: { $0.completion?.text == "Saved failure" }) == true)
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func anOldProcessFailureCannotAttachToANewProcessReceipt(currentWriter: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        var replacement = AgentWorkflowObservation(f.instance)
        replacement.processID = 20
        replacement.processRuntimeID = "501:20:200:0"
        _ = try await f.store.reconcile([replacement])
        let peer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        func currentHook(_ time: UInt64) throws -> PluginIngressPeer {
            try #require(PluginIngressPeer.capture(peerPID: Int32(time), userID: 501) { pid in
                if pid == Int32(time) {
                    return .init(processID: pid, parentProcessID: 20, userID: 501, startSeconds: time, startMicroseconds: 0)
                }
                return peer.processes.first(where: { $0.processID == pid })
            })
        }
        let router = AgentWorkflowEventRouter(
            store: f.store,
            runner: f.runner,
            inspect: { _ in throw AgentWorkflowInspectionUnavailable() },
            recheckConversation: { _, _, _ in .deferred },
            provider: { _ in f.nativeProvider }
        )
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: "New process continuation", turn: "B"), peer: currentHook(301))
        try f.appendNativeTurn("B")
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: "Later new process input", turn: "B"), peer: currentHook(303))
        let source = try currentWriter ? currentHook(304) : f.hookPeer(startedAt: 304)
        _ = try await router.receive(f.event(.failed, text: "Tool failure", turn: "B"), peer: source)
        let archive = try await f.store.snapshot()
        let retained = try #require(archive.pendingReceipts?[f.invocation.id]?.continuations)
        #expect(retained.contains { $0.writer.processID == 10 && $0.submission.nativeTurnID == "turn" && $0.completion == nil })
        let receipts = retained.filter { $0.writer.processID == 20 }
        #expect(receipts.count == 2 && receipts.allSatisfy { $0.writer.processID == 20 })
        #expect(receipts[0].completion == nil)
        #expect(receipts[1].completion?.text == (currentWriter ? "Tool failure" : nil))
        #expect(archive.runs[0].invocations[0].status != .failed)
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [PluginWorkflowEvent.Kind.stopCandidate, .failed], [false, true])
    func pendingContinuationsCanBindTheFirstCodexConversation(kind: PluginWorkflowEvent.Kind, restart: Bool) async throws {
        let f = try await fixture(conversation: "", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let conversation = UUID().uuidString
        try f.writeCodexTurns("turn", "B", conversationID: conversation)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        func event(_ kind: PluginWorkflowEvent.Kind, turn: String, text: String) -> PluginEvent {
            .init(
                pluginID: "codex",
                sessionID: conversation,
                tmuxPane: f.instance.paneID,
                workflow: .init(kind: kind, nativeTurnID: turn, transcriptPath: f.transcript.path, text: text)
            )
        }
        try await router.receiveUnconfirmedSubmission(event(.submitted, turn: "turn", text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        _ = try await router.receive(event(.submitted, turn: "B", text: "Follow-up"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Follow-up answer", turn: "B")
        _ = try await router.receive(event(kind, turn: "B", text: "Follow-up answer"), peer: f.hookPeer(startedAt: 104))
        if restart {
            await router.shutdown()
        }
        available.setValue(true)
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        if restart {
            _ = try await store.reconcile([.init(f.instance)])
        }
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("Recovery cannot resend tasks.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        try await active.requireVerifiedSubmission(f.invocation.id)
        let run = try await store.snapshot().runs[0]
        #expect(run.instances[0].conversationID == conversation)
        #expect(run.invocations[0].resultTurnID == "B")
        #expect(run.invocations[0].status == (kind == .failed ? .failed : .running))
        if kind == .stopCandidate {
            #expect(run.invocations[0].stepTurn?.stopped == true)
        }
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["online", "restart", "legacy-online", "legacy-restart"])
    func anEarlierSegmentFailureDoesNotBlockContinue(mode: String) async throws {
        let restart = mode.hasSuffix("restart")
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Clarify"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Clarification")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Clarification"), peer: f.hookPeer(startedAt: 104))
        let router = AgentWorkflowEventRouter(
            store: f.store,
            runner: f.runner,
            inspect: { _ in throw AgentWorkflowInspectionUnavailable() },
            recheckConversation: { _, _, _ in .deferred },
            provider: { _ in f.nativeProvider }
        )
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: "Earlier discussion"), peer: f.hookPeer(startedAt: 101))
        _ = try await router.receive(f.event(.failed, text: "Earlier segment failure"), peer: f.hookPeer(startedAt: 102))
        if mode.hasPrefix("legacy") {
            var archive = try await f.store.snapshot()
            let entry = try #require(archive.pendingReceipts?[f.invocation.id]?.continuations?.first)
            let completion = try #require(entry.completion)
            archive.pendingReceipts?[f.invocation.id]?.continuationFailure = .init(
                writer: entry.writer,
                submission: entry.submission,
                submittedAt: entry.submittedAt,
                failure: completion,
                failedAt: entry.completedAt
            )
            archive.pendingReceipts?[f.invocation.id]?.continuations = nil
            try await f.store.commit(archive)
        }
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("A workflow task cannot be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        let writes = LockIsolated(0)
        let service = AgentWorkflowService(
            store: store,
            scan: { _ in [.init(f.instance)] },
            schedule: { _ in },
            synchronizeEvents: { try await active.requireVerifiedSubmission($0, allowingStoppedReplay: true) },
            resumeStep: { _, _ in writes.withValue { $0 += 1 } }
        )
        let before = try await store.snapshot().runs[0]
        let paused = before.status == .paused ? before : try await service.pause(runID: before.id, expectedRevision: before.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.status == .running && writes.value == 1)
        let remaining = try await store.snapshot().pendingReceipts?[f.invocation.id]?.continuations?.filter { $0.isRetired != true }
        #expect(remaining?.isEmpty != false, Comment(rawValue: String(describing: remaining)))
        #expect(try await store.snapshot().pendingReceipts?[f.invocation.id]?.continuationFailure == nil)
        await active.shutdown()
        await router.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["native-only", "late-hook", "cold", "late-after-success"])
    func anAbortedOlderWriterCannotBeReplacedByASuccessfulTurn(mode: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Original discussion")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Original discussion"), peer: f.peer)
        try f.appendNativeTurn("B")
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { instance in
            guard instance.processID != 10 else { throw AgentWorkflowInspectionUnavailable() }
            return instance
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: "Earlier work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        if mode == "late-after-success" {
            try f.appendCodexAnswer("Earlier discussion", turn: "B")
            _ = try await router.receive(f.event(.stopCandidate, text: "Earlier discussion", turn: "B"), peer: f.hookPeer(startedAt: 104))
        } else {
            let file = try FileHandle(forWritingTo: f.transcript)
            try file.seekToEnd()
            let aborted: [String: Any] = ["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": "B"]]
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: aborted) + Data([10]))
            try file.close()
        }
        if mode == "cold" {
            _ = try await router.receive(f.event(.failed, text: "Earlier work failed", turn: "B"), peer: f.hookPeer(startedAt: 104))
            await router.shutdown()
        }
        let store = mode == "cold" ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        var replacement = AgentWorkflowObservation(f.instance)
        replacement.processID = 20
        replacement.processRuntimeID = "501:20:200:0"
        _ = try await store.reconcile([replacement])
        let peer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("No replacement task may be sent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = mode == "cold" ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        try f.appendNativeTurn("C")
        _ = try await active.receive(f.event(.submitted, text: "New work", turn: "C"), peer: peer)
        if mode == "late-after-success" {
            try await active.requireVerifiedSubmission(f.invocation.id)
            #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == "C")
        }
        if mode == "late-hook" || mode == "late-after-success" {
            _ = try await active.receive(f.event(.failed, text: "Earlier work failed", turn: "B"), peer: f.hookPeer(startedAt: 104))
        }
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let complete = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(complete, peer: peer).error?.code == "workflow_denied")
        try f.appendCodexAnswer("New writer answer", turn: "C")
        _ = try await active.receive(f.event(.stopCandidate, text: "New writer answer", turn: "C"), peer: peer)
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.result == nil && call.resultTurnID == "B")
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func crossConversationMembershipUsesNativeSubmissionTime(historical: Bool, legacy: Bool) async throws {
        let f = try await fixture(plugin: "claude-code", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let base = f.run.createdAt
        func user(_ id: String, session: String, at seconds: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "user",
                "uuid": id,
                "promptId": id,
                "sessionId": session,
                "isSidechain": false,
                "timestamp": base.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            ]) + Data([10])
        }
        try user("turn", session: f.instance.conversationID, at: 60).write(to: f.transcript)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "claude-code"), peer: f.hookPeer(startedAt: 101))
        if legacy {
            var archive = try await f.store.snapshot()
            archive.schemaVersion = 9
            archive.pendingReceipts = nil
            try JSONEncoder().encode(archive).write(to: await f.store.fileURL, options: .atomic)
        }
        let store = legacy ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let other = f.directory.appendingPathComponent("other.jsonl")
        var bytes = try user("B", session: "other-session", at: historical ? 30 : 90)
        if !historical {
            try bytes.append(user("C", session: "other-session", at: 120))
        }
        try bytes.write(to: other)
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("No task may be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, recheckConversation: { _, _, _ in .deferred }, provider: { _ in f.nativeProvider })
        func event(_ kind: PluginWorkflowEvent.Kind) -> PluginEvent {
            .init(pluginID: "claude-code", sessionID: "other-session", tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: "B", transcriptPath: other.path, text: kind == .submitted ? "Other input" : "Quota exceeded"
            ))
        }
        try await router.receiveUnconfirmedSubmission(event(.submitted), peer: f.hookPeer(startedAt: 210))
        if historical {
            try await router.requireVerifiedSubmission(f.invocation.id)
        }
        _ = try await router.receive(event(.failed), peer: f.hookPeer(startedAt: 211))
        try await router.requireVerifiedSubmission(f.invocation.id)
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(call.status == (historical ? .running : .failed))
        #expect(call.resultTurnID == (historical ? "turn" : "B"))
        if !historical {
            #expect(call.issue == "Quota exceeded")
        }
        await router.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5], ["online", "restart", "different-id-online", "different-id-restart"])
    func sameIDStopOwnershipIsIndependentOfReceiptArrival(order: Int, mode: String) async throws {
        let restart = mode.hasSuffix("restart")
        let sameID = !mode.hasPrefix("different-id")
        let firstTurn = sameID ? "turn" : "B", secondTurn = sameID ? "turn" : "C"
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn(firstTurn)
        try f.appendCodexAnswer("First answer", turn: firstTurn)
        try f.appendNativeTurn(secondTurn)
        try f.appendCodexAnswer("Final discussion", turn: secondTurn)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        for event in orders[order] {
            switch event {
            case 0: _ = try await router.receive(f.event(.submitted, text: "First question", turn: firstTurn), peer: f.hookPeer(startedAt: 103))
            case 1: _ = try await router.receive(f.event(.stopCandidate, text: "Final discussion", turn: secondTurn), peer: f.hookPeer(startedAt: 106))
            default: _ = try await router.receive(f.event(.submitted, text: "Second question", turn: secondTurn), peer: f.hookPeer(startedAt: 105))
            }
        }
        if restart {
            await router.shutdown()
        }
        available.setValue(true)
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("No discussion may be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let archive = try await store.snapshot()
        #expect(archive.runs[0].invocations[0].stepTurn?.stopped == true && archive.runs[0].invocations[0].result == nil)
        #expect(archive.pendingReceipts?[f.invocation.id]?.completion?.text == "Final discussion")
        #expect(archive.runs[0].invocations[0].resultTurnID == secondTurn)
        if sameID {
            #expect(archive.pendingReceipts?[f.invocation.id]?.resumedHookStartedAt == Date(timeIntervalSince1970: 105))
        }
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func anEarlierFailureOutranksALaterStopAcrossRestart(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: "Continue", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Intermediate answer", turn: "B")
        _ = try await router.receive(f.event(.stopCandidate, text: "Intermediate answer", turn: "B"), peer: f.hookPeer(startedAt: 105))
        _ = try await router.receive(f.event(.failed, text: "Failed answer", turn: "B"), peer: f.hookPeer(startedAt: 104))
        let saved = try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.continuations?.first(where: { $0.submission.nativeTurnID == "B" })
        #expect(saved?.completion?.kind == .failed)
        if restart {
            await router.shutdown()
        }
        available.setValue(true)
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("A failed task cannot be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        let service = AgentWorkflowService(
            store: store,
            scan: { _ in [.init(f.instance)] },
            schedule: { _ in },
            synchronizeEvents: { try await active.requireVerifiedSubmission($0, allowingStoppedReplay: true) },
            resumeStep: { _, _ in Issue.record("Failure recovery cannot send a reminder.") }
        )
        let current = try await store.snapshot().runs[0]
        let paused = current.status == .paused ? current : try await service.pause(runID: current.id, expectedRevision: current.revision)
        let recovered = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(recovered.status == .paused && recovered.invocations[0].status == .failed && recovered.invocations[0].issue == "Failed answer")
        await active.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func anOldContinuationErrorCannotUndoANewerOperatorsSuccessfulWrite() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let writes = LockIsolated(0), staleSchedules = LockIsolated(0)
        let other = AgentWorkflowService(store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in }, resumeStep: { call, agent in
            let permit = try #require(await f.store.authorizeContinuation(call, instance: agent))
            try permit.perform { writes.withValue { $0 += 1 } }
            try await f.store.finishContinuation(call, authorization: permit, written: true)
        })
        let current = try await f.store.snapshot().runs[0]
        let paused = try await other.pause(runID: current.id, expectedRevision: current.revision)
        let first = AgentWorkflowService(store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in staleSchedules.withValue { $0 += 1 } }, resumeStep: { _, _ in
            let current = try await f.store.snapshot().runs[0]
            let newerPause = try await other.pause(runID: current.id, expectedRevision: current.revision)
            _ = try await other.resume(runID: current.id, expectedRevision: newerPause.revision)
            throw AgentWorkflowError("Delayed write failure")
        })
        let run = try await first.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(run.status == .running && writes.value == 1 && staleSchedules.value == 0)
        #expect(run.invocations[0].continuationTurnID == "turn")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func removingAnOutdatedFailureKeepsAutomaticVerificationRunning() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Clarify"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Clarification")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Clarification"), peer: f.hookPeer(startedAt: 104))
        let clock = WorkflowRetryTestClock()
        defer { clock.sleeps.continuation.finish() }
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, clock: AnyClock(clock), recheckConversation: { _, _, _ in .deferred }, provider: { _ in f.nativeProvider }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: "Earlier discussion"), peer: f.hookPeer(startedAt: 101))
        _ = try await router.receive(f.event(.failed, text: "Outdated failure"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("B")
        _ = try await router.receive(f.event(.submitted, text: "Actual work", turn: "B"), peer: f.hookPeer(startedAt: 105))
        _ = try await router.receive(f.event(.failed, text: "Actual failure", turn: "B"), peer: f.hookPeer(startedAt: 106))
        available.setValue(true)
        let changes = await f.store.changes()
        var updates = changes.makeAsyncIterator()
        try await clock.advancePastNextSleep()
        while try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.continuations?.contains(where: { $0.completion?.text == "Outdated failure" }) == true {
            try #require(await updates.next() != nil)
        }
        try await clock.advancePastNextSleep()
        while try await f.store.snapshot().runs[0].invocations[0].status != .failed {
            try #require(await updates.next() != nil)
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].issue == "Actual failure")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aSelectedOlderWriterIsCheckedBeforeReplacement(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendNativeTurn("B")
        _ = try await f.router.receive(f.event(.submitted, text: "Earlier work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "B")
        try f.appendCodexAbort("B")
        await f.router.shutdown()
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let runner = restart ? f.runner(in: store) : f.runner
        let peer = try await f.replaceProcess(in: store)
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        try f.appendNativeTurn("C")
        _ = try await router.receive(f.event(.submitted, text: "Replacement work", turn: "C"), peer: peer)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: peer).error?.code == "workflow_denied")
        try f.appendCodexAnswer("Replacement answer", turn: "C")
        _ = try await router.receive(f.event(.stopCandidate, text: "Replacement answer", turn: "C"), peer: peer)
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.resultTurnID == "B" && call.result == nil)
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aCrossConversationReplayCannotRegressTheSelectedResult(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        let b = f.directory.appendingPathComponent("B.jsonl"), c = f.directory.appendingPathComponent("C.jsonl")
        try f.writeCodexTurns("B", conversationID: "session-B", to: b)
        try f.writeCodexTurns("C", conversationID: "session-C", to: c)
        // Fix native timestamps independently of wall-clock scheduling.
        for (file, time) in [(f.transcript, 1_000), (b, 2_000), (c, 3_000)] {
            let rows = try Data(contentsOf: file).split(separator: 10).map { line -> Data in
                var row = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                row["timestamp"] = Date(timeIntervalSince1970: Double(time)).formatted(.iso8601)
                return try JSONSerialization.data(withJSONObject: row) + Data([10])
            }
            try rows.reduce(into: Data()) { $0.append($1) }.write(to: file)
        }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        func event(_ kind: PluginWorkflowEvent.Kind, turn: String, file: URL) -> PluginEvent {
            .init(pluginID: "codex", sessionID: "session-\(turn)", tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: file.path, text: kind == .submitted ? "Discuss \(turn)" : "Old answer"
            ))
        }
        _ = try await f.router.receive(event(.submitted, turn: "C", file: c), peer: f.peer)
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        _ = try await f.router.receive(event(.stopCandidate, turn: "C", file: c), peer: f.peer)
        await f.router.shutdown()
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let runner = restart ? f.runner(in: store) : f.runner
        var observation = AgentWorkflowObservation(f.instance)
        observation.conversationID = "session-B"
        _ = try await store.reconcile([observation])
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(event(.submitted, turn: "B", file: b), peer: f.peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == "C")
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aHostContinuationCannotRegressTheSelectedResult(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        let b = f.directory.appendingPathComponent("B.jsonl"), c = f.directory.appendingPathComponent("C.jsonl")
        try f.writeCodexTurns("B", conversationID: "session-B", to: b)
        try f.writeCodexTurns("C", conversationID: "session-C", to: c)
        // Fix native timestamps independently of wall-clock scheduling.
        for (file, time) in [(f.transcript, 1_000), (b, 2_000), (c, 3_000)] {
            let rows = try Data(contentsOf: file).split(separator: 10).map { line -> Data in
                var row = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                row["timestamp"] = Date(timeIntervalSince1970: Double(time)).formatted(.iso8601)
                return try JSONSerialization.data(withJSONObject: row) + Data([10])
            }
            try rows.reduce(into: Data()) { $0.append($1) }.write(to: file)
        }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let prompt = AgentWorkflowPrompt.continuation(definition: f.run.definition, nodeID: f.invocation.nodeID, invocationID: f.invocation.id)
        func event(_ kind: PluginWorkflowEvent.Kind, turn: String, file: URL) -> PluginEvent {
            .init(pluginID: "codex", sessionID: "session-\(turn)", tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: file.path, text: kind == .submitted ? (turn == "B" ? prompt : "Discuss C") : "Old answer"
            ))
        }
        _ = try await f.router.receive(event(.submitted, turn: "B", file: b), peer: f.peer)
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        let accepted = try await f.store.snapshot()
        let writer = try #require(accepted.instances.first)
        _ = try await f.store.reconcile([.init(writer)])
        let call = accepted.runs[0].invocations[0]
        let permit = try #require(await f.store.authorizeContinuation(call, instance: writer))
        try await f.store.finishContinuation(call, authorization: permit, written: true)
        _ = try await f.router.receive(event(.submitted, turn: "C", file: c), peer: f.peer)
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        _ = try await f.router.receive(event(.stopCandidate, turn: "C", file: c), peer: f.peer)
        await f.router.shutdown()
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let runner = restart ? f.runner(in: store) : f.runner
        var observation = AgentWorkflowObservation(f.instance)
        observation.conversationID = "session-B"
        _ = try await store.reconcile([observation])
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(event(.submitted, turn: "B", file: b), peer: f.peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        #expect(try await store.snapshot().runs[0].invocations[0].resultTurnID == "C")
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [PluginWorkflowEvent.Kind.stopCandidate, .failed], ["online", "restart", "writing-online", "writing-restart"])
    func unmatchedTerminalEvidenceSurvivesOtherReceiptVerification(kind: PluginWorkflowEvent.Kind, mode: String) async throws {
        let restart = mode.hasSuffix("restart")
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if !mode.hasPrefix("writing") {
            _ = try await f.store.update(runID: f.run.id) { try $0.didWrite(invocationID: f.invocation.id) }
        }
        try f.writeNativeTurns("turn", "B")
        await f.router.shutdown()
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        _ = try await router.receive(f.event(kind, text: "B ended", turn: "B"), peer: f.hookPeer(startedAt: 104))
        #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.continuationCompletions?.contains(where: { $0.event.nativeTurnID == "B" }) == true)
        available.setValue(true)
        try await router.requireVerifiedSubmission(f.invocation.id)
        #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.continuationCompletions?.contains(where: { $0.event.nativeTurnID == "B" }) == true)
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let runner = restart ? f.runner(in: store) : f.runner
        _ = try await store.reconcile([.init(f.instance)])
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        _ = try await active.receive(f.event(.submitted, text: "B input", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try await active.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(kind == .failed ? call.status == .failed : call.stepTurn?.stopped == true)
        await active.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func crossFileMembershipUsesTheLatestSegmentOfARepeatedNativeID(repeated: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        let other = f.directory.appendingPathComponent("other.jsonl")
        try f.writeCodexTurns("old", conversationID: "other", to: other)
        func start(_ id: String, time: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": Date(timeIntervalSince1970: Double(time)).formatted(.iso8601), "payload": ["type": "task_started", "turn_id": id]]) + Data([10])
        }
        let header = try #require(Data(contentsOf: f.transcript).split(separator: 10).first)
        try (Data(header) + Data([10]) + start("turn", time: 2_000)).write(to: f.transcript)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let otherHeader = try #require(Data(contentsOf: other).split(separator: 10).first)
        let turn = repeated ? "B" : "new-B"
        try (Data(otherHeader) + Data([10]) + start("B", time: 1_000) + start(turn, time: 3_000)).write(to: other)
        func event(_ kind: PluginWorkflowEvent.Kind) -> PluginEvent {
            .init(pluginID: "codex", sessionID: "other", tmuxPane: f.instance.paneID, workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: other.path, text: kind == .submitted ? "New work" : "New work failed"
            ))
        }
        _ = try await f.router.receive(event(.submitted), peer: f.hookPeer(startedAt: 3_001))
        _ = try await f.router.receive(event(.failed), peer: f.hookPeer(startedAt: 3_002))
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        let call = try await f.store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.issue == "New work failed" && call.resultTurnID == turn)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func aLateOlderWriterFailureOverridesFrozenCompletion(restart: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Initial discussion")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Initial discussion"), peer: f.hookPeer(startedAt: 102))
        try f.appendNativeTurn("B")
        await f.router.shutdown()
        let old = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { _ in throw AgentWorkflowInspectionUnavailable() }, provider: { _ in f.nativeProvider })
        _ = try await old.receive(f.event(.submitted, text: "Old work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("Old discussion", turn: "B")
        _ = try await old.receive(f.event(.stopCandidate, text: "Old discussion", turn: "B"), peer: f.hookPeer(startedAt: 104))
        await old.shutdown()
        let peer = try await f.replaceProcess(in: f.store)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        try f.appendNativeTurn("C")
        _ = try await router.receive(f.event(.submitted, text: "New work", turn: "C"), peer: peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: peer).ok)
        _ = try await router.receive(f.event(.failed, text: "Late old failure", turn: "B"), peer: f.hookPeer(startedAt: 105))
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let runner = restart ? f.runner(in: store) : f.runner
        _ = try await f.replaceProcess(in: store)
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        do { try await active.requireVerifiedSubmission(f.invocation.id) }
        catch is AgentWorkflowInspectionUnavailable { Issue.record("A verified old failure must not remain pending.") }
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.resultTurnID == "B" && call.issue == "Late old failure")
        await active.shutdown()
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["background-abort", "earlier-unknown"])
    func retiredWriterVerificationFindsFailurePastWaitingEntries(mode: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        await f.router.shutdown()
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { instance in
            guard instance.processID != 10 else { throw AgentWorkflowInspectionUnavailable() }
            return instance
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: "Earlier work", turn: "B"), peer: f.hookPeer(startedAt: 103))
        let failedTurn: String
        if mode == "background-abort" {
            _ = try await router.receive(f.event(.stopCandidate, text: "Still working", turn: "B", hasPendingWork: true), peer: f.hookPeer(startedAt: 104))
            try f.appendCodexAbort("B")
            failedTurn = "B"
        } else {
            try f.appendNativeTurn("D")
            _ = try await router.receive(f.event(.submitted, text: "Later work", turn: "D"), peer: f.hookPeer(startedAt: 105))
            _ = try await router.receive(f.event(.failed, text: "Known later failure", turn: "D"), peer: f.hookPeer(startedAt: 106))
            failedTurn = "D"
        }
        let peer = try await f.replaceProcess(in: f.store)
        try f.appendNativeTurn("C")
        _ = try await router.receive(f.event(.submitted, text: "Replacement", turn: "C"), peer: peer)
        _ = try? await router.requireVerifiedSubmission(f.invocation.id)
        let call = try await f.store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.resultTurnID == failedTurn && call.issue != nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["same-session", "new-session", "restart"])
    func acceptedSameProcessFailureRemainsAuthoritative(mode: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendNativeTurn("B")
        _ = try await f.router.receive(f.event(.submitted, text: "B input", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        try f.appendCodexAbort("B")
        await f.router.shutdown()
        let store = mode == "restart" ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = f.runner(in: store)
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        let path = mode == "new-session" ? f.directory.appendingPathComponent("C.jsonl") : f.transcript
        if mode == "new-session" {
            try f.writeCodexTurns("C", conversationID: "C-session", to: path)
        } else {
            try f.appendNativeTurn("C")
        }
        let next = PluginEvent(
            pluginID: "codex",
            sessionID: mode == "new-session" ? "C-session" : f.instance.conversationID,
            tmuxPane: f.instance.paneID,
            workflow: .init(kind: .submitted, nativeTurnID: "C", transcriptPath: path.path, text: "C input")
        )
        _ = try await router.receive(next, peer: f.hookPeer(startedAt: 105))
        _ = try await router.receive(f.event(.failed, text: "B interrupted", turn: "B"), peer: f.hookPeer(startedAt: 104))
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.resultTurnID == "B" && call.result == nil)
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [PluginWorkflowEvent.Kind.stopCandidate, .failed], [("turn", false), ("turn", true), ("B", false), ("B", true)])
    func terminalBeforeFirstReceiptIsRetained(kind: PluginWorkflowEvent.Kind, state: (String, Bool)) async throws {
        let (target, restart) = state
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.store.update(runID: f.run.id) { try $0.didWrite(invocationID: f.invocation.id) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(kind, text: "Already ended", turn: target), peer: f.hookPeer(startedAt: 104))
        #expect(try await f.store.snapshot().earlyCompletions?[f.invocation.id]?.count == 1)
        await f.router.shutdown()
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = f.runner(in: store)
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        if target == "B" {
            _ = try await router.receive(f.event(.submitted, text: "B input", turn: "B"), peer: f.hookPeer(startedAt: 103))
        }
        _ = try? await router.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let call = try await store.snapshot().runs[0].invocations[0]
        #expect(kind == .failed ? call.status == .failed : call.stepTurn?.stopped == true)
        #expect(call.result == nil)
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [PluginWorkflowEvent.Kind.stopCandidate, .failed])
    func unrelatedMissingTimeCannotChangeCompletionOwnership(kind: PluginWorkflowEvent.Kind) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let peer = try await f.replaceProcess(in: f.store)
        let writer = try #require(await f.store.snapshot().instances.first)
        let turn = PluginWorkflowTurn(nativeTurnID: "turn", transcriptPath: f.transcript.path)
        let legacy = try AgentWorkflowContinuationReceipt(writer: f.instance, submission: #require(f.event(.submitted, text: "Legacy").workflow), submittedAt: nil)
        let early = try AgentWorkflowContinuationReceipt(writer: writer, submission: #require(f.event(.submitted, text: "Early B", turn: "B").workflow), submittedAt: Date(timeIntervalSince1970: 303))
        let late = try AgentWorkflowContinuationReceipt(writer: writer, submission: #require(f.event(.submitted, text: "Late B", turn: "B").workflow), submittedAt: Date(timeIntervalSince1970: 305))
        let end = try AgentWorkflowContinuationCompletion(writer: writer, event: #require(f.event(kind, text: "Late B ended", turn: "B").workflow), startedAt: Date(timeIntervalSince1970: 306))
        var receipt = AgentWorkflowPendingReceipt(conversationID: f.instance.conversationID, turn: turn)
        receipt.mergeContinuations([legacy, late, early], completions: [end])
        let restored = try JSONDecoder().decode(AgentWorkflowPendingReceipt.self, from: JSONEncoder().encode(receipt))
        for value in [receipt, restored] {
            #expect(value.continuations?.first(where: { $0.identifies(early) })?.completion == nil)
            #expect(value.continuations?.first(where: { $0.identifies(late) })?.completion == end.event)
        }
        #expect(peer.processes.first?.processID == writer.processID)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["v9-old-hook", "restarted-writer"])
    func reusedIDReceiptUsesItsOwnNativeSegment(mode: String) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func start(_ id: String, _ time: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": Date(timeIntervalSince1970: Double(time)).formatted(.iso8601), "payload": ["type": "task_started", "turn_id": id]]) + Data([10])
        }
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": f.instance.conversationID]]) + Data([10])
        try (header + start("turn", 2_000)).write(to: f.transcript)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 2_001))
        if mode == "v9-old-hook" {
            await f.router.shutdown()
            var archive = try await f.store.snapshot()
            archive.schemaVersion = 9
            archive.pendingReceipts = nil
            try JSONEncoder().encode(archive).write(to: await f.store.fileURL, options: .atomic)
            let store = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID)
            _ = try await store.reconcile([.init(f.instance)])
            let path = f.directory.appendingPathComponent("B.jsonl")
            try (header + start("B", 1_000) + start("B", 3_000)).write(to: path)
            let runner = f.runner(in: store)
            let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
            for kind in [PluginWorkflowEvent.Kind.submitted, .failed] {
                let event = PluginEvent(
                    pluginID: "codex",
                    sessionID: f.instance.conversationID,
                    tmuxPane: f.instance.paneID,
                    workflow: .init(kind: kind, nativeTurnID: "B", transcriptPath: path.path, text: "Old input")
                )
                _ = try await router.receive(event, peer: f.hookPeer(startedAt: kind == .submitted ? 1_001 : 1_002))
            }
            _ = try? await router.requireVerifiedSubmission(f.invocation.id)
            let call = try await store.snapshot().runs[0].invocations[0]
            #expect(call.status != .failed && call.resultTurnID == "turn")
            await router.shutdown()
            await runner.shutdown()
        } else {
            let file = try FileHandle(forWritingTo: f.transcript)
            try file.seekToEnd()
            try file.write(contentsOf: start("B", 3_000))
            try file.close()
            _ = try await f.router.receive(f.event(.submitted, text: "Old B", turn: "B"), peer: f.hookPeer(startedAt: 3_001))
            try await f.router.requireVerifiedSubmission(f.invocation.id)
            try f.appendCodexAbort("B")
            let peer = try await f.replaceProcess(in: f.store)
            let next = try FileHandle(forWritingTo: f.transcript)
            try next.seekToEnd()
            try next.write(contentsOf: start("B", 4_000))
            try next.close()
            _ = try await f.router.receive(f.event(.submitted, text: "New B", turn: "B"), peer: f.hookPeer(startedAt: 4_001, source: peer))
            let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { try await f.router.requireVerifiedSubmission($0) })
            let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
            #expect(await service.handle(request, peer: peer).error?.code == "workflow_denied")
            let call = try await f.store.snapshot().runs[0].invocations[0]
            #expect(call.status == .failed && call.result == nil)
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func lateSameIDReceiptCannotBorrowTheFollowingSubmission(restart: Bool, differentID: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func start(_ id: String, at time: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "timestamp": Date(timeIntervalSince1970: Double(time)).formatted(.iso8601),
                "payload": ["type": "task_started", "turn_id": id],
            ]) + Data([10])
        }
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": f.instance.conversationID]]) + Data([10])
        try (header + start("turn", at: 1_000)).write(to: f.transcript)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 1_001))
        try f.appendCodexAnswer("First proposal")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "First proposal"), peer: f.hookPeer(startedAt: 1_002))
        await f.router.shutdown()
        let file = try FileHandle(forWritingTo: f.transcript)
        try file.seekToEnd()
        try file.write(contentsOf: start("turn", at: 2_000))
        try file.close()
        try f.appendCodexAbort("turn")
        let following = try FileHandle(forWritingTo: f.transcript)
        try following.seekToEnd()
        try following.write(contentsOf: start(differentID ? "C" : "turn", at: 3_000))
        try following.close()

        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        _ = try await router.receive(f.event(.submitted, text: "Second input"), peer: f.hookPeer(startedAt: 2_001))
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        _ = try await store.reconcile([.init(f.instance)])
        let runner = restart ? f.runner(in: store) : f.runner
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        available.setValue(true)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error?.code == "workflow_denied")
        let saved = try await store.snapshot()
        #expect(saved.runs[0].invocations[0].stepTurn?.completionRequested == false)
        #expect(saved.runs[0].invocations[0].status == .failed && saved.runs[0].invocations[0].issue == "The native Codex turn was interrupted.")
        #expect(saved.runs[0].invocations[0].result == nil)
        await active.shutdown()
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func claudeSubmissionBoundaryRetainsThePreviousOutcome(restart: Bool, completed: Bool) async throws {
        let f = try await fixture(plugin: "claude-code", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func append(_ fields: [String: Any]) throws {
            let record = fields.merging(["sessionId": f.instance.conversationID, "isSidechain": false]) { value, _ in value }
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        }
        try append(["type": "user", "uuid": "user", "promptId": "turn", "timestamp": "1970-01-01T00:16:40Z"])
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "claude-code"), peer: f.hookPeer(startedAt: 1_001))
        try append([
            "type": "assistant", "uuid": "answer", "parentUuid": "user",
            "message": ["id": "answer", "stop_reason": "end_turn", "content": [["type": "text", "text": "Old answer"]]],
        ])
        if completed {
            try append([
                "type": "system", "uuid": "stop", "parentUuid": "answer", "subtype": "stop_hook_summary",
                "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": "",
            ])
            _ = try await f.router.receive(f.event(.stopCandidate, text: "Old answer", plugin: "claude-code"), peer: f.hookPeer(startedAt: 1_002))
        }
        await f.router.shutdown()
        let peer = try await f.replaceProcess(in: f.store)
        try append([
            "type": "user", "uuid": "next", "parentUuid": completed ? "stop" : "answer", "promptId": "C",
            "timestamp": "1970-01-01T00:33:20Z", "message": ["content": String(repeating: "x", count: 3 * 1_024 * 1_024)],
        ])
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { $0 }, provider: { _ in
            available.value ? f.nativeProvider : nil
        })
        _ = try await router.receive(f.event(.submitted, text: "New task", turn: "C", plugin: "claude-code"), peer: f.hookPeer(startedAt: 2_001, source: peer))
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        let activePeer = try await f.replaceProcess(in: store)
        let runner = restart ? f.runner(in: store) : f.runner
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        available.setValue(true)
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await active.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        let response = await service.handle(request, peer: activePeer)
        let saved = try await store.snapshot().runs[0].invocations[0]
        if completed {
            #expect(response.ok && saved.resultTurnID == "C")
        } else {
            #expect(response.error?.code == "workflow_denied")
            #expect(saved.status == .failed && saved.issue == "A different user prompt interrupted this workflow turn.")
        }
        #expect(saved.result == nil)
        await active.shutdown()
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["none", "tool-result", "stop-feedback"], [("delayed", false), ("delayed", true), ("new-process", false), ("new-process", true)])
    func claudeInternalMessagesDoNotSplitTheSubmission(kind: String, scenario: (String, Bool)) async throws {
        let (mode, restart) = scenario
        let f = try await fixture(plugin: "claude-code", completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func append(_ fields: [String: Any]) throws {
            let record = fields.merging(["sessionId": f.instance.conversationID, "isSidechain": false]) { value, _ in value }
            let file = try FileHandle(forWritingTo: f.transcript)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
        }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "claude-code"), peer: f.hookPeer(startedAt: 101))
        if mode == "delayed" {
            try f.appendNativeAnswer("Initial proposal")
            _ = try await f.router.receive(f.event(.stopCandidate, text: "Initial proposal", plugin: "claude-code"), peer: f.hookPeer(startedAt: 102))
            try append(["type": "user", "uuid": "discussion", "promptId": "B", "timestamp": "1970-01-01T00:33:20Z"])
        }
        let turn = mode == "delayed" ? "B" : "turn"
        let parents = try Data(contentsOf: f.transcript).split(separator: 10).compactMap { line in
            try (JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])?["uuid"] as? String
        }
        let parent = try #require(parents.last)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in available.value ? f.nativeProvider : nil })
        if mode == "delayed" {
            await f.router.shutdown()
            _ = try await router.receive(f.event(.submitted, text: "Discuss the plan", turn: turn, plugin: "claude-code"), peer: f.hookPeer(startedAt: 2_001))
        }
        if kind != "none" {
            try append([
                "type": "assistant", "uuid": "working", "parentUuid": parent,
                "message": ["id": "working", "stop_reason": kind == "tool-result" ? "tool_use" : "end_turn", "content": []],
            ])
            let content: Any = kind == "tool-result"
                ? [["type": "tool_result", "tool_use_id": "tool", "content": "Result"]]
                : "Stop hook feedback: Continue"
            try append([
                "type": "user", "uuid": "internal", "parentUuid": "working", "promptId": turn,
                "timestamp": "1970-01-01T00:33:22Z", "message": ["role": "user", "content": content],
            ])
        }
        try f.appendNativeAnswer("Verified proposal", turn: turn)
        let stop = f.event(.stopCandidate, text: "Verified proposal", turn: turn, plugin: "claude-code")
        if mode == "delayed" {
            _ = try await router.receive(stop, peer: f.hookPeer(startedAt: 2_010))
        } else {
            _ = try await f.router.receive(stop, peer: f.hookPeer(startedAt: 2_010))
            await f.router.shutdown()
            let peer = try await f.replaceProcess(in: f.store)
            let last = try #require(Data(contentsOf: f.transcript).split(separator: 10).last)
            let previous = try #require((JSONSerialization.jsonObject(with: Data(last)) as? [String: Any])?["uuid"] as? String)
            try append(["type": "user", "uuid": "next", "parentUuid": previous, "promptId": "C", "timestamp": "1970-01-01T00:50:00Z"])
            _ = try await router.receive(f.event(.submitted, text: "New task", turn: "C", plugin: "claude-code"), peer: f.hookPeer(startedAt: 3_001, source: peer))
        }
        if restart {
            await router.shutdown()
        }
        let store = restart ? AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID) : f.store
        if mode == "new-process" {
            _ = try await f.replaceProcess(in: store)
        } else {
            _ = try await store.reconcile([.init(f.instance)])
        }
        let runner = restart ? f.runner(in: store) : f.runner
        let active = restart ? AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider }) : router
        available.setValue(true)
        try await active.requireVerifiedSubmission(f.invocation.id)
        let writes = LockIsolated(0)
        let service = AgentWorkflowService(store: store, scan: { _ in
            try await store.snapshot().instances.map { AgentWorkflowObservation($0) }
        }, schedule: { _ in }, synchronizeEvents: { try await active.requireVerifiedSubmission($0, allowingStoppedReplay: true) }, resumeStep: { _, _ in
            writes.withValue { $0 += 1 }
        })
        let before = try await store.snapshot().runs[0]
        let paused = before.status == .paused ? before : try await service.pause(runID: before.id, expectedRevision: before.revision)
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.status == .running && writes.value == 1)
        let saved = try #require(resumed.invocations.first)
        #expect(saved.resultTurnID == (mode == "delayed" ? "B" : "C"))
        #expect(saved.stepTurn?.stopped == (mode == "delayed"))
        #expect(saved.result == nil)
        await active.shutdown()
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["ascii", "utf8", "escaped"])
    func metadataContentPrefixesRemainBoundedAndValid(kind: String) throws {
        let data: Data
        if kind == "escaped" {
            data = Data((#"{"message":{"content":""# + String(repeating: #"\u4e2d\ud83d\ude00"#, count: 80) + #""}}"#).utf8)
        } else {
            let text = kind == "ascii" ? "Stop hook feedback: " + String(repeating: "x", count: 3 * 1_024 * 1_024) : "Prefix " + String(repeating: "中😀\\\n\"", count: 80)
            data = try JSONSerialization.data(withJSONObject: ["message": ["content": text]])
        }
        var record = AgentWorkflowTranscriptRecord(turnMetadataOnly: true)
        let chunk = kind == "ascii" ? 4_093 : 7
        for start in stride(from: 0, to: data.count, by: chunk) {
            try record.append(data[start..<min(start + chunk, data.count)])
        }
        let value = try JSONSerialization.jsonObject(with: record.finish()) as? [String: Any]
        let prefix = try #require((value?["message"] as? [String: Any])?["content"] as? String)
        let original = try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? [String: Any])
        #expect((original["content"] as? String)?.hasPrefix(prefix) == true)
        #expect(record.retained.count < 1_024 && prefix.utf8.count <= 256)
        if kind == "ascii" {
            #expect(prefix.hasPrefix("Stop hook feedback:"))
        }
    }

    @Test
    func currentWriterFailureSettlesBeforeAnOlderUnknownTurn() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        _ = try await f.router.receive(f.event(.submitted, text: "B input", turn: "B"), peer: f.hookPeer(startedAt: 103))
        let peer = try await f.replaceProcess(in: f.store)
        try f.appendNativeTurn("C")
        _ = try await f.router.receive(f.event(.submitted, text: "C input", turn: "C"), peer: f.hookPeer(startedAt: 305, source: peer))
        try f.appendCodexAbort("C")
        _ = try await f.router.receive(f.event(.failed, text: "C failure", turn: "C"), peer: f.hookPeer(startedAt: 306, source: peer))
        _ = try? await f.router.requireVerifiedSubmission(f.invocation.id)
        let call = try await f.store.snapshot().runs[0].invocations[0]
        #expect(call.status == .failed && call.resultTurnID == "C" && call.issue == "C failure")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func legacyStoppedTurnCanResumeInANewProcessWithoutStopReplay() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Proposal")
        _ = try await f.store.update(runID: f.run.id) { try $0.stopStepTurn(invocationID: f.invocation.id, turnID: "turn") }
        await f.router.shutdown()
        var archive = try await f.store.snapshot()
        archive.schemaVersion = 9
        archive.pendingReceipts = nil
        try JSONEncoder().encode(archive).write(to: await f.store.fileURL, options: .atomic)
        let store = AgentWorkflowStore(fileURL: await f.store.fileURL, hostID: f.instance.hostID)
        let peer = try await f.replaceProcess(in: store)
        let runner = f.runner(in: store)
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 }, provider: { _ in f.nativeProvider })
        let sent = LockIsolated<[String]>([])
        let service = AgentWorkflowService(store: store, scan: { _ in try [.init(#require(await store.snapshot().instances.first))] }, schedule: { _ in }, resumeStep: { call, writer in
            let permit = try #require(await store.authorizeContinuation(call, instance: writer))
            try permit.perform { sent.withValue { $0.append(AgentWorkflowPrompt.continuation(definition: f.run.definition, nodeID: call.nodeID, invocationID: call.id)) } }
            try await store.finishContinuation(call, authorization: permit, written: true)
        })
        let before = try await store.snapshot().runs[0]
        _ = try await service.resume(runID: before.id, expectedRevision: before.revision)
        let prompt = try #require(sent.value.first)
        #expect(sent.value.count == 1)
        try f.appendNativeTurn("C")
        _ = try await router.receive(f.event(.submitted, text: prompt, turn: "C"), peer: peer)
        try await router.requireVerifiedSubmission(f.invocation.id)
        let commands = AgentWorkflowAgentService(store: store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await commands.handle(request, peer: peer).ok)
        await router.shutdown()
        await runner.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func continueReusesTheArchivedFrozenTurnFailure() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn", "B")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await f.router.receive(f.event(.submitted, text: "B input", turn: "B"), peer: f.hookPeer(startedAt: 103))
        try f.appendCodexAnswer("B proposal", turn: "B")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "B proposal", turn: "B"), peer: f.hookPeer(startedAt: 104))
        let peer = try await f.replaceProcess(in: f.store)
        try f.appendNativeTurn("C")
        _ = try await f.router.receive(f.event(.submitted, text: "C input", turn: "C"), peer: peer)
        let commands = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { try await f.router.requireVerifiedSubmission($0) })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await commands.handle(request, peer: peer).ok)
        let paused = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator pause", operatorInitiated: true) }
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in f.nativeProvider }, synchronizeIngress: {
            _ = try await f.router.receive(f.event(.failed, text: "B late failure", turn: "B"), peer: f.hookPeer(startedAt: 105))
            _ = try? await f.router.requireVerifiedSubmission(f.invocation.id)
        })
        let recovered = try await recovery.recover(paused)
        #expect(recovered.status == .paused && recovered.invocations[0].status == .failed && recovered.invocations[0].issue == "B late failure")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func submissionWindowSkipsUnrelatedLargeRecords() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let large = String(repeating: "x", count: 3 * 1_024 * 1_024)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": f.instance.conversationID]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": large]],
            ["type": "event_msg", "timestamp": "1970-01-01T00:01:42Z", "payload": ["type": "task_started", "turn_id": "B"]],
            ["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": "B"]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "C"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": large]],
        ]
        let bytes = try records.reduce(into: Data()) { try $0.append(JSONSerialization.data(withJSONObject: $1) + Data([10])) }
        try bytes.write(to: f.transcript)
        let parser = CodexWorkflowTranscript(conversationID: f.instance.conversationID, nativeTurnID: "B")
        let metadata = try AgentWorkflowTranscriptFile(path: f.transcript.path, parser: parser)
        let proof = try #require(await metadata.verifySubmittedTurn(.init(nativeTurnID: "B", transcriptPath: f.transcript.path)))
        let reader = try AgentWorkflowTranscriptFile(path: f.transcript.path, parser: parser)
        let result = try #require(await reader.verifiedOutcome(for: proof, hasStop: false))
        #expect(result.0 == .failed("The native Codex turn was interrupted."))
        #expect(await reader.bytesRead < 128 * 1_024)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func continuationWithTheSameIDCanCompleteWithoutResendingItsPrompt(stopArrived: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        if stopArrived {
            _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        }
        let stopped = try await f.store.snapshot().runs[0].invocations[0]
        let permit = try #require(await f.store.authorizeContinuation(stopped, instance: f.instance))
        try await f.store.finishContinuation(stopped, authorization: permit, written: true)
        let command = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await f.router.requireVerifiedSubmission($0)
        })
        #expect(await service.handle(command, peer: f.peer).error?.code == "workflow_denied")
        try f.appendNativeTurn("turn")
        _ = try await f.router.receive(f.event(.submitted, text: "Continue this step"), peer: f.hookPeer(startedAt: 103))
        try #require(await service.handle(command, peer: f.peer).ok)
        let accepted = try await f.store.snapshot().runs[0].invocations[0]
        #expect(accepted.continuationTurnID == "turn" && accepted.continuationInstance == nil)
        #expect(try await f.store.authorizeContinuation(accepted, instance: f.instance) == nil)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["success", "reopen", "restop", "explicit-success"])
    func continueAcceptsVerifiedProgressDuringIngressDrain(scenario: String) async throws {
        let explicit = scenario != "success"
        let f = try await fixture(completion: explicit ? .explicit : .replyEnded)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.writeNativeTurns("turn")
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.hookPeer(startedAt: 101))
        try f.appendCodexAnswer("Proposal")
        if scenario == "reopen" || scenario == "restop" {
            _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        } else if explicit {
            _ = try await f.store.update(runID: f.run.id) {
                try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
        }
        let paused = try await f.store.update(runID: f.run.id) { $0.pause(reason: "Operator paused") }
        let recovery = AgentWorkflowResultRecovery(store: f.store, inspect: { $0 }, provider: { _ in f.nativeProvider }, synchronizeIngress: {
            if scenario == "reopen" || scenario == "restop" {
                try f.appendNativeTurn("turn")
                _ = try await f.router.receive(f.event(.submitted, text: "Implement"), peer: f.hookPeer(startedAt: 103))
                try await f.router.requireVerifiedSubmission(f.invocation.id)
                if scenario == "restop" {
                    try f.appendCodexAnswer("Clarification")
                    _ = try await f.router.receive(f.event(.stopCandidate, text: "Clarification"), peer: f.hookPeer(startedAt: 104))
                }
            } else {
                if explicit {
                    _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
                }
                try await f.runner.succeeded(
                    runID: f.run.id,
                    result: .init(invocationID: f.invocation.id, nativeTurnID: "turn", text: "Proposal", completedAt: Date()),
                    instance: f.instance
                )
            }
        })
        let service = AgentWorkflowService(
            store: f.store, scan: { _ in [.init(f.instance)] }, schedule: { _ in }, resumeStep: { _, _ in },
            recoverResults: { try await recovery.recover($0) }
        )
        let resumed = try await service.resume(runID: paused.id, expectedRevision: paused.revision)
        #expect(resumed.status != .paused)
        if scenario == "reopen" || scenario == "restop" {
            #expect(resumed.invocations[0].stepTurn?.stopped == (scenario == "restop"))
        } else {
            #expect(resumed.invocations[0].result?.text == "Proposal")
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppedTurnRetainsItsContinuationWhenInspectionTimesOut() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(true)
        let clock = WorkflowRetryTestClock()
        let timedOut = AsyncStream<Void>.makeStream()
        defer {
            timedOut.continuation.finish()
            clock.sleeps.continuation.finish()
        }
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            if !available.value {
                throw AgentWorkflowInspectionUnavailable()
            }
            return $0
        }, verificationTimeout: .zero, clock: AnyClock(clock), provider: { _ in f.nativeProvider }, onFailure: { _ in
            timedOut.continuation.yield(())
        })
        try f.writeNativeTurns("turn")
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.appendCodexAnswer("Proposal")
        _ = try await router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.hookPeer(startedAt: 102))
        available.setValue(false)
        try f.appendNativeTurn("turn")
        _ = try await router.receive(f.event(.submitted, text: "Implement it"), peer: f.hookPeer(startedAt: 103))
        try await clock.advancePastNextSleep()
        var expiration = timedOut.stream.makeAsyncIterator()
        try #require(await expiration.next() != nil)
        available.setValue(true)
        try await router.requireVerifiedSubmission(f.invocation.id)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == false)
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func laterDiscussionReceiptSurvivesInitialReceiptVerification() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, provider: { _ in f.nativeProvider })
        try f.writeNativeTurns("turn", "next")
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.peer)
        _ = try await router.receive(f.event(.submitted, text: "Clarify", turn: "next"), peer: f.peer)
        _ = try await router.receive(f.event(.stopCandidate, text: "Clarification", turn: "next"), peer: f.peer)
        available.setValue(true)
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try await f.store.snapshot().runs[0].invocations[0]
        #expect(saved.nativeTurnID == "turn")
        #expect(saved.stepTurn?.id == "next" && saved.stepTurn?.stopped == true)
        #expect(saved.result == nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func proposalAndHumanDiscussionWaitUntilAnExplicitlyCompletedTurn(plugin: String, logAheadOfStop: Bool) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await f.router.requireVerifiedSubmission($0)
        })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        try f.writeNativeTurns("turn")
        #expect(await service.handle(request, peer: f.peer).error != nil)
        #expect(try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer) == nil)
        try f.appendNativeAnswer("Please confirm the design")
        if logAheadOfStop {
            try f.appendNativeTurn("turn")
        }
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Please confirm the design", plugin: plugin), peer: f.peer) == nil)
        var saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == .running && saved.invocations[0].result == nil)
        #expect(AgentWorkflowInvocationSummary(saved.invocations[0]).awaitingStepCompletion)
        #expect(try AgentWorkflowExecution(validating: saved).readyNodeIDs.isEmpty)
        let restored = try AgentWorkflowExecution(restoring: saved)
        #expect(restored.run.invocations[0].status == .running)
        #expect(await service.handle(request, peer: f.peer).error != nil) // A stopped proposal is not a current tool turn.

        _ = try await f.router.receive(f.event(.submitted, text: "Answer to the question", plugin: plugin), peer: f.peer)
        if !logAheadOfStop {
            #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
            try f.appendNativeTurn("turn")
        }
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        let continued = try await f.store.snapshot().runs[0].invocations[0]
        #expect(continued.stepTurn?.stopped == false && continued.stepTurn?.prompt == f.invocation.delivery.input.text)
        #expect(try await f.store.snapshot().pendingReceipts?[f.invocation.id]?.completion == nil)
        try f.appendNativeTurn("discussion")
        let discussion = f.event(.submitted, text: "Discuss an alternative", turn: "discussion", plugin: plugin)
        _ = try await f.router.receive(discussion, peer: f.peer)
        try f.appendNativeAnswer("Alternative proposal", turn: "discussion")
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Alternative proposal", turn: "discussion", plugin: plugin), peer: f.peer)
        _ = try await f.router.receive(discussion, peer: f.peer)
        #expect(await service.handle(request, peer: f.peer).error != nil)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == true)
        try f.appendNativeTurn("discussion")
        try await f.router.requireVerifiedSubmission(f.invocation.id)
        #expect(try await f.store.snapshot().runs[0].invocations[0].stepTurn?.stopped == false)
        try f.appendNativeTurn("implementation")
        _ = try await f.router.receive(f.event(.submitted, text: "Implement the agreed design", turn: "implementation", plugin: plugin), peer: f.peer)
        _ = try await f.router.receive(discussion, peer: f.peer)
        #expect(await service.handle(request, peer: nil).error != nil)
        try #require(await service.handle(request, peer: f.peer).ok)
        try #require(await service.handle(request, peer: f.peer).ok)
        saved = try await f.store.snapshot().runs[0]
        #expect(saved.invocations[0].nativeTurnID == "turn") // Original delivery receipt stays unchanged.
        #expect(saved.invocations[0].stepTurn?.id == "implementation")
        #expect(saved.invocations[0].result == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Old proposal", plugin: plugin), peer: f.peer) == nil)
        // A later manual task cannot replace the explicitly selected result.
        _ = try await f.router.receive(f.event(.submitted, text: "Unrelated question", turn: "other", plugin: plugin), peer: f.peer)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Unrelated answer", turn: "other", plugin: plugin), peer: f.peer) == nil)
        let records: [[String: Any]]
        let provider: any AgentWorkflowProviding
        if plugin == "codex" {
            provider = CodexPluginCore()
            records = [
                ["type": "session_meta", "payload": ["id": "conversation"]],
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn"]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn", "last_agent_message": "Please confirm the design"]],
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "implementation"]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "implementation", "last_agent_message": "Implementation and checks done"]],
            ]
        } else {
            provider = ClaudeCodePluginCore()
            records = [
                ["type": "user", "uuid": "user", "promptId": "implementation", "sessionId": "conversation", "isSidechain": false],
                [
                    "type": "assistant",
                    "uuid": "answer",
                    "parentUuid": "user",
                    "sessionId": "conversation",
                    "isSidechain": false,
                    "message": ["id": "message", "stop_reason": "end_turn", "content": [["type": "text", "text": "Implementation and checks done"]]],
                ],
                [
                    "type": "system",
                    "subtype": "stop_hook_summary",
                    "uuid": "stop",
                    "parentUuid": "answer",
                    "sessionId": "conversation",
                    "isSidechain": false,
                    "hookErrors": [],
                    "hookAdditionalContext": [],
                    "preventedContinuation": false,
                    "stopReason": "",
                ],
            ]
        }
        var bytes = Data()
        for record in records {
            try bytes.append(JSONSerialization.data(withJSONObject: record))
            bytes.append(0x0A)
        }
        try bytes.write(to: f.transcript)
        let context = try #require(await f.router.receive(f.event(.stopCandidate, text: "Implementation and checks done", turn: "implementation", plugin: plugin), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, verificationTimeout: .seconds(2), onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(context, provider: provider)
        for _ in 0..<100 {
            saved = try await f.store.snapshot().runs[0]
            if saved.status.isTerminal || saved.status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saved.status == .completed)
        #expect(saved.invocations[0].result?.text == "Implementation and checks done")
        #expect(saved.invocations[0].result?.nativeTurnID == "implementation")
        _ = try AgentWorkflowExecution(validating: saved)
        #expect(await service.handle(request, peer: f.peer).error != nil)
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func nativeImageReceiptRequiresTheWholeTaskAndExactAttachmentCount() async throws {
        let f = try await fixture(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let text = f.invocation.delivery.input.text
        #expect(f.invocation.nativeImageNumbers == [3, 5])
        #expect(!text.contains("workflow attachments"))
        #expect(try await f.router.receive(f.event(.submitted, text: "[Image #1] " + text), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0].invocations[0].nativeTurnID == nil)
        _ = try #require(await f.router.receive(f.event(.submitted, text: "[Image #3] [Image #5] " + text), peer: f.peer))
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.invocations.count == 1 && saved.invocations[0].nativeTurnID == "turn")
        #expect(saved.status == .running) // Other input cannot claim or pause this task.
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func firstQuestionSurvivesConcurrentInitialConversationBinding() async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let conversation = UUID().uuidString
        _ = try await f.router.receive(.init(
            pluginID: "codex", sessionID: conversation,
            notification: .init(title: "Question", body: "Which approach?", isQuestion: true), tmuxPane: "%1"
        ), peer: f.peer)
        let pending = try await f.store.snapshot().runs[0]
        #expect(pending.status == .running && pending.invocations[0].hasAskedQuestion == true)
        #expect(pending.instances[0].conversationID.isEmpty)
        _ = try await f.router.receive(.init(
            pluginID: "codex", sessionID: conversation, tmuxPane: "%1",
            workflow: .init(kind: .submitted, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text)
        ), peer: f.peer)
        let accepted = try await f.store.snapshot().runs[0]
        #expect(accepted.status == .running && accepted.invocations[0].status == .running)
        #expect(accepted.instances[0].conversationID == conversation)
        #expect(accepted.invocations[0].hasAskedQuestion == true)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func firstCodexReceiptConfirmsAnInitiallyUnpersistedConversation(uncertain: Bool, fresh: Bool) async throws {
        let f = try await fixture(conversation: fresh ? "" : "conversation")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if uncertain {
            try await f.store.update(runID: f.run.id) { try $0.writeUncertain(invocationID: f.invocation.id, reason: "Waiting for receipt") }
        }
        var current = f.instance
        current.conversationID = UUID().uuidString
        _ = try await f.store.reconcile([.init(current)])
        #expect(try await f.store.snapshot().runs[0].issue == (uncertain ? "Waiting for receipt" : nil))
        let event = PluginEvent(pluginID: "codex", sessionID: current.conversationID, tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "new-turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
        ))
        let context = try #require(await f.router.receive(event, peer: f.peer))
        let saved = try await f.store.snapshot()
        #expect(context.instance.conversationID == current.conversationID)
        #expect(saved.runs[0].instances[0].conversationID == current.conversationID)
        #expect(saved.instances[0].conversationID == current.conversationID)
        #expect(saved.runs[0].invocations[0].nativeTurnID == "new-turn")
        #expect(saved.runs[0].invocations[0].status == .running)
        if fresh {
            for readiness in [AgentWorkflowReadiness.ready, .unavailable] {
                var stale = AgentWorkflowObservation(f.instance)
                stale.readiness = readiness
                await #expect(throws: AgentWorkflowCatalogChanged.self) { try await f.store.reconcile([stale]) }
                #expect(try await f.store.snapshot() == saved)
            }
        }
        await #expect(throws: AgentWorkflowError.self) {
            try await f.store.update(runID: f.run.id) {
                try $0.accept(invocationID: f.invocation.id, instance: f.instance, nativeTurnID: "new-turn")
            }
        }
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func firstReceiptAfterPaneMoveKeepsInvocationRecoverable(paused: Bool, catalogRefreshed: Bool) async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.store.update(runID: f.run.id) {
            try $0.didWrite(invocationID: f.invocation.id)
            if paused {
                $0.pause(reason: "Operator paused")
            }
        }
        let conversation = UUID().uuidString, windowID = UUID(), sessionID = UUID()
        if catalogRefreshed {
            var moved = AgentWorkflowObservation(f.instance)
            moved.workspacePane.windowID = windowID
            moved.workspacePane.sessionID = sessionID
            _ = try await f.store.reconcile([moved])
        }
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            var live = $0
            live.workspacePane.windowID = windowID
            live.workspacePane.sessionID = sessionID
            return live
        })
        let event = PluginEvent(pluginID: "codex", sessionID: conversation, tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "first-turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
        ))
        let context = try await router.receive(event, peer: f.peer)
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
        #expect(context?.instance.workspacePane.windowID == windowID)
        let saved = try await f.store.snapshot().runs[0]
        var expected = f.instance
        expected.conversationID = conversation
        #expect(saved.status == (paused ? .paused : .running))
        #expect(saved.instances[0].agentID == expected.agentID)
        #expect(saved.instances[0].workspacePane.windowID == (!paused && catalogRefreshed ? windowID : expected.workspacePane.windowID))
        #expect(saved.instances[0].matchesBinding(expected))
        #expect(saved.invocations[0].instance == expected)
        #expect(saved.invocations[0].nativeTurnID == "first-turn")
        #expect(saved.invocations[0].status == .running)
        #expect(try AgentWorkflowExecution(validating: saved).run == saved)

        let file = f.directory.appendingPathComponent("ledger.json")
        let restoredStore = AgentWorkflowStore(fileURL: file, hostID: f.instance.hostID)
        let restored = try await restoredStore.snapshot().runs[0]
        #expect(restored.status == .paused)
        #expect(restored.invocations[0].instance == expected)
        #expect(restored.invocations[0].nativeTurnID == "first-turn")
        #expect(restored.invocations[0].status == .uncertain)
        #expect(restored.invocations[0].delivery == saved.invocations[0].delivery)
        let ended = try await restoredStore.update(runID: restored.id) { $0.end() }
        #expect(ended.status == .ended)
        let reloaded = try await AgentWorkflowStore(fileURL: file, hostID: f.instance.hostID).snapshot()
        #expect(reloaded.runs[0] == ended)
    }

    @Test
    func firstReceiptCannotBypassAnUnsupportedHook() async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            var live = $0
            live.capabilityIssue = "Unsupported workflow hook"
            return live
        })
        let event = PluginEvent(pluginID: "codex", sessionID: UUID().uuidString, tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "new-turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
        ))
        await #expect(throws: AgentWorkflowError.self) { try await router.receive(event, peer: f.peer) }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.instances[0].conversationID.isEmpty)
        #expect(run.invocations[0].nativeTurnID == nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [AgentWorkflowReadiness.ready, .busy, .unavailable])
    func firstReceiptDuringCatalogScanRechecksTheConfirmedConversation(uncertain: Bool, readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if uncertain {
            try await f.store.update(runID: f.run.id) { try $0.writeUncertain(invocationID: f.invocation.id, reason: "Waiting for receipt") }
        }
        let conversation = UUID().uuidString
        let scans = LockIsolated(0)
        let receiptSnapshot = LockIsolated<AgentWorkflowArchive?>(nil)
        let identities = AgentSessionIdentityClient(load: { _ in nil }, recoverySource: { _, _, _ in nil }, save: { _ in false }, invalidate: { _ in }, isInvalidated: { _ in false }, runtimeID: { _ in f.instance.processRuntimeID }, codexOwnsSession: { _, _, id in
            id == conversation
        }, codexSessionID: { _, _ in conversation })
        let service = AgentWorkflowService(store: f.store, scan: { previous in
            var live = try #require(previous.first)
            let scan = scans.withValue { $0 += 1
                return $0
            }
            if scan == 1 {
                #expect(live.conversationID.isEmpty)
                let event = PluginEvent(pluginID: "codex", sessionID: conversation, tmuxPane: "%1", workflow: .init(
                    kind: .submitted, nativeTurnID: "new-turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
                ))
                _ = try #require(await f.router.receive(event, peer: f.peer))
                let accepted = try await f.store.snapshot()
                receiptSnapshot.setValue(accepted)
            } else {
                // The stale observation must not change either the catalog or run
                // before a second scan verifies the now-confirmed conversation.
                #expect(try await f.store.snapshot() == receiptSnapshot.value)
                #expect(live.conversationID == conversation)
            }
            let allowsInitialBinding = try await f.store.allowsInitialConversationBinding(for: live)
            #expect(!allowsInitialBinding)
            live.capabilityIssue = await identities.workflowInputIssue(for: live, allowsInitialBinding: allowsInitialBinding)
            if scan == 1 {
                #expect(live.capabilityIssue != nil)
                live.readiness = .unavailable
            } else {
                #expect(live.capabilityIssue == nil)
                live.readiness = readiness
                if readiness == .unavailable {
                    live.capabilityIssue = "Current conversation is unavailable"
                }
            }
            return [.init(live)]
        }, schedule: { _ in Issue.record("Refreshing the catalog must not submit a task.") })
        let catalog = try await service.refreshInstancesCatalog()
        #expect(scans.value == 2)
        #expect(catalog[0].conversationID == conversation)
        #expect(catalog[0].readiness == readiness)
        #expect(catalog[0].capabilityIssue == (readiness == .unavailable ? "Current conversation is unavailable" : nil))
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == (uncertain || readiness == .unavailable ? .paused : .running))
        #expect(saved.instances[0].conversationID == conversation)
        #expect(saved.invocations.count == 1)
        #expect(saved.invocations[0].nativeTurnID == "new-turn")
        #expect(saved.invocations[0].status == .running)
        await service.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func firstConversationBindingRequiresTheExactWrittenTask() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let event = PluginEvent(pluginID: "codex", sessionID: UUID().uuidString, tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "new-turn", transcriptPath: f.transcript.path, text: "Different task"
        ))
        #expect(try await f.router.receive(event, peer: f.peer) == nil)
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.instances[0].conversationID == f.instance.conversationID)
        #expect(saved.invocations[0].nativeTurnID == nil)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func firstReceiptWaitsForItsNativeWriterWithoutPausingOrLosingStop() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let readable = LockIsolated(false)
        let verified = LockIsolated<AgentWorkflowTurnContext?>(nil)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard readable.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, onVerified: { verified.setValue($0) }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let conversation = UUID().uuidString
        func event(_ kind: PluginWorkflowEvent.Kind, _ text: String) -> PluginEvent {
            .init(pluginID: "codex", sessionID: conversation, tmuxPane: "%1", workflow: .init(
                kind: kind, nativeTurnID: "new-turn", transcriptPath: f.transcript.path, text: text
            ))
        }
        #expect(try await router.receive(event(.submitted, f.invocation.delivery.input.text), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0].status == .running)
        #expect(try await router.receive(event(.stopCandidate, "Final"), peer: f.peer) == nil)
        readable.setValue(true)
        for _ in 0..<100 {
            if verified.value != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try #require(verified.value)
        #expect(context.instance.conversationID == conversation)
        #expect(context.candidate.kind == .stopCandidate)
        let saved = try await f.store.snapshot()
        #expect(saved.runs[0].status == .running)
        #expect(saved.runs[0].invocations.count == 1)
        #expect(saved.runs[0].invocations[0].nativeTurnID == "new-turn")
        #expect(saved.runs[0].instances[0].conversationID == conversation)
        #expect(saved.instances[0].conversationID == conversation)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func earlyStopUsesPendingReceiptWhileCatalogIsEmpty() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        _ = try await reopened.reconcile([])
        #expect(try await reopened.snapshot().instances.isEmpty)
        #expect(try await reopened.snapshot().runs[0].invocations[0].status == .uncertain)

        let writerAvailable = LockIsolated(false)
        let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("The written task must not be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let monitor = AgentWorkflowCompletionMonitor(store: reopened, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let stop = f.event(.stopCandidate, text: "Verified result")
        let router = AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: {
            guard writerAvailable.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, onVerified: { context in
            #expect(context.candidate == stop.workflow)
            await monitor.verify(context, provider: NativeWorkflowTestProvider())
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: f.invocation.submissionText(pluginID: f.instance.pluginID)), peer: f.peer)
        #expect(try await router.receive(stop, peer: f.peer) == nil)
        let unrelated = PluginEvent(pluginID: f.instance.pluginID, sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .failed, nativeTurnID: "turn", transcriptPath: f.transcript.path + ".unrelated", text: "Wrong transcript"
        ))
        #expect(try await router.receive(unrelated, peer: f.peer) == nil)
        #expect(try await reopened.snapshot().runs[0].invocations[0].nativeTurnID == nil)

        try Data("{\"final\":\"Verified result\"}\n".utf8).write(to: f.transcript)
        _ = try await reopened.reconcile([.init(f.instance)])
        writerAvailable.setValue(true)
        for _ in 0..<100 {
            if try await reopened.snapshot().runs[0].invocations[0].status == .succeeded {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try await reopened.snapshot().runs[0].invocations[0]
        #expect(saved.nativeTurnID == "turn")
        #expect(saved.status == .succeeded)
        #expect(saved.result?.text == "Verified result")
        await router.shutdown()
        await monitor.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: [false, true])
    func resultUsesAcceptedReceiptWhileCatalogIsEmpty(failed: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        _ = try await reopened.reconcile([])
        let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("The written task must not be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let monitor = AgentWorkflowCompletionMonitor(store: reopened, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        try await router.receiveUnconfirmedSubmission(f.event(.submitted, text: f.invocation.submissionText(pluginID: f.instance.pluginID)), peer: f.peer)
        for _ in 0..<100 {
            if (try? await router.requireVerifiedSubmission(f.invocation.id)) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await router.requireVerifiedSubmission(f.invocation.id)
        let accepted = try await reopened.snapshot()
        #expect(accepted.instances.isEmpty)
        try #require(accepted.runs[0].invocations[0].status == .running)
        let other = PluginEvent(pluginID: f.instance.pluginID, sessionID: f.instance.conversationID, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .failed, nativeTurnID: "turn", transcriptPath: f.transcript.path + ".other", text: "Wrong transcript"
        ))
        #expect(try await router.receive(other, peer: f.peer) == nil)
        #expect(try await reopened.snapshot().runs[0].invocations[0].status == .running)
        if failed {
            #expect(try await router.receive(f.event(.failed, text: "Native failure"), peer: f.peer) == nil)
        } else {
            let context = try #require(await router.receive(f.event(.stopCandidate, text: "Verified result"), peer: f.peer))
            try Data("{\"final\":\"Verified result\"}\n".utf8).write(to: f.transcript)
            await monitor.verify(context, provider: NativeWorkflowTestProvider())
            _ = try await reopened.reconcile([.init(f.instance)])
            for _ in 0..<100 {
                if try await reopened.snapshot().runs[0].invocations[0].status == .succeeded {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let saved = try await reopened.snapshot().runs[0].invocations[0]
        #expect(saved.status == (failed ? .failed : .succeeded))
        #expect((failed ? saved.issue : saved.result?.text) == (failed ? "Native failure" : "Verified result"))
        await router.shutdown()
        await monitor.shutdown()
        await runner.shutdown()
    }

    @Test(arguments: ["first-receipt", "restarted-agent", "late-transcript", "stale-catalog", "mixed-receipts"])
    func earlyFollowupsUseLatestNativeTurn(scenario: String) async throws {
        let restartedAgent = scenario == "restarted-agent" || scenario == "stale-catalog"
        let firstReceiptPending = scenario == "first-receipt"
        let delayLatestTurn = scenario == "late-transcript" || scenario == "mixed-receipts"
        let f = try await fixture(completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let initial = f.event(.submitted, text: f.invocation.submissionText(pluginID: f.instance.pluginID))
        if !firstReceiptPending {
            _ = try await f.router.receive(initial, peer: f.peer)
        }
        let reopened = await AgentWorkflowStore(fileURL: f.store.fileURL, hostID: f.instance.hostID)
        if scenario == "stale-catalog" {
            #expect(try await reopened.snapshot().instances.first?.processID == f.instance.processID)
        } else {
            _ = try await reopened.reconcile([])
        }
        var observation = AgentWorkflowObservation(f.instance)
        if restartedAgent {
            observation.processID = 20
            observation.processRuntimeID = "501:20:200:0"
        }
        let peer = restartedAgent ? try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        }) : f.peer
        let writerAvailable = LockIsolated(false)
        let startedScan = LockIsolated(false)
        let runner = AgentWorkflowRunner(store: reopened, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("The written task must not be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: reopened, runner: runner, inspect: {
            guard writerAvailable.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, recheckConversation: { _, source, admit in
            admit && writerAvailable.value && source == peer ? .ready : .deferred
        }, provider: { _ in
            startedScan.setValue(true)
            return CodexPluginCore()
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        if firstReceiptPending {
            try await router.receiveUnconfirmedSubmission(initial, peer: peer)
        }
        let earlier = f.event(.submitted, text: "Earlier follow-up", turn: "earlier")
        let latest = f.event(.submitted, text: "Latest review request", turn: "latest")
        let receipts = delayLatestTurn ? [earlier, latest] : [latest, earlier]
        for receipt in receipts {
            if scenario == "mixed-receipts", receipt == latest {
                _ = try await reopened.reconcile([observation])
                _ = try await router.receive(receipt, peer: peer)
            } else {
                try await router.receiveUnconfirmedSubmission(receipt, peer: peer)
            }
        }
        #expect(try await reopened.snapshot().runs[0].invocations[0].resultTurnID == (firstReceiptPending ? nil : "turn"))
        if delayLatestTurn {
            try f.writeCodexTurns("turn", "earlier")
            _ = try await reopened.reconcile([observation])
            writerAvailable.setValue(true)
            for _ in 0..<100 {
                if startedScan.value {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(startedScan.value)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await reopened.snapshot().runs[0].invocations[0].resultTurnID == "turn")
            await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }
        } else if scenario == "stale-catalog" {
            // Let the retry inspect the restored entry for the exited process.
            try await Task.sleep(for: .milliseconds(350))
            #expect(try await reopened.snapshot().runs[0].invocations[0].resultTurnID == "turn")
        }
        try f.writeCodexTurns("turn", "earlier", "latest")
        _ = try await reopened.reconcile([observation])
        writerAvailable.setValue(true)
        for _ in 0..<100 {
            if try await reopened.snapshot().runs[0].invocations[0].resultTurnID == "latest" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await router.requireVerifiedSubmission(f.invocation.id)
        let saved = try await reopened.snapshot().runs[0]
        #expect(saved.invocations[0].nativeTurnID == "turn")
        #expect(saved.invocations[0].resultTurnID == "latest")
        #expect(saved.instance(for: saved.invocations[0])?.processID == observation.processID)
        #expect(saved.invocations[0].instance?.id == saved.invocations[0].delivery.toAgentID)
        let service = AgentWorkflowAgentService(
            store: reopened, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) }, provider: { _ in CodexPluginCore() }
        )
        let approval = await service.handle(f.loopExitRequest(), peer: peer)
        #expect(approval.ok, Comment(rawValue: approval.error?.message ?? ""))
        await router.shutdown()
        await runner.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["reworded", "same-input", "same-input-reversed"])
    func claudeRejectionReleasesOnlyTheMatchingPendingInput(retry: String) async throws {
        let f = try await fixture(plugin: "claude-code", completion: .explicit, afterLoop: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: f.instance.pluginID), peer: f.peer)
        let blocked = "Review the first draft."
        let sameInput = retry != "reworded"
        func transcript(includeCurrentRejection: Bool) throws -> Data {
            func rejection(at timestamp: String, prompt: String) -> [String: Any] {
                [
                    "type": "system", "subtype": "informational", "timestamp": timestamp, "preventContinuation": true,
                    "content": "UserPromptSubmit operation blocked by hook:\n[fixture]: Rejected.\n\nOriginal prompt: " + prompt,
                    "promptSubmitEnding": ["ending": ["kind": "blocked_by_hook", "reason": "Rejected."], "promptKept": false],
                ]
            }
            var records: [[String: Any]] = [
                ["type": "user", "promptId": "turn"],
                rejection(at: "1970-01-01T00:02:30.000Z", prompt: blocked),
                rejection(at: "1970-01-01T00:03:20.500Z", prompt: "An unrelated input\nOriginal prompt: " + blocked),
            ]
            if includeCurrentRejection {
                records.append(rejection(at: "1970-01-01T00:03:21.000Z", prompt: blocked))
            } else if sameInput {
                // A matching record at the next hook's start cannot identify the first turn.
                records.append(rejection(at: "1970-01-01T00:03:22.000Z", prompt: blocked))
            }
            records.append(["type": "user", "promptId": "revised"])
            return try records.enumerated().reduce(into: Data()) { data, entry in
                var record = entry.element
                record["uuid"] = "record-\(entry.offset)"
                record["sessionId"] = f.instance.conversationID
                record["isSidechain"] = false
                try data.append(JSONSerialization.data(withJSONObject: record))
                data.append(10)
            }
        }
        try transcript(includeCurrentRejection: false).write(to: f.transcript)
        func hookPeer(_ hookPID: Int32, startedAt: UInt64) throws -> PluginIngressPeer {
            try #require(PluginIngressPeer.capture(peerPID: hookPID, userID: 501) { pid in
                switch pid {
                case hookPID: .init(processID: hookPID, parentProcessID: 10, userID: 501, startSeconds: startedAt, startMicroseconds: 0)
                case 10: .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
                default: nil
                }
            })
        }
        let scanned = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { $0 }, recheckConversation: { _, _, admit in
            admit ? .ready : .deferred
        }, provider: { _ in
            scanned.setValue(true)
            return ClaudeCodePluginCore()
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let first = f.event(.submitted, text: blocked, turn: "blocked", plugin: f.instance.pluginID)
        let second = f.event(.submitted, text: sameInput ? blocked : "Review the revised draft.", turn: "revised", plugin: f.instance.pluginID)
        let receipts = try [(first, hookPeer(21, startedAt: 200)), (second, hookPeer(22, startedAt: 202))]
        for (event, peer) in retry == "same-input-reversed" ? Array(receipts.reversed()) : receipts {
            try await router.receiveUnconfirmedSubmission(event, peer: peer)
        }
        for _ in 0..<100 {
            if scanned.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(scanned.value)
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
        await #expect(throws: AgentWorkflowError.self) { try await router.requireVerifiedSubmission(f.invocation.id) }

        try transcript(includeCurrentRejection: true).write(to: f.transcript)
        for _ in 0..<100 {
            if try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "revised" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await router.requireVerifiedSubmission(f.invocation.id)
        let service = AgentWorkflowAgentService(
            store: f.store, inspect: { $0 }, synchronizeEvents: { try await router.requireVerifiedSubmission($0) },
            provider: { _ in ClaudeCodePluginCore() }
        )
        let approval = await service.handle(f.loopExitRequest(), peer: f.peer)
        #expect(approval.ok, Comment(rawValue: approval.error?.message ?? ""))
        let saved = try await f.store.snapshot().runs[0].invocations[0]
        #expect(saved.nativeTurnID == "turn")
        #expect(saved.resultTurnID == "revised")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func pendingContinuationSuppressesOnlyItsOwnCompletionAfterNewConversation() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.submissionText(pluginID: f.instance.pluginID)), peer: f.peer)
        let conversation = "new-conversation"
        let transcript = f.directory.appendingPathComponent("new-session.jsonl")
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { $0 }, recheckConversation: { _, _, _ in .deferred })
        let submitted = PluginEvent(pluginID: f.instance.pluginID, sessionID: conversation, tmuxPane: f.instance.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "continued", transcriptPath: transcript.path, text: "Continue review"
        ))
        try await router.receiveUnconfirmedSubmission(submitted, peer: f.peer)
        let notifications = LockIsolated([String]())
        let dispatcher = PluginEventDispatcher(onNotification: { _, _, notice, _ in
            notifications.withValue { $0.append(notice.body) }
        }, onWorkflow: { event, peer in
            do { _ = try await router.receive(event, peer: peer) }
            catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        }, shouldSuppressAgentCompletion: { event, peer in
            do { return try await router.suppressesAgentCompletion(event, peer: peer) }
            catch {
                Issue.record(Comment(rawValue: error.localizedDescription))
                return false
            }
        })
        func stop(_ text: String, path: String) -> PluginEvent {
            .init(
                pluginID: f.instance.pluginID, sessionID: conversation, state: .doneWorking(summary: nil),
                notification: .init(title: "Finished", body: text), tmuxPane: f.instance.paneID,
                workflow: .init(kind: .stopCandidate, nativeTurnID: "continued", transcriptPath: path, text: text)
            )
        }
        let otherPeer = try #require(PluginIngressPeer.capture(peerPID: 20, userID: 501) { pid in
            pid == 20 ? .init(processID: 20, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0) : nil
        })
        let completed = stop("Workflow reply", path: transcript.path)
        #expect(try await !router.suppressesAgentCompletion(completed, peer: otherPeer))
        await dispatcher.dispatch(completed, ingressPeer: f.peer)
        await dispatcher.dispatch(stop("Unrelated reply", path: f.transcript.path), ingressPeer: f.peer)
        #expect(notifications.value == ["Unrelated reply"])
        #expect(try await f.store.snapshot().runs[0].invocations[0].resultTurnID == "turn")
        await router.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func questionAnswerPreservesThePendingFirstReceipt(awaitingAcceptance: Bool) async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        if awaitingAcceptance {
            try await f.store.update(runID: f.run.id) { try $0.didWrite(invocationID: f.invocation.id) }
        }
        let readable = LockIsolated(false)
        let verified = LockIsolated<AgentWorkflowTurnContext?>(nil)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard readable.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, onVerified: { verified.setValue($0) }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let conversation = UUID().uuidString
        func submission(_ text: String) -> PluginEvent {
            .init(pluginID: "codex", sessionID: conversation, tmuxPane: "%1", workflow: .init(
                kind: .submitted, nativeTurnID: "first-turn", transcriptPath: f.transcript.path, text: text
            ))
        }
        #expect(try await router.receive(submission(f.invocation.delivery.input.text), peer: f.peer) == nil)
        _ = try await router.receive(.init(
            pluginID: "codex", sessionID: conversation,
            notification: .init(title: "Question", body: "Which approach?", isQuestion: true), tmuxPane: "%1"
        ), peer: f.peer)
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running)
        #expect(waiting.invocations[0].status == (awaitingAcceptance ? .awaitingAcceptance : .writing))
        #expect(waiting.invocations[0].hasAskedQuestion == true)
        #expect(try await router.receive(submission("Use the simple approach."), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0] == waiting)
        #expect(verified.value == nil)

        readable.setValue(true)
        for _ in 0..<100 {
            if verified.value != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try #require(verified.value)
        #expect(context.candidate.kind == .submitted)
        #expect(context.candidate.text == f.invocation.delivery.input.text)
        #expect(context.invocation.id == f.invocation.id)
        let accepted = try await f.store.snapshot().runs[0]
        #expect(accepted.status == .running && accepted.invocations.count == 1)
        #expect(accepted.instances[0].conversationID == conversation)
        #expect(accepted.invocations[0].status == .running)
        #expect(accepted.invocations[0].nativeTurnID == "first-turn")
        #expect(accepted.invocations[0].nativeTranscriptPath == f.transcript.path)
        #expect(accepted.invocations[0].delivery == f.invocation.delivery)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["different-turn", "different-transcript", "different-conversation", "no-question", "no-receipt"])
    func unrelatedAnswerCannotUseAPendingReceipt(scenario: String) async throws {
        let f = try await fixture(conversation: "")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.store.update(runID: f.run.id) { try $0.didWrite(invocationID: f.invocation.id) }
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { _ in
            throw AgentWorkflowInspectionUnavailable()
        }, onVerified: { _ in Issue.record("An unverified receipt was accepted.") }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let conversation = UUID().uuidString
        if scenario != "no-receipt" {
            _ = try await router.receive(.init(
                pluginID: "codex", sessionID: conversation, tmuxPane: "%1", workflow: .init(
                    kind: .submitted, nativeTurnID: "first-turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
                )
            ), peer: f.peer)
        }
        if scenario != "no-question" {
            _ = try await router.receive(.init(
                pluginID: "codex", sessionID: conversation,
                notification: .init(title: "Question", body: "Which approach?", isQuestion: true), tmuxPane: "%1"
            ), peer: f.peer)
        }
        #expect(try await f.store.snapshot().runs[0].status == .running)
        #expect(try await router.receive(.init(
            pluginID: "codex", sessionID: scenario == "different-conversation" ? UUID().uuidString : conversation, tmuxPane: "%1", workflow: .init(
                kind: .submitted, nativeTurnID: scenario == "different-turn" ? "another-turn" : "first-turn",
                transcriptPath: scenario == "different-transcript" ? f.transcript.path + ".other" : f.transcript.path,
                text: "Use the simple approach."
            )
        ), peer: f.peer) == nil)
        let paused = try await f.store.snapshot().runs[0]
        #expect(paused.status == .running && paused.invocations.count == 1)
        #expect(paused.invocations[0].status == .awaitingAcceptance)
        #expect(paused.invocations[0].nativeTurnID == nil)
        #expect(paused.invocations[0].delivery == f.invocation.delivery)
        #expect(paused.instances[0].conversationID.isEmpty)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func laterConversationCannotReplaceAnAcceptedTask() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let event = PluginEvent(pluginID: "codex", sessionID: UUID().uuidString, tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "turn", transcriptPath: f.transcript.path, text: f.invocation.delivery.input.text
        ))
        #expect(try await f.router.receive(event, peer: f.peer) == nil)
        let saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == .paused)
        #expect(saved.instances[0].conversationID == f.instance.conversationID)
        #expect(saved.invocations[0].nativeTurnID == "turn")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"])
    func replayedTaskInANewTurnDoesNotClaimAnAcceptedReceipt(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let text = f.invocation.submissionText(pluginID: plugin)
        let original = f.event(.submitted, text: text, plugin: plugin)
        _ = try #require(await f.router.receive(original, peer: f.peer))
        let accepted = try await f.store.snapshot().runs[0]

        #expect(try await f.router.receive(original, peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0] == accepted)
        let replay = f.event(.submitted, text: text, turn: "human-replay", plugin: plugin)
        #expect(try await f.router.receive(replay, peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0] == accepted)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Human result", turn: "human-replay", plugin: plugin), peer: f.peer) == nil)

        let completion = try #require(await f.router.receive(f.event(.stopCandidate, text: "Workflow result", plugin: plugin), peer: f.peer))
        #expect(completion.invocation.id == f.invocation.id)
        #expect(completion.candidate.nativeTurnID == "turn")
        #expect(try await f.store.snapshot().runs[0] == accepted)
        let completed = try await f.store.update(runID: f.run.id) {
            try $0.succeed(.init(invocationID: f.invocation.id, nativeTurnID: "turn", text: "Workflow result", completedAt: Date()), instance: f.instance, now: Date())
        }
        #expect(completed.status == .completed)
        #expect(try await f.router.receive(original, peer: f.peer) == nil)
        #expect(try await f.router.receive(replay, peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0] == completed)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"])
    func duplicateReceiptStillValidatesItsTranscriptPath(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let text = f.invocation.submissionText(pluginID: plugin)
        _ = try #require(await f.router.receive(f.event(.submitted, text: text, plugin: plugin), peer: f.peer))
        let accepted = try await f.store.snapshot().runs[0]
        let changed = PluginEvent(pluginID: plugin, sessionID: "conversation", tmuxPane: "%1", workflow: .init(
            kind: .submitted, nativeTurnID: "turn", transcriptPath: f.transcript.path + ".other", text: text
        ))
        await #expect(throws: AgentWorkflowError.self) { try await f.router.receive(changed, peer: f.peer) }
        #expect(try await f.store.snapshot().runs[0] == accepted)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func authenticSubmissionPersistsNativeReceiptButStopAloneDoesNotComplete() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        #expect(submission?.candidate.kind == .submitted)
        let accepted = try await f.store.snapshot().runs[0].invocations[0]
        #expect(accepted.status == .running && accepted.nativeTurnID == "turn")
        #expect(accepted.nativeTranscriptPath == f.transcript.path)
        let candidate = try await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer)
        #expect(candidate?.invocation.id == f.invocation.id)
        let replay = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        #expect(replay?.candidate == candidate?.candidate)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        await f.runner.shutdown()
    }

    @Test
    func wrongProcessPluginAndTurnCannotAcceptOrFinish() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let other = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: other)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: "other"), peer: f.peer)
        #expect(try await f.store.snapshot().runs[0].invocations[0].status == .writing)
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: other) == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Final", plugin: "other"), peer: f.peer) == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Old", turn: "old"), peer: f.peer) == nil)
        #expect(try await f.store.snapshot().runs[0].invocations[0].result == nil)
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func acceptedNativeResultAfterRestartResolvesOnlyItsOriginalCall(fails: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        await f.runner.shutdown()
        let restarted = AgentWorkflowStore(fileURL: f.directory.appendingPathComponent("ledger.json"), hostID: f.instance.hostID)
        #expect(try await restarted.snapshot().runs[0].invocations[0].status == .uncertain)
        let runner = AgentWorkflowRunner(store: restarted, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("Restart recovery must not submit the task again.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: restarted, runner: runner, inspect: { $0 })
        #expect(try await router.receive(f.event(.stopCandidate, text: "Old", turn: "old"), peer: f.peer) == nil)
        let candidate = try #require(await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        #expect(try await restarted.snapshot().runs[0].invocations[0].result == nil)
        let content = fails ? "{\"failure\":\"Native failure\"}\n" : "{\"final\":\"Final\"}\n"
        try Data(content.utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: restarted, runner: runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await restarted.snapshot().runs[0].invocations[0].status != .uncertain {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await restarted.snapshot().runs[0]
        #expect(result.status == .paused)
        #expect(result.invocations.count == 1 && result.invocations[0].id == f.invocation.id)
        #expect(result.invocations[0].status == (fails ? .failed : .succeeded))
        #expect(result.invocations[0].result?.text == (fails ? nil : "Final"))
        #expect(try await router.receive(f.event(.stopCandidate, text: "Duplicate"), peer: f.peer) == nil)
        await monitor.shutdown()
        await runner.shutdown()
    }

    @Test
    func unacceptedWriteAfterRestartCannotBeCompletedByAStop() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.runner.shutdown()
        let restarted = AgentWorkflowStore(fileURL: f.directory.appendingPathComponent("ledger.json"), hostID: f.instance.hostID)
        let before = try await restarted.snapshot().runs[0]
        #expect(before.invocations[0].status == .uncertain && before.invocations[0].nativeTurnID == nil)
        let runner = AgentWorkflowRunner(store: restarted, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("An unaccepted write must not be resent.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: restarted, runner: runner, inspect: { $0 })
        #expect(try await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer) == nil)
        #expect(try await router.receive(f.event(.failed, text: "Failure"), peer: f.peer) == nil)
        #expect(try await restarted.snapshot().runs[0] == before)
        await runner.shutdown()
    }

    @Test
    func humanSubmissionDoesNotPauseAndNativeFailureDoesNotBecomeAResult() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await f.router.receive(f.event(.submitted, text: "Human task", turn: "human"), peer: f.peer)
        #expect(try await f.store.snapshot().runs[0].status == .running)
        _ = try await f.router.receive(f.event(.failed, text: "Rate limited"), peer: f.peer)
        let invocation = try await f.store.snapshot().runs[0].invocations[0]
        #expect(invocation.status == .failed && invocation.result == nil)
        await f.runner.shutdown()
    }

    @Test
    func rejectedSubmissionPausesWithoutReceivingAStop() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = try #require(await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer))
        try Data("{\"failure\":\"Rejected by hook\"}\n".utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(submission, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .paused && run.issue == "Rejected by hook")
        #expect(run.invocations.count == 1 && run.invocations[0].status == .failed)
        #expect(run.invocations[0].result == nil)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func submissionWaitsForTheFirstNativeTranscriptToBeCreated() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.removeItem(at: f.transcript)
        let submission = try #require(await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(submission, provider: NativeWorkflowTestProvider())
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await f.store.snapshot().runs[0].status == .running)
        try Data("{\"failure\":\"Rejected first task\"}\n".utf8).write(to: f.transcript)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .paused && run.issue == "Rejected first task")
        #expect(run.invocations[0].status == .failed && run.invocations[0].result == nil)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func submissionWatchCannotAcceptSuccessWithoutAStopCandidate() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = try #require(await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer))
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        let observed = LockIsolated(0)
        let provider = NativeWorkflowTestProvider { observed.withValue { $0 += 1 } }
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(submission, provider: provider)
        for _ in 0..<200 {
            if observed.value > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.value == 1)
        let pending = try await f.store.snapshot().runs[0]
        #expect(pending.status == .running && pending.invocations[0].result == nil)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        await monitor.verify(stop, provider: provider)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].result?.text == "Final")
        #expect(observed.value == 1) // Stop reuses evidence, without parsing again.
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func completionWaitsForDurableRecordAndAcceptsOnlyOneResult() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let candidate = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider())
        #expect(try await f.store.snapshot().runs[0].status == .running)
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .completed && run.invocations[0].result?.text == "Final")
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer) == nil)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func lateSubmissionMonitorCannotReplaceFinalVerification() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = try #require(await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer))
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        await monitor.verify(submission, provider: NativeWorkflowTestProvider())
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].result?.text == "Final")
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    private func startAnotherRun(_ f: Fixture) async throws -> AgentWorkflowRun {
        let run = try await f.store.start(
            definitionID: f.run.definition.id, expectedRevision: f.run.definition.revision, requestID: UUID(),
            now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600)
        )
        return try await f.store.update(runID: run.id) {
            let invocation = try $0.prepareInvocation(nodeID: run.definition.entryNodeID, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: f.instance, now: Date())
            try $0.didWrite(invocationID: invocation.id)
        }
    }

    @Test
    func lateFirstReceiptCannotBecomeAnotherRunsContinuation() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.store.update(runID: f.run.id) { $0.end() }
        let current = try await startAnotherRun(f)
        let currentCall = try #require(current.invocations.first)
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        })
        _ = try await router.receive(f.event(.submitted, text: currentCall.delivery.input.text, turn: "current"), peer: f.peer)
        available.setValue(true)
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, turn: "old"), peer: f.peer)
        for _ in 0..<100 {
            if try await f.store.snapshot().runs.allSatisfy({ $0.invocations[0].nativeTurnID != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let archive = try await f.store.snapshot()
        #expect(archive.runs.first(where: { $0.id == f.run.id })?.invocations[0].nativeTurnID == "old")
        #expect(archive.runs.first(where: { $0.id == current.id })?.invocations[0].stepTurn?.id == "current")
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func archivedContinuationCannotSelectTurnInNewRun(unconfirmed: Bool, intermediate: Bool) async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try f.writeCodexTurns("turn", "middle")
        let middle = f.event(.submitted, text: "Intermediate continuation", turn: "middle")
        _ = try await f.router.receive(middle, peer: f.peer)
        try f.appendNativeTurn("old-followup")
        let old = f.event(.submitted, text: "Historical continuation", turn: "old-followup")
        _ = try await f.router.receive(old, peer: f.peer)
        let ended = try await f.store.update(runID: f.run.id) { $0.end() }
        #expect(ended.invocations[0].stepTurn?.id == "old-followup")
        let next = try await startAnotherRun(f)
        let task = try #require(next.invocations.first)
        try f.writeCodexTurns("turn", "middle", "old-followup", "current")
        _ = try await f.router.receive(f.event(.submitted, text: task.delivery.input.text, turn: "current"), peer: f.peer)
        let replay = intermediate ? middle : old
        if unconfirmed {
            try await f.router.receiveUnconfirmedSubmission(replay, peer: f.peer)
        } else {
            _ = try await f.router.receive(replay, peer: f.peer)
        }
        try await f.router.requireVerifiedSubmission(task.id)
        let saved = try #require(await f.store.snapshot().runs.first(where: { $0.id == next.id }))
        #expect(saved.invocations[0].stepTurn?.id == "current")
        _ = try await f.router.receive(f.event(.submitted, text: "New continuation", turn: "new-followup"), peer: f.peer)
        #expect(try await f.store.snapshot().runs.last?.invocations[0].stepTurn?.id == "current")
        try f.writeCodexTurns("turn", "middle", "old-followup", "current", "new-followup")
        try await f.router.requireVerifiedSubmission(task.id)
        #expect(try await f.store.snapshot().runs.last?.invocations[0].stepTurn?.id == "new-followup")
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func stableTranscriptRejectsAnEqualLengthRewriteDuringParsing() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data("{\"final\":\"First\"}\n".utf8).write(to: f.transcript)
        let changed = LockIsolated(false)
        let parser = NativeWorkflowTestParser(onOutcome: {
            do {
                let handle = try FileHandle(forWritingTo: f.transcript)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data("{\"final\":\"Other\"}\n".utf8))
                changed.setValue(true)
            } catch {
                Issue.record(Comment(rawValue: error.localizedDescription))
            }
        })
        let file = try AgentWorkflowTranscriptFile(path: f.transcript.path, parser: parser)
        #expect(try await file.verifiedOutcome(at: f.transcript.path, hasStop: true) == nil)
        #expect(changed.value)
        let newFile = try AgentWorkflowTranscriptFile(path: f.transcript.path, parser: NativeWorkflowTestParser())
        let reread = try #require(await newFile.verifiedOutcome(at: f.transcript.path, hasStop: true))
        #expect(reread.0 == .succeeded("Other"))
    }

    @Test
    func resubmittingOriginalTextSelectsTheNewExplicitTurn() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let prompt = f.invocation.delivery.input.text
        _ = try await f.router.receive(f.event(.submitted, text: prompt), peer: f.peer)
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Proposal"), peer: f.peer)
        try f.writeCodexTurns("turn", "retry")
        _ = try await f.router.receive(f.event(.submitted, text: prompt, turn: "retry"), peer: f.peer)
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: {
            try await f.router.requireVerifiedSubmission($0)
        })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).ok)
        let invocation = try #require(await f.store.snapshot().runs.first?.invocations.first)
        #expect(invocation.nativeTurnID == "turn")
        #expect(invocation.stepTurn?.id == "retry" && invocation.stepTurn?.completionRequested == true)
        await f.router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], [false, true])
    func endedExplicitRunCannotConsumeNewRunsReceipt(plugin: String, receiptPending: Bool) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(!receiptPending)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        })
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        try await f.store.update(runID: f.run.id) { $0.end() }
        let next = try await startAnotherRun(f)
        let task = try #require(next.invocations.first)
        #expect(task.status == .awaitingAcceptance)
        _ = try await router.receive(f.event(.submitted, text: task.delivery.input.text, turn: "new-run", plugin: plugin), peer: f.peer)
        available.setValue(true)
        if receiptPending {
            for _ in 0..<100 {
                if try await f.store.snapshot().runs.allSatisfy({ $0.invocations[0].nativeTurnID != nil }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let saved = try await f.store.snapshot().runs
        let old = try #require(saved.first(where: { $0.id == f.run.id }))
        let current = try #require(saved.first(where: { $0.id == next.id }))
        #expect(old.status == .ended && old.invocations[0].nativeTurnID == "turn")
        #expect(old.invocations[0].stepTurn?.id == "turn")
        #expect(current.invocations[0].status == .running)
        #expect(current.invocations[0].nativeTurnID == "new-run")
        #expect(current.invocations[0].stepTurn?.id == "new-run")
        #expect(saved.allSatisfy { $0.invocations.count == 1 && $0.invocations[0].result == nil })
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"])
    func currentPendingReceiptDoesNotSwallowEndedRunsLateStop(plugin: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        try await f.store.update(runID: f.run.id) {
            try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            $0.end()
        }
        let next = try await startAnotherRun(f)
        let task = try #require(next.invocations.first)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { _ in
            throw AgentWorkflowInspectionUnavailable()
        })
        _ = try await router.receive(f.event(.submitted, text: task.delivery.input.text, turn: "new-run", plugin: plugin), peer: f.peer)
        let late = try await router.receive(f.event(.stopCandidate, text: "Late result", plugin: plugin), peer: f.peer)
        #expect(late?.runID == f.run.id && late?.invocation.id == f.invocation.id)
        #expect(late?.candidate.nativeTurnID == "turn")
        let current = try #require(await f.store.snapshot().runs.first(where: { $0.id == next.id }))
        #expect(current.invocations[0].nativeTurnID == nil && current.invocations[0].result == nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["codex", "claude-code"], [AgentWorkflowNode.Completion.replyEnded, .explicit])
    func endedRunStillVerifiesLateAnswerWithoutRestarting(plugin: String, completion: AgentWorkflowNode.Completion) async throws {
        let f = try await fixture(plugin: plugin, completion: completion)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        try await f.store.update(runID: f.run.id) {
            if completion == .explicit {
                try $0.requestStepCompletion(invocationID: f.invocation.id, instance: f.instance, turnID: "turn", now: Date())
            }
            $0.end()
        }
        let next = try await startAnotherRun(f)
        let task = try #require(next.invocations.first)
        _ = try await f.router.receive(f.event(.submitted, text: task.delivery.input.text, turn: "new-run", plugin: plugin), peer: f.peer)
        // Exact old receipts and results can still be archived after End.
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        let candidate = try #require(await f.router.receive(f.event(.stopCandidate, text: "Late answer", plugin: plugin), peer: f.peer))
        #expect(candidate.runID == f.run.id)
        try Data("{\"final\":\"Late answer\"}\n".utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try await f.store.snapshot().runs
        let run = try #require(saved.first(where: { $0.id == f.run.id }))
        let current = try #require(saved.first(where: { $0.id == next.id }))
        #expect(run.status == .ended)
        #expect(run.invocations.count == 1 && run.invocations[0].status == .succeeded)
        #expect(run.invocations[0].result?.text == "Late answer")
        #expect(current.status == .running && current.invocations[0].status == .running)
        #expect(current.invocations[0].nativeTurnID == "new-run" && current.invocations[0].result == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Late answer", plugin: plugin), peer: f.peer) == nil)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func authenticatedStopSurvivesTemporaryInspectionFailure() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: { _ in
            throw AgentWorkflowInspectionUnavailable()
        })
        let candidate = try #require(await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        let available = LockIsolated(false)
        let parsed = LockIsolated(false)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider { parsed.setValue(true) })
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].issue != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running && waiting.invocations[0].result == nil)
        #expect(!parsed.value)
        available.setValue(true)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolved = try await f.store.snapshot().runs[0]
        #expect(resolved.status == .completed)
        #expect(resolved.invocations.count == 1 && resolved.invocations[0].id == f.invocation.id)
        #expect(resolved.invocations[0].result?.text == "Final")
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func temporaryInspectionRetainsSubmissionAndEarlyStop(stopBeforeRecovery: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(false)
        let contexts = LockIsolated<[AgentWorkflowTurnContext]>([])
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        }, onVerified: { context in
            contexts.withValue { $0.append(context) }
            await monitor.verify(context, provider: NativeWorkflowTestProvider())
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        #expect(try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer) == nil)
        #expect(try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer) == nil)
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .running)
        #expect(waiting.invocations[0].status == .writing && waiting.invocations[0].nativeTurnID == nil)
        if stopBeforeRecovery {
            #expect(try await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer) == nil)
        }
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        available.setValue(true)
        for _ in 0..<200 {
            if !contexts.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(contexts.value.count == 1)
        #expect(contexts.value.first?.candidate.kind == (stopBeforeRecovery ? .stopCandidate : .submitted))
        #expect(try await f.store.snapshot().runs[0].invocations[0].nativeTurnID == "turn")
        if !stopBeforeRecovery {
            let stop = try #require(await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
            await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        }
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await f.store.snapshot().runs[0]
        #expect(completed.status == .completed && completed.invocations.count == 1)
        #expect(completed.invocations[0].result?.text == "Final")
        await router.shutdown()
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: ["replaced", "timeout", "shutdown"])
    func unverifiedSubmissionNeverLinksToAnotherAgentOrOutlivesRetry(action: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let recovered = LockIsolated(false)
        let inspected = LockIsolated(0)
        let failures = LockIsolated(0)
        let router = AgentWorkflowEventRouter(
            store: f.store,
            runner: f.runner,
            inspect: {
                inspected.withValue { $0 += 1 }
                guard recovered.value else { throw AgentWorkflowInspectionUnavailable() }
                var live = $0
                live.conversationID = "replacement"
                return live
            },
            verificationTimeout: action == "timeout" ? .milliseconds(50) : .seconds(60),
            onVerified: { _ in Issue.record("An unverified receipt was accepted") },
            onFailure: { _ in failures.withValue { $0 += 1 } }
        )
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        #expect(try await router.suppressesAgentCompletion(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        #expect(try await !router.suppressesAgentCompletion(f.event(.stopCandidate, text: "Manual", turn: "other"), peer: f.peer))
        _ = try await router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer)
        if action == "shutdown" {
            await router.shutdown()
        }
        if action == "replaced" {
            recovered.setValue(true)
        }
        try await Task.sleep(for: .milliseconds(350))
        let count = inspected.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(inspected.value == count)
        #expect(failures.value == (action == "shutdown" ? 0 : 1))
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == (action == "shutdown" ? .running : .paused) && run.invocations[0].nativeTurnID == nil && run.invocations[0].result == nil)
        await router.shutdown()
        await f.runner.shutdown()
    }

    @Test(arguments: [false, true])
    func stopCannotArchiveWithUnavailableOrReplacedIdentity(replaced: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let candidate = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        let inspections = LockIsolated(0)
        let parsed = LockIsolated(false)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            inspections.withValue { $0 += 1 }
            guard replaced else { throw AgentWorkflowInspectionUnavailable() }
            var changed = $0
            changed.conversationID = "replacement-conversation"
            return changed
        }, verificationTimeout: .milliseconds(50), onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider { parsed.setValue(true) })
        try await Task.sleep(for: .milliseconds(350))
        let stoppedAt = inspections.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(inspections.value == stoppedAt)
        #expect(stoppedAt > 0 && stoppedAt <= 2)
        if replaced {
            #expect(stoppedAt == 1)
        }
        #expect(!parsed.value)
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .paused && run.invocations[0].result == nil)
        #expect(run.invocations[0].status == .running)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func catchUpDoesNotSpendFinalWaitBudgetOrInspectEveryChunk() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        let old = try JSONSerialization.data(withJSONObject: ["old": String(repeating: "x", count: 500_000)]) + Data([10])
        let writer = try FileHandle(forWritingTo: f.transcript)
        for _ in 0..<10 {
            try writer.write(contentsOf: old)
        }
        try writer.write(contentsOf: Data("{\"final\":\"Final\"}\n".utf8))
        try writer.close()
        let inspected = LockIsolated(0)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            inspected.withValue { $0 += 1 }
            try await Task.sleep(for: .milliseconds(20))
            return $0
        }, verificationTimeout: .milliseconds(10), onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        for _ in 0..<500 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await f.store.snapshot().runs[0].invocations[0].result?.text == "Final")
        #expect(inspected.value == 2) // Initial check and the final commit boundary.
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func finalIdentityCheckRetriesAlreadyConsumedEvidence() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        try Data("{\"final\":\"Final\"}\n".utf8).write(to: f.transcript)
        let inspected = LockIsolated(0)
        let parsed = LockIsolated(0)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            let count = inspected.withValue { $0 += 1
                return $0
            }
            if count == 2 {
                throw AgentWorkflowInspectionUnavailable()
            }
            return $0
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider { parsed.withValue { $0 += 1 } })
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .completed && run.invocations[0].result?.text == "Final")
        #expect(parsed.value == 1)
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func missingFinalRecordStillTimesOutAfterCatchUp() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        let stop = try #require(await f.router.receive(f.event(.stopCandidate, text: "Final"), peer: f.peer))
        let monitor = AgentWorkflowCompletionMonitor(
            store: f.store,
            runner: f.runner,
            inspect: { $0 },
            verificationTimeout: .milliseconds(30),
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .paused && run.invocations[0].result == nil)
        #expect(run.issue == "The Agent's final completion could not be verified. Nothing was handed downstream.")
        await monitor.shutdown()
        await f.runner.shutdown()
    }

    @Test
    func readerPreservesRecordsAfterAnOutcomeInTheSameChunk() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data("{\"final\":\"First\"}\n{\"failure\":\"Later\"}\n".utf8).write(to: f.transcript)
        let reader = try AgentWorkflowTranscriptFile(path: f.transcript.path, parser: NativeWorkflowTestParser())
        #expect(try await reader.poll().outcome == .succeeded("First"))
        #expect(try await reader.poll().outcome == .failed("Later"))
        #expect(try await reader.poll().reachedEnd)
        await f.runner.shutdown()
    }

    @Test
    func incrementalReaderWaitsForNewlineAndRejectsTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-jsonl-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.jsonl")
        try Data("{\"final\":\"Final\"}".utf8).write(to: path)
        let reader = try AgentWorkflowTranscriptFile(path: path.path, parser: NativeWorkflowTestParser())
        #expect(try await reader.poll().outcome == nil)
        let append = try FileHandle(forWritingTo: path)
        try append.seekToEnd()
        try append.write(contentsOf: Data([10]))
        try append.close()
        #expect(try await reader.poll().outcome == .succeeded("Final"))
        let writer = try FileHandle(forWritingTo: path)
        try writer.truncate(atOffset: 0)
        try writer.close()
        await #expect(throws: AgentWorkflowError.self) { try await reader.poll() }
    }
}
