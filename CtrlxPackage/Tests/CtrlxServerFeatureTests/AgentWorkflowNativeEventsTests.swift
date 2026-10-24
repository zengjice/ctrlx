import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

private struct NativeWorkflowTestParser: AgentWorkflowTranscriptParser {
    var onOutcome: @Sendable () -> Void = { }
    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        let value = try JSONDecoder().decode([String: String].self, from: line)
        let result = value["failure"].map { AgentWorkflowTranscriptOutcome.failed($0) }
            ?? value["final"].map { .succeeded($0) }
        if result != nil {
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

struct AgentWorkflowNativeEventsTests {
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

        func event(_ kind: PluginWorkflowEvent.Kind, text: String, turn: String = "turn", plugin: String = "codex") -> PluginEvent {
            .init(pluginID: plugin, sessionID: "conversation", tmuxPane: "%1", workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: transcript.path, text: text
            ))
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-events-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("native.jsonl")
        try Data().write(to: transcript)
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: directory.appendingPathComponent("ledger.json"), hostID: hostID)
        let instance = try #require(await store.reconcile([.init(
            pluginID: "codex", processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Developer", workingDirectory: directory.path,
            capabilities: .init(maximumInputBytes: 10_000), readiness: .ready
        )]).first)
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = try await store.saveDefinition(.init(name: "Test", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        let written = try await store.update(runID: run.id) {
            let invocation = try $0.prepareInvocation(nodeID: node.id, now: Date())
            try $0.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
        }
        let invocation = try #require(written.invocations.first)
        let runner = AgentWorkflowRunner(store: store, transport: .init(inspect: { $0 }, prepare: { _, _ in }, write: { _, _ in
            Issue.record("The fixture already wrote its task; it must not be submitted again.")
        }), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { $0 })
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
        #expect(try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer) == nil)
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
    func humanSubmissionPausesAndNativeFailureDoesNotBecomeAResult() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        _ = try await f.router.receive(f.event(.submitted, text: "Human task", turn: "human"), peer: f.peer)
        #expect(try await f.store.snapshot().runs[0].status == .paused)
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
        let observed = LockIsolated(false)
        let provider = NativeWorkflowTestProvider { observed.setValue(true) }
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(submission, provider: provider)
        for _ in 0..<200 {
            if observed.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.value)
        await monitor.shutdown()
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

    @Test
    func endedRunStillVerifiesLateAnswerWithoutRestarting() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text), peer: f.peer)
        try await f.store.update(runID: f.run.id) { $0.end() }
        let candidate = try #require(await f.router.receive(f.event(.stopCandidate, text: "Late answer"), peer: f.peer))
        try Data("{\"final\":\"Late answer\"}\n".utf8).write(to: f.transcript)
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: { $0 }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(candidate, provider: NativeWorkflowTestProvider())
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try await f.store.snapshot().runs[0]
        #expect(run.status == .ended)
        #expect(run.invocations.count == 1 && run.invocations[0].status == .succeeded)
        #expect(run.invocations[0].result?.text == "Late answer")
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Late answer"), peer: f.peer) == nil)
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
            if try await f.store.snapshot().runs[0].status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try await f.store.snapshot().runs[0]
        #expect(waiting.status == .paused && waiting.invocations[0].result == nil)
        #expect(!parsed.value)
        available.setValue(true)
        for _ in 0..<200 {
            if try await f.store.snapshot().runs[0].invocations[0].result != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolved = try await f.store.snapshot().runs[0]
        #expect(resolved.status == .paused)
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
        #expect(waiting.status == .paused)
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
        #expect(completed.status == .paused && completed.invocations.count == 1)
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
        #expect(run.status == .paused && run.invocations[0].nativeTurnID == nil && run.invocations[0].result == nil)
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
