import ClaudeCodePluginCore
import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Darwin
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentMessagePendingEventTests {
    @Test(arguments: ["classification", "receipt"])
    func queuedPendingStopPreventsRecoveryUntilFinalReply(delay: String) async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let classifierEntered = LockIsolated(false)
        let receiptEntered = LockIsolated(false)
        let synchronization = LockIsolated(0)
        let ingressDrained = LockIsolated(false)
        let f = try await AgentInteractionTestSupport()
        f.replyProvider = { _ in ClaudeCodePluginCore() }
        try await f.restartInteraction()
        let main = await f.orbie()
        try await main.create(pluginID: "claude-code", providerID: nil)
        main.draft = "Run the checks and report the result"
        await main.send()
        let message = try #require(main.messages.last)
        let transcript = f.root.appendingPathComponent("native.jsonl")
        try record(message, ["type": "user", "uuid": "user", "promptId": "turn"]).write(to: transcript)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let service = try #require(f.interaction)
        try await service.receive(.init(
            pluginID: "claude-code", sessionID: message.instance.conversationID, tmuxPane: message.instance.paneID,
            workflow: .init(kind: .submitted, nativeTurnID: "turn", transcriptPath: transcript.path, text: message.prompt)
        ), peer: peer)
        try await wait {
            let receipts = await service.observationCounts().receipts
            return try await service.store.message(message.id)?.status == .running && receipts == 0
        }

        try await withDependencies {
            $0[PluginIngressPeerClient.self].capture = { _ in peer }
            $0[StopFinalityClassifier.self] = .init(classify: { _ in
                classifierEntered.setValue(true)
                if delay == "classification" {
                    for await _ in gate.stream {
                        break
                    }
                }
                return .stillWaiting
            }, availability: { .available })
        } operation: {
            let core = ClaudeCodePluginCore()
            let server = IngressSocketServer(
                socketPath: "/tmp/ctrlx-message-\(UUID().uuidString).sock",
                coreLookup: { _ in core },
                dispatcher: PluginEventDispatcher(onWorkflow: { event, peer in
                    do { try await service.receive(event, peer: peer) }
                    catch { Issue.record(error) }
                })
            )
            try await server.start()
            f.synchronizeEvents = {
                synchronization.withValue { $0 += 1 }
                try await server.waitForPendingFrames()
                ingressDrained.setValue(true)
            }
            if delay == "receipt" {
                f.inspectReply = { instance in
                    let first = receiptEntered.withValue { entered in
                        let first = !entered
                        entered = true
                        return first
                    }
                    if first {
                        for await _ in gate.stream {
                            break
                        }
                    }
                    return instance
                }
            }
            do {
                try await sendStop(server, message: message, transcript: transcript, pending: true)
                try await wait { classifierEntered.value && (delay == "classification" || receiptEntered.value) }
                // The bridge has its ACK and writes the native summary while
                // classification or message receipt validation is still blocked.
                try appendAnswer(message, to: transcript, id: "interim", parent: "user", text: "Checks are still running")
                try await wait { synchronization.value > 0 }
                if delay == "receipt" {
                    try await wait { ingressDrained.value }
                }
                try await Task.sleep(for: .milliseconds(300))
                let waiting = try #require(try await service.store.message(message.id))
                #expect(waiting.status == .running && waiting.answer == nil && waiting.completedAt == nil)
                #expect(waiting.nativeEvent?.kind == .submitted)
                #expect(try await service.availability(message.agentID) != nil)

                gate.continuation.finish()
                try await wait {
                    let receipts = await service.observationCounts().receipts
                    return try await service.store.message(message.id)?.nativeEvent?.hasPendingWork == true && receipts == 0
                }
                let pending = try #require(try await service.store.message(message.id))
                #expect(pending.status == .running && pending.answer == nil)

                try appendAnswer(message, to: transcript, id: "final", parent: "interim-stop", text: "Final reply")
                try await sendStop(server, message: message, transcript: transcript, pending: false)
                try await wait { try await service.store.message(message.id)?.status == .succeeded }
                let completed = try #require(try await service.store.message(message.id))
                #expect(completed.answer == "Final reply" && completed.completedAt != nil)
                #expect(try await service.availability(message.agentID) == nil)
                #expect(f.writes.count == 1)
                await server.stop()
                try await f.cleanup()
            } catch {
                gate.continuation.finish()
                await server.stop()
                try await f.cleanup()
                throw error
            }
        }
    }

    private func record(_ message: AgentMessage, _ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields.merging([
            "sessionId": message.instance.conversationID, "isSidechain": false,
        ]) { _, value in value }) + Data([10])
    }

    private func appendAnswer(_ message: AgentMessage, to transcript: URL, id: String, parent: String, text: String) throws {
        let answer = try record(message, ["type": "assistant", "uuid": id, "parentUuid": parent, "message": [
            "id": id, "stop_reason": "end_turn", "content": [["type": "text", "text": text]],
        ]])
        let summary = try record(message, [
            "type": "system",
            "subtype": "stop_hook_summary",
            "uuid": id + "-stop",
            "parentUuid": id,
            "hookErrors": [],
            "hookAdditionalContext": [],
            "preventedContinuation": false,
            "stopReason": "",
        ])
        let file = try FileHandle(forWritingTo: transcript)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: answer + summary)
    }

    private func sendStop(_ server: IngressSocketServer, message: AgentMessage, transcript: URL, pending: Bool) async throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop", "session_id": message.instance.conversationID, "prompt_id": "turn",
            "transcript_path": transcript.path, "last_assistant_message": pending ? "Checks are still running" : "Final reply",
            "background_tasks": pending ? [["id": "checks", "type": "shell", "status": "running"]] : [],
        ]
        let frame = try IngressFrame(pluginID: "claude-code", context: ["TMUX_PANE": message.instance.paneID, "CTRLX_INGRESS_ACK": "1"], payload: JSONSerialization.data(withJSONObject: payload))
        let bytes = try frame.encodeFrame()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = await server.boundSocketPath
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                UnsafeMutableRawPointer(target).copyMemory(from: source, byteCount: path.utf8.count + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        try #require(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count)
        try await awaitIngressAcknowledgement(fd)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentWorkflowError("Timed out waiting for the delayed Stop test")
    }
}
