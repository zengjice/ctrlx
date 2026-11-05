import ConcurrencyExtras
import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
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

    private func fixture(conversation: String = "conversation", imageCount: Int = 0, plugin: String = "codex") async throws -> Fixture {
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
            capabilities: .init(maximumInputBytes: 10_000), readiness: .ready
        )]).first)
        var imageIDs: [UUID] = []
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=")!
        for _ in 0..<imageCount {
            let id = UUID(), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            _ = try await store.uploadAttachment(.image(id: id, name: "task.png", mediaType: "image/png", data: bytes, sha256: hash))
            imageIDs.append(id)
        }
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
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
        let identities = AgentSessionIdentityClient(load: { _ in nil }, recoverySource: { _, _, _ in nil }, save: { _ in false }, runtimeID: { _ in f.instance.processRuntimeID }, codexOwnsSession: { _, _, id in
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
        #expect(run.status == .paused && run.invocations[0].result?.text == "Final")
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
