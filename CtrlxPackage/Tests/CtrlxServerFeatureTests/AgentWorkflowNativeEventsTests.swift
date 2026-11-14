import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

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

struct AgentWorkflowNativeEventsTests {
    @Test(arguments: ["codex", "claude-code"], [false, true])
    func restartedTabCanCompleteItsExplicitStep(plugin: String, newConversation: Bool) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit, allowsFinish: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
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
        let submitted = PluginEvent(pluginID: plugin, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .submitted, nativeTurnID: "after-login", transcriptPath: f.transcript.path, text: prompt
        ))
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

        try Data("{\"final\":\"Finished after login\"}\n".utf8).write(to: f.transcript)
        let stop = PluginEvent(pluginID: plugin, sessionID: live.conversationID, tmuxPane: live.paneID, workflow: .init(
            kind: .stopCandidate, nativeTurnID: "after-login", transcriptPath: f.transcript.path, text: "Finished after login"
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

    @Test(arguments: ["submission", "stop", "inspection"])
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
        if stage != "stop" {
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
                try Data("{\"final\":\"Finished\"}\n".utf8).write(to: f.transcript)
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
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Finished"), peer: peer) == nil)
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
        let monitor = AgentWorkflowCompletionMonitor(store: f.store, runner: f.runner, inspect: {
            Issue.record("Another conversation must not verify the old result.")
            return $0
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        await monitor.verify(stop, provider: NativeWorkflowTestProvider())
        try await Task.sleep(for: .milliseconds(100))
        await monitor.shutdown()
        await f.router.shutdown()
        await f.runner.shutdown()
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

        func event(_ kind: PluginWorkflowEvent.Kind, text: String, turn: String = "turn", plugin: String = "codex") -> PluginEvent {
            .init(pluginID: plugin, sessionID: "conversation", tmuxPane: "%1", workflow: .init(
                kind: kind, nativeTurnID: turn, transcriptPath: transcript.path, text: text
            ))
        }
    }

    private func fixture(conversation: String = "conversation", imageCount: Int = 0, plugin: String = "codex", completion: AgentWorkflowNode.Completion = .replyEnded, allowsFinish: Bool = false) async throws -> Fixture {
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
        let definition = try await store.saveDefinition(.init(name: "Test", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(attachmentIDs: imageIDs)), expectedRevision: nil)
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
        }, verificationTimeout: state == "timeout" ? .milliseconds(250) : .seconds(5), onFailure: { _ in timedOut.setValue(true) })
        _ = try await router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer)
        available.setValue(false)
        _ = try await router.receive(f.event(.submitted, text: "Implement", turn: "B", plugin: plugin), peer: f.peer)
        if state == "stopped" {
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

    @Test
    func laterDiscussionReceiptSurvivesInitialReceiptVerification() async throws {
        let f = try await fixture(completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let available = LockIsolated(false)
        let router = AgentWorkflowEventRouter(store: f.store, runner: f.runner, inspect: {
            guard available.value else { throw AgentWorkflowInspectionUnavailable() }
            return $0
        })
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

    @Test(arguments: ["codex", "claude-code"])
    func proposalAndHumanDiscussionWaitUntilAnExplicitlyCompletedTurn(plugin: String) async throws {
        let f = try await fixture(plugin: plugin, completion: .explicit)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 }, synchronizeEvents: { _ in })
        let request = JSONRPCRequest(id: "complete", method: "workflow.completeStep", params: ["invocationId": .string(f.invocation.id.uuidString)])
        #expect(await service.handle(request, peer: f.peer).error != nil)
        #expect(try await f.router.receive(f.event(.submitted, text: f.invocation.delivery.input.text, plugin: plugin), peer: f.peer) == nil)
        #expect(try await f.router.receive(f.event(.stopCandidate, text: "Please confirm the design", plugin: plugin), peer: f.peer) == nil)
        var saved = try await f.store.snapshot().runs[0]
        #expect(saved.status == .running && saved.invocations[0].result == nil)
        #expect(AgentWorkflowInvocationSummary(saved.invocations[0]).awaitingStepCompletion)
        #expect(try AgentWorkflowExecution(validating: saved).readyNodeIDs.isEmpty)
        let restored = try AgentWorkflowExecution(restoring: saved)
        #expect(restored.run.invocations[0].status == .running)
        #expect(await service.handle(request, peer: f.peer).error != nil) // A stopped proposal is not a current tool turn.

        _ = try await f.router.receive(f.event(.submitted, text: "Answer to the question", plugin: plugin), peer: f.peer)
        let continued = try await f.store.snapshot().runs[0].invocations[0]
        #expect(continued.stepTurn?.stopped == false && continued.stepTurn?.prompt == f.invocation.delivery.input.text)
        _ = try await f.router.receive(f.event(.submitted, text: "Discuss an alternative", turn: "discussion", plugin: plugin), peer: f.peer)
        _ = try await f.router.receive(f.event(.stopCandidate, text: "Alternative proposal", turn: "discussion", plugin: plugin), peer: f.peer)
        _ = try await f.router.receive(f.event(.submitted, text: "Implement the agreed design", turn: "implementation", plugin: plugin), peer: f.peer)
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
