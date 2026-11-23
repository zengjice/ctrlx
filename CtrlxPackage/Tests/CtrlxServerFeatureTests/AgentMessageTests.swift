import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentMessageTests {
    @Test(arguments: ["tmux", "ps"])
    func productionSnapshotFailureRetriesUntilCommandsRecover(command: String) async throws {
        let unavailable = LockIsolated(true)
        let failedCommands = LockIsolated(0)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                let source: String
                let output: String
                if executable == "/bin/ps" {
                    source = "ps"
                    output = "100 1 zsh\n"
                } else if arguments.contains("list-panes") {
                    source = "tmux"
                    let separator = String(PaneInfo.fieldSeparator)
                    output = "%1\(separator)100\(separator)/fixture\n"
                } else {
                    Issue.record("Unexpected process invocation: \(executable)")
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
                }
                if source == command, unavailable.value {
                    failedCommands.withValue { $0 += 1 }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("snapshot unavailable".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            }
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.pluginRegistry = PluginRegistry()
            #expect(coordinator.pluginRegistry?.processNamesByPlugin["codex"] == ["codex"])
            let f = try await AgentInteractionTestSupport()
            let message = try await savedReply(f)
            let hostID = f.hostID
            await #expect(throws: AgentWorkflowInspectionUnavailable.self) {
                try await coordinator.scanWorkflowInstances(previous: [], hostID: hostID)
            }
            // Probe through the production command/scan path before returning
            // the fixture's native conversation and persisted reply evidence.
            f.beforeScan = {
                _ = try await coordinator.scanWorkflowInstances(previous: [], hostID: hostID)
            }
            let scans = f.scanCount
            try await f.restartInteraction()
            for _ in 0..<100 where f.scanCount == scans {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(try await f.interaction.store.message(message.id)?.status == .running)
            #expect(await f.interaction.observationCounts().transcripts == 1)
            #expect(failedCommands.value >= 2)
            unavailable.setValue(false)
            try await waitForStatus(.succeeded, message.id, in: f)
            #expect(f.scanCount >= scans + 2)
            #expect(try await f.interaction.store.message(message.id)?.answer == "saved reply")
            #expect(try await coordinator.scanWorkflowInstances(previous: [], hostID: hostID).isEmpty)
            #expect(f.writes.isEmpty)
            try await f.cleanup()
        }
    }

    @Test(arguments: [false, true])
    func temporaryCatalogFailureRetriesWithoutPanelOrHook(warmCatalog: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f)
        f.beforeScan = { throw AgentWorkflowInspectionUnavailable() }
        let scans = f.scanCount
        if warmCatalog {
            try await f.interaction.resumePendingReplies()
        } else {
            try await f.restartInteraction()
        }
        for _ in 0..<100 where f.scanCount == scans {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await f.interaction.store.message(message.id)?.status == .running)
        #expect(await f.interaction.observationCounts().transcripts == 1)
        #expect(try await f.interaction.store.message(message.id)?.answer == nil)
        f.beforeScan = nil
        try await waitForStatus(.succeeded, message.id, in: f)
        #expect(f.scanCount >= scans + 2)
        #expect(try await f.interaction.store.message(message.id)?.answer == "saved reply")
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func catalogFailureStopsAtBudgetOrFailsImmediatelyWhenNotTemporary(temporary: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f)
        f.beforeScan = {
            if temporary {
                throw AgentWorkflowInspectionUnavailable()
            }
            throw AgentWorkflowError("Invalid catalog identity")
        }
        let scans = f.scanCount
        try await f.restartInteraction(verificationTimeout: .milliseconds(250))
        try await waitForStatus(.uncertain, message.id, in: f)
        let stoppedAt = f.scanCount
        #expect(temporary ? stoppedAt >= scans + 2 : stoppedAt == scans + 1)
        #expect(try await f.interaction.store.message(message.id)?.answer == nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.scanCount == stoppedAt)
        // Recovery remains available after the bounded retry has ended.
        f.beforeScan = nil
        _ = await f.orbie()
        try await waitForStatus(.succeeded, message.id, in: f)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test(arguments: [AgentWorkflowInvocationStatus.running, .uncertain])
    func restartVerifiesSavedReplyWithoutPanelOrWorkflow(status: AgentWorkflowInvocationStatus) async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f, status: status)
        let scans = f.scanCount
        try await f.restartInteraction()
        try await waitForStatus(.succeeded, message.id, in: f)
        #expect(f.scanCount == scans + 1)
        #expect(try await f.interaction.store.message(message.id)?.answer == "saved reply")
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func pendingReplyRefreshesRuntimeAgainWithoutPanel() async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f)
        let observations = f.observations
        let scans = f.scanCount
        f.observations = []
        try await f.restartInteraction()
        for _ in 0..<100 where f.scanCount == scans {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.scanCount == scans + 1)
        f.observations = observations
        try await waitForStatus(.succeeded, message.id, in: f)
        #expect(f.scanCount == scans + 2)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func refreshRechecksSavedReplyAfterRuntimeTimeout() async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f)
        let observations = f.observations
        f.observations = []
        try await f.restartInteraction(verificationTimeout: .milliseconds(50))
        try await waitForStatus(.uncertain, message.id, in: f)
        #expect(await f.interaction.observationCounts().transcripts == 0)
        f.observations = observations
        // The role's ordinary refresh must restart verification, not sending.
        _ = await f.orbie()
        try await waitForStatus(.succeeded, message.id, in: f)
        #expect(try await f.interaction.availability(message.agentID) == nil)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func nativeFailureRequiresVerifiedIdentityAndTurnThenAllowsNextMessage() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "claude-code", providerID: nil)
        main.draft = "First message"
        await main.send()
        let message = try #require(main.messages.last)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let wrongPeer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0)
        })
        let turn = "accepted-turn"
        let path = f.root.appendingPathComponent("empty-transcript.jsonl").path
        try Data().write(to: URL(fileURLWithPath: path))
        let receipt = PluginEvent(
            pluginID: "claude-code",
            sessionID: message.instance.conversationID,
            tmuxPane: message.instance.paneID,
            workflow: .init(kind: .submitted, nativeTurnID: turn, transcriptPath: path, text: message.prompt)
        )
        try await f.interaction.receive(receipt, peer: peer)
        try await waitForStatus(.running, message.id, in: f)
        let failure = PluginEvent(
            pluginID: "claude-code",
            sessionID: message.instance.conversationID,
            tmuxPane: message.instance.paneID,
            workflow: .init(kind: .failed, nativeTurnID: turn, transcriptPath: path, text: "Native API request failed")
        )
        try await f.interaction.receive(failure, peer: wrongPeer)
        for (session, turnID, transcript) in [("other", turn, path), (message.instance.conversationID, "other", path), (message.instance.conversationID, turn, path + ".other")] {
            try await f.interaction.receive(.init(
                pluginID: "claude-code",
                sessionID: session,
                tmuxPane: message.instance.paneID,
                workflow: .init(kind: .failed, nativeTurnID: turnID, transcriptPath: transcript, text: "Unrelated failure")
            ), peer: peer)
        }
        #expect(try await f.interaction.store.message(message.id)?.status == .running)
        try await f.interaction.receive(failure, peer: peer)
        try await waitForStatus(.failed, message.id, in: f)
        let failed = try #require(try await f.interaction.store.message(message.id))
        #expect(failed.issue == "Native API request failed" && failed.completedAt != nil)
        #expect(await f.interaction.observationCounts().transcripts == 0)
        await main.refresh()
        #expect(main.availability == nil)
        main.draft = "Next message"
        await main.send()
        try await f.complete(#require(main.messages.last))
        #expect(f.writes.count == 2)
        try await f.cleanup()
    }

    @Test
    func restartRetainsSavedNativeFailureWithoutTranscript() async throws {
        let f = try await AgentInteractionTestSupport()
        let message = try await savedReply(f)
        try await f.interaction.store.update(message.id) {
            $0.nativeEvent = .init(kind: .failed, nativeTurnID: "turn", transcriptPath: "/missing", text: "Saved native failure")
        }
        try await f.restartInteraction()
        let failed = try #require(try await f.interaction.store.message(message.id))
        #expect(failed.status == .failed && failed.issue == "Saved native failure")
        #expect(failed.needsFailureActivity == true)
        #expect(await f.interaction.observationCounts().transcripts == 0)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    private func savedReply(_ f: AgentInteractionTestSupport, status: AgentWorkflowInvocationStatus = .running) async throws -> AgentMessage {
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        var message = try AgentMessage(instance: #require(main.instance), text: "Saved prompt")
        let file = f.root.appendingPathComponent("saved.jsonl")
        try (JSONEncoder().encode(["turn": "turn", "final": "saved reply"]) + Data([10])).write(to: file)
        message.status = status
        message.nativeEvent = .init(kind: .stopCandidate, nativeTurnID: "turn", transcriptPath: file.path, text: "saved reply")
        try await f.interaction.store.importMessage(message)
        return message
    }

    private func waitForStatus(_ status: AgentWorkflowInvocationStatus, _ id: UUID, in f: AgentInteractionTestSupport) async throws {
        for _ in 0..<1_500 {
            let counts = await f.interaction.observationCounts()
            if try await f.interaction.store.message(id)?.status == status, counts.receipts == 0, status == .running || counts.transcripts == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Message did not reach \(status)")
    }

    @Test
    func duplicateMessageCannotWriteAgainEvenAfterCompletion() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        main.draft = "One delivery"
        await main.send()
        let message = try #require(main.messages.last)
        await #expect(throws: AgentWorkflowError.self) { try await f.interaction.send(message) }
        try await f.complete(message)
        await #expect(throws: AgentWorkflowError.self) { try await f.interaction.send(message) }
        #expect(f.writes.count == 1)
        try await f.cleanup()
    }

    @Test
    func wrongProcessPromptTurnAndTranscriptCannotBindReply() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        main.draft = "Exact message"
        await main.send()
        let message = try #require(main.messages.last)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let turn = UUID().uuidString
        let path = f.root.appendingPathComponent("turn.jsonl").path
        let event = PluginEvent(
            pluginID: "codex",
            sessionID: message.instance.conversationID,
            tmuxPane: message.instance.paneID,
            workflow: .init(kind: .submitted, nativeTurnID: turn, transcriptPath: path, text: "human prompt")
        )
        try await f.interaction.receive(event, peer: peer)
        #expect(try await f.interaction.store.message(message.id)?.nativeEvent == nil)
        #expect(!AgentReplyEvidence.turn(.init(kind: .stopCandidate, nativeTurnID: turn, transcriptPath: path + "wrong", text: "reply"), id: turn, path: path))
        #expect(!AgentReplyEvidence.turn(.init(kind: .stopCandidate, nativeTurnID: "other", transcriptPath: path, text: "reply"), id: turn, path: path))
        let wrongPeer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 200, startMicroseconds: 0)
        })
        #expect(!AgentReplyEvidence.owns(event, instance: message.instance, peer: wrongPeer))
        try await f.complete(message)
        #expect(try await f.interaction.store.message(message.id)?.answer == "verified answer")
        try await f.cleanup()
    }

    @Test
    func cancellationRevokesFinalWritePermit() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let message = try AgentMessage(instance: #require(main.instance), text: "cancel")
        try await f.interaction.store.insert(message)
        try await f.interaction.store.update(message.id) { $0.status = .writing }
        let permit = try await f.interaction.store.authorize(message.id)
        try await f.interaction.stopWaiting(message.id)
        #expect(throws: (any Error).self) { try permit.perform { Issue.record("Cancelled input must not be written") } }
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func historyReadsAreBoundedAndInterruptedWritesAreNotReplayed() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let instance = try #require(main.instance)
        var ids: [UUID] = []
        for i in 0..<250 {
            var message = AgentMessage(instance: instance, text: "history \(i)")
            message.status = .succeeded
            message.answer = "reply"
            try await f.interaction.store.importMessage(message)
            ids.append(message.id)
        }
        #expect(try await f.interaction.store.messages(ids).count == 100)
        #expect(try await f.interaction.store.messages(ids, limit: 1_000).count == 200)
        #expect(try await f.interaction.store.pending().isEmpty)
        var pending = AgentMessage(instance: instance, text: "interrupted")
        pending.status = .writing
        try await f.interaction.store.importMessage(pending)
        try await f.interaction.start()
        #expect(try await f.interaction.store.message(pending.id)?.status == .uncertain)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }
}
