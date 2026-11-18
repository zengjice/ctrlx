import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentMessageRecoveryTests {
    private struct Fixture {
        let support: AgentInteractionTestSupport
        let message: AgentMessage
        let transcript: URL
        let peer: PluginIngressPeer

        func event(_ kind: PluginWorkflowEvent.Kind, pending: Bool = false) -> PluginEvent {
            .init(
                pluginID: message.instance.pluginID, sessionID: message.instance.conversationID,
                tmuxPane: message.instance.paneID,
                workflow: .init(
                    kind: kind,
                    nativeTurnID: "turn",
                    transcriptPath: transcript.path,
                    text: kind == .submitted ? message.prompt : "Full reply",
                    hasPendingWork: pending
                )
            )
        }
    }

    private func fixture(_ plugin: String, accepted: Bool = true) async throws -> Fixture {
        let f = try await AgentInteractionTestSupport()
        f.replyProvider = { plugin in
            if plugin == "codex" {
                return CodexPluginCore()
            }
            return ClaudeCodePluginCore()
        }
        try await f.restartInteraction()
        let main = await f.orbie()
        try await main.create(pluginID: plugin, providerID: nil)
        main.draft = "Does it rain this weekend?"
        await main.send()
        let message = try #require(main.messages.last)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let transcript = f.root.appendingPathComponent("native.jsonl")
        try records(plugin, conversation: message.instance.conversationID, finished: false).write(to: transcript)
        let result = Fixture(support: f, message: message, transcript: transcript, peer: peer)
        if accepted {
            try await f.interaction.receive(result.event(.submitted), peer: peer)
            try await wait(.running, result)
        }
        return result
    }

    private func records(_ plugin: String, conversation: String, turn: String = "turn", finished: Bool = true, completionOnly: Bool = false) throws -> Data {
        var rows: [[String: Any]] = []
        if plugin == "codex" {
            if !completionOnly {
                rows = [
                    ["type": "session_meta", "payload": ["id": conversation]],
                    ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
                ]
            }
            if finished {
                rows.append(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": "Full reply"]])
            }
        } else {
            if !completionOnly {
                rows = [["type": "user", "uuid": "user", "promptId": turn]]
            }
            if finished {
                rows += [
                    ["type": "assistant", "uuid": "answer", "parentUuid": "user", "message": ["id": "message", "stop_reason": "end_turn", "content": [["type": "text", "text": "Full reply"]]]],
                    ["type": "system", "subtype": "stop_hook_summary", "uuid": "stop", "parentUuid": "answer", "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": ""],
                ]
            }
            rows = rows.map { $0.merging(["sessionId": conversation, "isSidechain": false]) { _, value in value } }
        }
        return try rows.reduce(into: Data()) { data, row in
            try data.append(JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
    }

    private func appendCompletion(_ fixture: Fixture) throws {
        let file = try FileHandle(forWritingTo: fixture.transcript)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: records(fixture.message.instance.pluginID, conversation: fixture.message.instance.conversationID, completionOnly: true))
    }

    private func wait(_ status: AgentWorkflowInvocationStatus, _ fixture: Fixture) async throws {
        for _ in 0..<500 {
            let counts = await fixture.support.interaction.observationCounts()
            if
                try await fixture.support.interaction.store.message(fixture.message.id)?.status == status,
                counts.receipts == 0, status == .running || counts.transcripts == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Message did not reach \(status)")
    }

    @Test(arguments: ["codex", "claude-code"], ["before-restart", "after-restart", "live"])
    func missingStopRecoversNativeReplyWithoutResending(plugin: String, completion: String) async throws {
        let f = try await fixture(plugin)
        if completion != "live" {
            await f.support.interaction.shutdown()
        }
        if completion == "before-restart" {
            try appendCompletion(f)
        }
        if completion != "live" {
            try await f.support.restartInteraction()
        }
        if completion != "before-restart" {
            try appendCompletion(f)
        }
        try await wait(.succeeded, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.answer == "Full reply" && saved.completedAt != nil && saved.issue == nil)
        #expect(saved.nativeEvent?.kind == .submitted, "Recovery must not invent a Stop callback")
        #expect(try await f.support.interaction.availability(saved.agentID) == nil)
        let reopened = await f.support.orbie()
        #expect(reopened.messages.last?.answer == "Full reply" && reopened.availability == nil)

        try await f.support.interaction.receive(f.event(.stopCandidate), peer: f.peer)
        try await f.support.interaction.receive(f.event(.submitted), peer: f.peer)
        #expect(try await f.support.interaction.store.message(saved.id) == saved)
        try await f.support.restartInteraction()
        #expect(try await f.support.interaction.store.message(saved.id) == saved)
        #expect(await f.support.interaction.observationCounts().transcripts == 0)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"], ["conversation", "turn", "unfinished", "partial", "unaccepted", "pending-work"])
    func unrelatedOrIncompleteEvidenceCannotCompleteMessage(plugin: String, change: String) async throws {
        let f = try await fixture(plugin, accepted: change != "unaccepted")
        if change == "pending-work" {
            try await f.support.interaction.receive(f.event(.stopCandidate, pending: true), peer: f.peer)
            for _ in 0..<100 {
                if try await f.support.interaction.store.message(f.message.id)?.nativeEvent?.kind == .stopCandidate {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await f.support.interaction.shutdown()
        var bytes = try records(
            plugin,
            conversation: change == "conversation" ? "other" : f.message.instance.conversationID,
            turn: change == "turn" ? "other" : "turn",
            finished: change != "unfinished"
        )
        if change == "partial" {
            bytes.removeLast()
        }
        try bytes.write(to: f.transcript)
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(500))
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(saved.answer == nil && saved.completedAt == nil)
        #expect(saved.status == (change == "unaccepted" ? .uncertain : .running))
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func changedConversationCannotReceiveOldReply(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        f.support.observations[0].conversationID = "different-conversation"
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(100))
        try await wait(.uncertain, f)
        #expect(try await f.support.interaction.store.message(f.message.id)?.answer == nil)
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: [false, true])
    func recoverySynchronizationRetriesWithinBudget(recovers: Bool) async throws {
        let f = try await fixture("codex")
        let attempts = LockIsolated(0)
        f.support.synchronizeEvents = {
            let count = attempts.withValue { $0 += 1
                return $0
            }
            if count == 1 || !recovers {
                throw AgentWorkflowInspectionUnavailable()
            }
        }
        try await f.support.restartInteraction(verificationTimeout: .milliseconds(450))
        try appendCompletion(f)
        try await wait(recovers ? .succeeded : .uncertain, f)
        let saved = try #require(try await f.support.interaction.store.message(f.message.id))
        #expect(attempts.value >= 2 && attempts.value <= 3)
        #expect(saved.answer == (recovers ? "Full reply" : nil))
        #expect(f.support.writes.count == 1)
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func workflowMonitorStillRequiresStopForAutomaticHandoff(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        let completed = LockIsolated<[AgentWorkflowTranscriptOutcome]>([])
        let monitor = AgentReplyMonitor(state: { context in .init(isPending: true, instance: context.instance) }, completed: { _, _, outcome in
            completed.withValue { $0.append(outcome) }
        }, waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) }, inspect: { $0 }, verificationTimeout: .milliseconds(100), onFailure: { Issue.record(Comment(rawValue: $0)) })
        let provider = try #require(await f.support.replyProvider(plugin))
        let receipt = try #require(f.event(.submitted).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt), provider: provider)
        try await Task.sleep(for: .milliseconds(300))
        let activeCount = await monitor.activeCount
        #expect(completed.value.isEmpty && activeCount == 1)
        let stop = try #require(f.event(.stopCandidate).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: stop), provider: provider)
        for _ in 0..<100 {
            if !completed.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == [.succeeded("Full reply")])
        await monitor.shutdown()
        try await f.support.cleanup()
    }

    @Test(arguments: ["codex", "claude-code"])
    func stopArrivingDuringRecoveryKeepsItsVerifier(plugin: String) async throws {
        let f = try await fixture(plugin)
        await f.support.interaction.shutdown()
        try appendCompletion(f)
        let recovering = LockIsolated(false)
        let release = LockIsolated(false)
        let completed = LockIsolated<[AgentWorkflowTranscriptOutcome]>([])
        let monitor = AgentReplyMonitor(state: { context in .init(isPending: true, instance: context.instance) }, completed: { context, _, outcome in
            if context.candidate.kind == .submitted {
                recovering.setValue(true)
                for _ in 0..<500 {
                    if release.value {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Stop did not arrive while recovery was saving")
            } else {
                completed.withValue { $0.append(outcome) }
            }
        }, waiting: { _, reason, _ in Issue.record(Comment(rawValue: reason)) }, inspect: { $0 }, synchronizeRecovery: { _ in }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let provider = try #require(await f.support.replyProvider(plugin))
        let receipt = try #require(f.event(.submitted).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: receipt), provider: provider)
        for _ in 0..<500 {
            if recovering.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recovering.value)
        let stop = try #require(f.event(.stopCandidate).workflow)
        await monitor.verify(.init(id: f.message.id, instance: f.message.instance, prompt: f.message.prompt, candidate: stop), provider: provider)
        release.setValue(true)
        for _ in 0..<100 {
            if !completed.value.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == [.succeeded("Full reply")])
        await monitor.shutdown()
        try await f.support.cleanup()
    }
}
