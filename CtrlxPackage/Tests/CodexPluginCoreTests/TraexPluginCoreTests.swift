import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct TraexPluginCoreTests {
    @Test("Captured native Traex question lifecycle preserves notifications and completion", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_TRAEX_QUESTION_PROBES"] != nil))
    func capturedQuestionNotifications() async throws {
        let probes = try #require(ProcessInfo.processInfo.environment["CTRLX_TRAEX_QUESTION_PROBES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-question-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["async", "blocking"] {
            let url = URL(fileURLWithPath: probes).appendingPathComponent("\(mode)/native-report.json")
            let report = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(report["timeout"] as? Bool == false)
            let frames = try #require(report["events"] as? [[String: Any]])
            let payloads = frames.compactMap { $0["payload"] as? [String: Any] }.filter {
                $0["hook_event_name"] as? String == "PreToolUse" && $0["tool_name"] as? String == "AskUserQuestion"
            }
            try #require(!payloads.isEmpty)
            let core = CodexPluginCore(correlation: .init(root: root), distribution: .traex)
            var notifications: [NotificationSpec] = []
            var last: PluginEvent?
            for frame in frames {
                let body = try #require(frame["payload"] as? [String: Any])
                let payload = try JSONSerialization.data(withJSONObject: body)
                let event = try #require(await core.handleIngress(.init(pluginID: "traex", context: ["TMUX_PANE": "%7"], payload: payload)))
                if let notification = event.notification, notification.isQuestion == true {
                    notifications.append(notification)
                    #expect(notification.title == "Traex wants answers")
                    #expect(event.state == nil)
                }
                if body["hook_event_name"] as? String == "Stop" {
                    let answer = try #require(body["last_assistant_message"] as? String)
                    #expect(event.state == .doneWorking(summary: answer))
                }
                last = event
            }
            #expect(notifications.count == payloads.count)
            #expect(Set(notifications.compactMap(\.questionID)).count == notifications.count)
            for (notice, payload) in zip(notifications, payloads) {
                let input = try #require(payload["tool_input"] as? [String: Any])
                let questions = try #require(input["questions"] as? [[String: Any]])
                #expect(notice.body == questions.first?["question"] as? String)
            }
            if let results = report["rollouts"] as? [[String: Any]], results.contains(where: { ($0["tool_results"] as? [Any])?.isEmpty == false }) {
                #expect(last?.state == .doneWorking(summary: "TRAEX_FIXTURE_OK"))
            }
        }
    }

    @Test("Native Traex questions notify once per call without fabricating a Codex response form", arguments: [false, true])
    func questionNotifications(blocking: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-questions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CodexPluginCore(correlation: .init(root: root), distribution: .traex)
        var payload: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "fixture-session", "cwd": "/fixture/repo",
            "tool_name": "AskUserQuestion", "tool_use_id": "call-a", "permission_mode": "default",
            "tool_input": ["isBlocking": blocking, "questions": [[
                "header": "Fixture", "question": "Pick the fixture choice", "multiSelect": false,
                "options": [["label": "Alpha", "description": "First option"], ["label": "Beta", "description": "Second option"]],
            ]]],
        ]
        func frame() throws -> IngressFrame {
            try .init(pluginID: "traex", context: ["TMUX_PANE": "%7"], payload: JSONSerialization.data(withJSONObject: payload))
        }
        let first = try frame()
        let event = try #require(await core.handleIngress(first))
        #expect(event.notification?.title == "Traex wants answers")
        #expect(event.notification?.body == "Pick the fixture choice")
        #expect(event.notification?.isQuestion == true)
        #expect(event.notification?.questionID == "fixture-session:call-a")
        #expect(event.tmuxPane == "%7" && event.projectPath == "/fixture/repo")
        #expect(event.state == nil && event.appActions.isEmpty)
        #expect(await core.handleIngress(first) == nil)
        #expect(CodexQuestionNotification(payload: first.payload) == nil)
        payload["tool_use_id"] = "call-b"
        #expect(try await core.handleIngress(frame())?.notification?.questionID == "fixture-session:call-b")
        payload["tool_use_id"] = "child-call"
        payload["agent_id"] = "child"
        #expect(try await core.handleIngress(frame()) == nil)
    }

    @Test("Traex owns its command, configuration, history and correlation directories")
    func separateConfiguration() {
        let home = URL(fileURLWithPath: "/fixture")
        let environment = ["CODEX_HOME": "/codex-account", "TRAE_HOME": "/traex-account"]
        #expect(CodexDistribution.traex.defaultHome(home: home, environment: environment).path == "/traex-account")
        #expect(CodexDistribution.traex.defaultHome(home: home, environment: ["CODEX_HOME": "/codex-account"]).path == "/fixture/.trae")
        #expect(CodexDistribution.codex.defaultHome(home: home, environment: environment).path == "/codex-account")
        #expect(CodexDistribution.traex.settings(from: Data()).commandPath == "traex")
        #expect(CodexDistribution.traex.settings(from: Data(#"{"command_path":"/tools/traecli"}"#.utf8)).commandPath == "/tools/traecli")
        #expect(CodexDistribution.codex.settings(from: Data()).commandPath == "codex")
        #expect(CodexSessionCorrelation.live(pluginID: "traex", home: home).root.path == "/fixture/.ctrlx/state/plugins/traex/codex-sessions")
        #expect(CodexSessionCorrelation.live(home: home).root.path == "/fixture/.ctrlx/codex-sessions")
    }

    @Test("Traex uses its native Provider and embedded backend without Codex account queries")
    func nativeLaunch() async throws {
        let core = CodexPluginCore(distribution: .traex)
        let launch = try #require(await core.commandForLaunch(projectPath: "/project"))
        #expect(launch.command == "traex")
        #expect(launch.args == ["--dangerously-bypass-hook-trust", "--no-daemon"])
        #expect(launch.env.isEmpty)
        #expect(await core.providerOptions().isEmpty)
        #expect(await core.dashboardAccounts().isEmpty)
        #expect(core.modelDiscoveryCommand == "traex")
        #expect(core.workflowComposer.prompt == "❯ ")
        #expect(core.supportsWorkflowCLI("traecli 0.213.1"))
        #expect(!core.supportsWorkflowCLI("codex-cli 0.167.0"))
        #expect(!core.supportsWorkflowCLI("traecli 0.214.0"))
        await #expect(throws: AgentProviderError.self) {
            try await core.commandForLaunch(projectPath: "/project", providerID: "openai")
        }
    }

    @Test("Traex does not inherit Codex's unverified OTLP exporter")
    func telemetryIsNotAssumed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CodexPluginCore(correlation: .init(root: root), distribution: .traex)
        try await core.initialize(.init(
            pluginRoot: root, stateDir: root, appVersion: "fixture", settings: Data(), marketplaceSource: root,
            otlpReceiverEndpoint: URL(string: "http://127.0.0.1:54321")
        ), host: MockPluginHost())
        let launch = try #require(await core.commandForLaunch(projectPath: "/project"))
        #expect(launch.args == ["--dangerously-bypass-hook-trust", "--no-daemon"])
        #expect(await core.terminalTelemetryArguments().isEmpty)
        await core.shutdown()
    }

    @Test("Native Traex hooks keep their own identity and durable turn evidence")
    func hooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CodexPluginCore(correlation: .init(root: root), distribution: .traex)
        let session = UUID().uuidString
        let turn = UUID().uuidString
        let start = Data("""
        {"hook_event_name":"SessionStart","session_id":"\(session)","cwd":"/project","source":"startup","permission_mode":"default"}
        """.utf8)
        let started = try #require(await core.handleIngress(.init(pluginID: "traex", context: ["TMUX_PANE": "%1"], payload: start)))
        #expect(started.pluginID == "traex" && started.sessionID == session && started.tmuxPane == "%1")
        let prompt = Data("""
        {"hook_event_name":"UserPromptSubmit","session_id":"\(session)","turn_id":"\(turn)","transcript_path":"/traex/cli/sessions/rollout-fixture.jsonl","cwd":"/project","prompt":"fixture","permission_mode":"default"}
        """.utf8)
        let submitted = try #require(await core.handleIngress(.init(pluginID: "traex", context: ["CTRLX_WORKFLOW_VERSION": "1"], payload: prompt)))
        #expect(submitted.pluginID == "traex" && submitted.tmuxPane == "%1")
        #expect(submitted.workflow?.nativeTurnID == turn)
        #expect(await core.handleIngress(.init(pluginID: "codex", context: ["TMUX_PANE": "%2"], payload: start)) == nil)
    }

    @Test("Traex resume preserves TRAE_HOME and permission mode without reading Codex history")
    func resumeAndFork() async throws {
        let id = UUID().uuidString
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, layout in
                #expect(layout == .traex)
                #expect(!roots.contains("/other-codex"))
                return "/traex/source"
            }
            $0[AgentResumeExecutableClient.self].resolve = { recorded, fallback in recorded ?? fallback }
        } operation: {
            let core = CodexPluginCore(distribution: .traex)
            let invocation = AgentResumeInvocation(executable: "/tools/traex", arguments: ["--permission-mode", "auto", "--shell-tool-timeout", "120s"], configurationRoots: ["CODEX_HOME": "/other-codex", "TRAE_HOME": "/traex/source"], version: "traecli 0.213.1")
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: invocation)
            #expect(descriptor.pluginID == "traex" && descriptor.configurationRoot == "/traex/source")
            #expect(descriptor.automaticResumeUnavailableReason == nil)
            let resumed = try await core.commandForResume(descriptor)
            #expect(resumed.command.command == "/tools/traex")
            #expect(resumed.command.env == ["TRAE_HOME": "/traex/source"])
            #expect(resumed.command.args == ["--shell-tool-timeout", "120s", "resume", id, "-C", "/project", "--permission-mode", "auto", "--dangerously-bypass-hook-trust", "--no-daemon"])
            let fork = try await core.commandForFork(sessionID: id, projectPath: "/fork")
            #expect(fork.command.command == "traex" && fork.command.env == ["TRAE_HOME": "/traex/source"])
        }
    }

    @Test("Native Traex accepts restored top-level timeout options", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_TRAEX_NATIVE_TESTS"] == "1"))
    func nativeResumeArguments() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["CTRLX_TRAEX_TEST_EXECUTABLE"]
            ?? (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/traex" }
            .first { FileManager.default.isExecutableFile(atPath: $0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-resume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[AgentForkHistoryClient.self].root = { _, _, _ in root.path }
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in executable }
        } operation: {
            let core = CodexPluginCore(distribution: .traex)
            for arguments in [
                ["--shell-tool-timeout", "120s", "--permission-mode", "auto"],
                ["--permission-mode", "auto", "--shell-tool-timeout=120s"],
            ] {
                let invocation = AgentResumeInvocation(executable: executable, arguments: arguments, configurationRoots: ["TRAE_HOME": root.path], version: "traecli 0.213.1")
                let descriptor = try await core.recoveryDescriptor(sessionID: UUID().uuidString, projectPath: root.path, invocation: invocation)
                let launch = try await core.commandForResume(descriptor).command
                let environment = launch.env.merging([
                    "HOME": root.path, "TRAEX_AUTO_UPDATE_ON_STARTUP": "0", "TRAECLI_AUTO_UPDATE_ON_STARTUP": "0",
                ]) { _, isolated in isolated }
                // --help validates the actual argv without starting or resuming an Agent.
                let result = try await ProcessRunner.liveValue.run(launch.command, launch.args + ["--help"], environment, 10)
                #expect(result.isSuccess, "\(result.stderrString)")
                #expect(result.stdoutString.contains("Resume a previous interactive session"))
            }
        }
    }

    @Test("Traex catalogs omit display_name and use the slug as their native label")
    func modelCatalog() throws {
        let data = Data(#"{"models":[{"slug":"fixture","visibility":"list","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#.utf8)
        let models = try CodexModelCatalog.parse(data)
        #expect(models.first?.id == "fixture" && models.first?.name == "fixture")
        #expect(models.first?.efforts == ["low", "high"])
        let core = CodexPluginCore(distribution: .traex)
        #expect(core.modelSelection(lines: ["fixture high · ~/workspace"], models: models)?.effort == "high")
        #expect(core.modelSelection(lines: ["fixture · ~/workspace"], models: models) == nil)
    }

    @Test("Unsupported Traex inline model commands never become an Agent task")
    func modelCommandsAreNotPrompts() async throws {
        let core = CodexPluginCore(distribution: .traex)
        let model = AgentModelOption(id: "fixture", name: "fixture", efforts: ["low", "high"], defaultEffort: "low")
        let terminal = AgentModelTerminal(read: { ["fixture low · ~/workspace"] }, submit: { _ in
            Issue.record("An unsupported inline model command was sent to Traex.")
        }, send: { _ in
            Issue.record("Unexpected Traex keyboard input.")
        })
        await #expect(throws: AgentModelError.self) {
            try await core.selectModel(.init(model: "fixture", effort: "high"), models: [model], terminal: terminal)
        }
    }

    @Test("Traex hook trust does not drive the incompatible Codex menu")
    func hookTrustIsNative() async {
        let core = CodexPluginCore(distribution: .traex)
        let terminal = AgentHookTrustTerminal(read: { [] }, perform: { _ in
            Issue.record("Unexpected automatic hook trust input to Traex.")
        })
        await #expect(throws: AgentHookTrustError.self) {
            try await core.trustHooks(terminal: terminal, refreshIfTrusted: true)
        }
    }

    @Test("Traex history is resolved only under cli/sessions")
    func nativeHistoryAndProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-history-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let sessions = root.appendingPathComponent("cli/sessions/2026/11/18")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "source": "cli", "cwd": project.path, "cli_version": "0.213.1"]])
        try (header + Data([10])).write(to: sessions.appendingPathComponent("rollout-fixture-\(id).jsonl"))
        #expect(try await AgentForkHistoryClient.liveValue.root(id, [root.path], .traex) == root.path)
        await #expect(throws: AgentForkError.self) { try await AgentForkHistoryClient.liveValue.root(id, [root.path], .codex) }
        let projects = CodexScanner(distribution: .traex).scan(codexHomeRoots: [root])
        #expect(projects.count == 1 && projects.first?.pluginID == "traex" && projects.first?.path == project.path)
        #expect(CodexScanner().scan(codexHomeRoots: [root]).isEmpty)
    }

    @Test("Traex 0.213.1 native completion uses the Codex rollout parser")
    func nativeCompletionReplay() throws {
        var parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "turn")
        for record in [
            #"{"type":"session_meta","payload":{"id":"session","originator":"traex-tui","cli_version":"0.213.1","source":"cli"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn","root_turn_id":"turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"session","turn_id":"turn"}}"#,
        ] {
            #expect(try parser.consume(Data(record.utf8)) == nil)
        }
        let completed = Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn","last_agent_message":"TRAEX_FIXTURE_OK","duration_ms":1000}}"#.utf8)
        #expect(try parser.consume(completed) == .succeeded("TRAEX_FIXTURE_OK"))
    }
}
