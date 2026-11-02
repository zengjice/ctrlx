import ClaudeCodePluginCore
import CodexPluginCore
import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Darwin
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

private actor NativeReviewCore: PluginCore, AgentWorkflowProviding {
    nonisolated let codex: Bool
    nonisolated let provider: any AgentWorkflowProviding
    private var working: Set<String> = []
    func isWorking(_ session: String) -> Bool {
        working.contains(session)
    }

    init(codex: Bool) {
        self.codex = codex
        if codex {
            self.provider = CodexPluginCore()
        } else {
            self.provider = ClaudeCodePluginCore()
        }
    }

    func initialize(_ env: PluginEnv, host: any PluginHost) async throws { }
    func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        guard
            let value = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
            let session = value["session_id"] as? String else { return nil }
        let event = PluginWorkflowHook.event(payload: frame.payload, nativeTurnKey: codex ? "turn_id" : "prompt_id")
        if event?.kind == .submitted {
            working.insert(session)
        }
        if event?.kind == .stopCandidate || event?.kind == .failed {
            working.remove(session)
        }
        print("HOOK", frame.pluginID, value["hook_event_name"] ?? "?", event?.nativeTurnID ?? "none")
        return PluginWorkflowHook.addingEvidence(to: .init(pluginID: frame.pluginID, sessionID: session, tmuxPane: frame.context["TMUX_PANE"]), from: frame, nativeTurnKey: codex ? "turn_id" : "prompt_id")
    }

    func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async { }
    func refreshProjects() async { }
    func commandForLaunch(projectPath: String) async -> LaunchCommand? {
        nil
    }

    func install(configRoot: String?) async throws -> InstallResult {
        .alreadyInstalled
    }

    func uninstall(configRoot: String?) async throws { }
    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        .installed(version: "fixture")
    }

    func applySettings(_ raw: Data) async -> SettingsResult {
        .applied
    }

    func shutdown() async { }
    nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        provider.workflowCapabilities
    }

    nonisolated var workflowComposer: AgentWorkflowComposer {
        provider.workflowComposer
    }

    nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        provider.workflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID, prompt: prompt, candidate: candidate)
    }
}

/// Opt-in native CLI acceptance. The fixture supplies only private tmux/profile
/// paths and loopback model endpoints; no installed App or user session is used.
@MainActor
struct AgentWorkflowNativeReviewLoopTests {
    private struct Fixture: Decodable, Sendable {
        struct Agent: Decodable, Sendable {
            let pluginID: String
            let paneID: String
            let processID: Int32
            let conversationID: String
            let version: String
        }

        let root: String
        let tmux: String
        let agents: [Agent]
    }

    private nonisolated func tmux(_ fixture: Fixture, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        process.arguments = ["-S", fixture.tmux] + arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentWorkflowError(String(decoding: output, as: UTF8.self)) }
        return String(decoding: output, as: UTF8.self)
    }

    private nonisolated func processRuntime(_ pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let size = MemoryLayout.size(ofValue: info)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { throw AgentWorkflowError("The fixture Agent exited.") }
        return "\(info.pbi_uid):\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private nonisolated func capture(_ fixture: Fixture, _ instance: AgentWorkflowInstance) throws -> AgentWorkflowTerminalCapture {
        let keys = ["pane_width", "pane_height", "cursor_x", "cursor_y", "cursor_flag", "bracket_paste_flag", "pane_in_mode", "pane_current_command"]
        let metadata = try tmux(fixture, ["display-message", "-p", "-t", instance.paneID, keys.map { "#{\($0)}" }.joined(separator: "|")])
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard metadata.count == 8, let width = Int(metadata[0]), let height = Int(metadata[1]), let x = Int(metadata[2]), let y = Int(metadata[3]) else {
            throw AgentWorkflowError("Incomplete private tmux metadata.")
        }
        return try .init(
            ansi: tmux(fixture, ["capture-pane", "-e", "-p", "-t", instance.paneID]),
            width: width,
            height: height,
            cursorX: x,
            cursorY: y,
            cursorVisible: metadata[4] == "1",
            bracketedPaste: metadata[5] == "1",
            inCopyMode: metadata[6] != "0",
            foregroundCommand: metadata[7]
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_NATIVE_FIXTURE"] != nil))
    func nativeTwoAgentReviewLoop() async throws {
        try await withDependencies {
            $0[PluginIngressPeerClient.self] = .liveValue
        } operation: { try await runNativeSample() }
    }

    private func runNativeSample() async throws {
        let manifest = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["CTRLX_WORKFLOW_NATIVE_FIXTURE"]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifest))
        let root = URL(fileURLWithPath: fixture.root)
        try #require(root.lastPathComponent.hasPrefix("cx-wf-steps-") && fixture.tmux == root.appendingPathComponent("tmux.sock").path)
        try #require(fixture.agents.count == 2)
        let hostID = UUID(), sessionID = UUID()
        let cores = ["codex": NativeReviewCore(codex: true), "claude-code": NativeReviewCore(codex: false)]
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let observations = try fixture.agents.map { agent in
            let core = try #require(cores[agent.pluginID])
            try #require(core.provider.workflowRuntimeIssue(cliVersion: agent.version) == nil)
            return try AgentWorkflowObservation(
                pluginID: agent.pluginID,
                processID: agent.processID,
                processRuntimeID: processRuntime(agent.processID),
                workspacePane: .init(serverID: fixture.tmux, sessionID: sessionID, windowID: UUID(), paneID: UUID()),
                paneID: agent.paneID,
                conversationID: agent.conversationID,
                displayName: agent.pluginID,
                workingDirectory: root.appendingPathComponent("project").path,
                capabilities: cores[agent.pluginID]?.workflowCapabilities,
                readiness: .ready
            )
        }
        let instances = try await store.reconcile(observations)
        let inspect: @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance = { instance in
            guard try processRuntime(instance.processID) == instance.processRuntimeID else { throw AgentWorkflowError("The fixture Agent changed.") }
            let core = try #require(cores[instance.pluginID])
            var live = instance
            live.readiness = try AgentWorkflowComposerInspection.readiness(capture(fixture, instance), composer: core.workflowComposer)
            if await core.isWorking(instance.conversationID) {
                live.readiness = .busy
            }
            return live
        }
        let gate = AgentWorkflowInputGate { _ in throw AgentWorkflowError("Unexpected human input in the private fixture.") }
        let transport = AgentWorkflowTerminalTransport(store: store, gate: gate, temporaryDirectory: root.appendingPathComponent("input"), inspect: inspect, submit: { instance, file, beforeWrite in
            let terminal = try capture(fixture, instance)
            let core = try #require(cores[instance.pluginID])
            try #require(AgentWorkflowComposerInspection.readiness(terminal, composer: core.workflowComposer) == .ready)
            let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: terminal)
            try beforeWrite {
                let result = try tmux(fixture, commands.flatMap { $0 })
                guard !result.contains(AgentWorkflowTmuxSubmission.rejection) else { throw AgentWorkflowError("Private tmux rejected the submission.") }
            }
        }, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let runner = AgentWorkflowRunner(store: store, transport: transport.transport, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let router = AgentWorkflowEventRouter(store: store, runner: runner, inspect: inspect)
        let monitor = AgentWorkflowCompletionMonitor(store: store, runner: runner, inspect: inspect, onFailure: { Issue.record(Comment(rawValue: $0)) })
        let dispatcher = PluginEventDispatcher(onWorkflow: { event, peer in
            do {
                if let instance = instances.first(where: { $0.paneID == event.tmuxPane && $0.conversationID == event.sessionID && $0.pluginID == event.pluginID }) {
                    guard try processRuntime(instance.processID) == instance.processRuntimeID else { return }
                    try await store.recordBridge(event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
                }
                if let context = try await router.receive(event, peer: peer), let core = cores[event.pluginID] {
                    await monitor.verify(context, provider: core)
                }
            } catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
        })
        let ingress = IngressSocketServer(socketPath: root.appendingPathComponent("ingress.sock").path, coreLookup: { cores[$0] }, dispatcher: dispatcher)
        try await ingress.start()
        let api = APISocketServer.liveValue
        let agentService = AgentWorkflowAgentService(store: store, inspect: inspect)
        await api.setRequestHandler { request, peer in await agentService.handle(request, peer: peer) }
        try await api.start(root.appendingPathComponent("api.sock").path)
        do {
            for instance in instances {
                let file = root.appendingPathComponent("warmup-\(instance.id).txt")
                try Data("Confirm isolated workflow bridge readiness.".utf8).write(to: file)
                let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: capture(fixture, instance))
                try #require(try !tmux(fixture, commands.flatMap { $0 }).contains(AgentWorkflowTmuxSubmission.rejection))
            }
            var ready = false
            for _ in 0..<300 {
                var current = true
                for instance in instances {
                    let bridgeIssue = try await store.bridgeIssue(for: instance)
                    let live = try await inspect(instance)
                    if bridgeIssue != nil || live.readiness != .ready {
                        current = false
                    }
                }
                if current {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(ready, "Native hooks did not become ready.")
            let image = try Data(contentsOf: root.appendingPathComponent("task.png")), imageID = UUID()
            _ = try await store.uploadAttachment(.begin(id: imageID, name: "task.png", mediaType: "image/png", size: image.count))
            _ = try await store.uploadAttachment(.append(id: imageID, offset: 0, data: image))
            _ = try await store.uploadAttachment(.finish(id: imageID, sha256: SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()))
            var draft = AgentWorkflowDefinition(name: "Native development and review", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID(), initialInput: .init(text: "Implement the attached fixture image. USER_IMAGE_TASK", attachmentIDs: [imageID]))
            try AgentWorkflowReviewTemplate.apply(to: &draft, developerID: #require(instances.first { $0.pluginID == "codex" }?.id), reviewerID: #require(instances.first { $0.pluginID == "claude-code" }?.id))
            draft.nodes[1].input.text += "\nEnd this workflow only when there are no P0, P1, P2 or P3 findings."
            let definition = try await store.saveDefinition(draft, expectedRevision: nil)
            let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(180))
            await runner.schedule(runID: run.id)
            var latest = run
            for _ in 0..<1_800 {
                latest = try await store.snapshot().runs[0]
                if latest.status.isTerminal || latest.status == .paused {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(latest).write(to: root.appendingPathComponent("native-run.json"))
            try #require(latest.status == .completed, Comment(rawValue: latest.issue ?? "Native sample did not finish."))
            #expect(latest.round == 2 && latest.instances == run.instances && latest.invocations.count == 6)
            #expect(latest.finishRequest != nil)
            #expect(latest.invocations.allSatisfy { $0.result?.text.contains("FIXTURE_ERROR") == false })
            #expect(latest.invocations.filter { $0.nodeID == definition.entryNodeID }.count == 1)
            #expect(latest.invocations.filter { $0.delivery.input.attachmentIDs == [imageID] }.count == 1)
            for invocation in latest.invocations where invocation.nodeID == definition.nodes[1].id {
                #expect(!invocation.delivery.input.text.contains("USER_IMAGE_TASK"))
                #expect(!invocation.delivery.input.text.contains("Answer from") && invocation.delivery.input.attachmentIDs.isEmpty)
            }
            for instance in instances {
                #expect(try processRuntime(instance.processID) == instance.processRuntimeID)
            }
        } catch {
            await runner.shutdown()
            await router.shutdown()
            await monitor.shutdown()
            await ingress.stop()
            await api.stop()
            throw error
        }
        await runner.shutdown()
        await router.shutdown()
        await monitor.shutdown()
        await ingress.stop()
        await api.stop()
    }
}
