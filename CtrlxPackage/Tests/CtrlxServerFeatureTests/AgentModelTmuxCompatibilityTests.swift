import CodexPluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelTmuxCompatibilityTests {
    private let models = [AgentModelOption(id: "test-model", name: "Test Model", efforts: ["low", "high"], defaultEffort: "low")]
    private let identity = WorkspacePaneIdentity(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())

    private func output(paste: String) -> String {
        let metadata = ["80", "5", "2", "1", "1", paste, "0", "codex"].joined(separator: "\u{1f}")
        return metadata + "\n\n› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  Test Model low · /fixture\n\n"
    }

    @Test("Missing input-mode capability preserves the model selection but cannot enable switching", arguments: ["", "0", "1"])
    func terminalModes(paste: String) async throws {
        let terminalOutput = output(paste: paste)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                #expect(arguments.first == "if-shell")
                #expect(arguments.contains { $0.contains("capture-pane") && $0.contains("display-message") })
                #expect(!arguments.contains { $0.contains("send-keys") || $0.contains("paste-buffer") })
                return ProcessResult(exitCode: 0, stdout: Data(terminalOutput.utf8), stderr: Data())
            }
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.windowManager.setPaneStatesForPreview([PaneState(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "codex"))])
            let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: "%1", identity: identity)
            let core = CodexPluginCore()
            #expect(screen.bracketedPaste == (paste.isEmpty ? nil : paste == "1"))
            #expect(core.modelSelection(lines: screen.plainLines, models: models) == .init(model: "test-model", effort: "low"))
            let issue = coordinator.agentModelInputIssue(paneID: "%1", screen: screen, provider: core, models: models)
            if paste.isEmpty {
                #expect(issue?.contains("tmux 3.7") == true)
                #expect(issue?.contains("running tmux server") == true)
            } else if paste == "0" {
                #expect(issue != nil)
                #expect(issue?.contains("tmux 3.7") == false)
            } else {
                #expect(issue == nil)
            }
            #expect(AgentWorkflowComposerInspection.readiness(screen, composer: core.modelComposer) == (paste == "1" ? .ready : .unavailable))
        }
    }

    @Test("Malformed mode data is not treated as an older server", arguments: ["invalid", "2", "-1"])
    func invalidMode(paste: String) {
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowTerminalCapture.parse(output(paste: paste)) }
    }

    @Test("Incomplete terminal metadata remains an error", arguments: ["", "80\u{1f}5\n", "80\u{1f}5\u{1f}?\u{1f}1\u{1f}1\u{1f}\u{1f}0\u{1f}codex\n"])
    func invalidMetadata(_ output: String) {
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowTerminalCapture.parse(output) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"] != nil))
    func nativeServerCaptureAndInputGuard() async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await runNative() }
    }

    private func runNative() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"])
        let unknown = ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXPECT_UNKNOWN"] == "1"
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-mode-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let run: @Sendable ([String]) async throws -> ProcessResult = { arguments in
            try await ProcessRunner.liveValue.run(executable, ["-S", socket, "-f", "/dev/null"] + arguments, ["TMUX": "", "TMUX_PANE": ""], 10)
        }
        let script = directory.appendingPathComponent("terminal.py")
        let received = directory.appendingPathComponent("received")
        try """
        import os, sys, tty
        tty.setraw(0)
        os.write(1, '\u{1b}[?2004h\u{1b}[2J\u{1b}[4;3HTest Model low · /fixture\u{1b}[2;1H› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\u{1b}[2;3H'.encode())
        with open(sys.argv[1], 'ab', buffering=0) as output:
            while True:
                data = os.read(0, 65536)
                if not data: break
                output.write(data)
        """.write(to: script, atomically: true, encoding: .utf8)
        do {
            try #require(try await run(["new-session", "-d", "-s", "probe", "-x", "80", "-y", "24", "/usr/bin/python3", script.path, received.path]).isSuccess)
            let service = TmuxService(tmuxPath: executable, socketPath: socket)
            let pane = try await service.captureWorkspacePane(target: "probe")
            var screen = try await service.captureAgentTerminal(paneID: pane.info.paneId, identity: pane.identity)
            for _ in 0..<100 {
                if screen.plainLines.contains(where: { $0.contains("Test Model low") }), FileManager.default.fileExists(atPath: received.path) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
                screen = try await service.captureAgentTerminal(paneID: pane.info.paneId, identity: pane.identity)
            }
            #expect(screen.bracketedPaste == (unknown ? nil : true))
            #expect(CodexPluginCore().modelSelection(lines: screen.plainLines, models: models) == .init(model: "test-model", effort: "low"))
            #expect(AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().modelComposer) == (unknown ? .unavailable : .ready))
            let result = try await run(["if-shell", "-F", "-t", pane.info.paneId, "#{bracket_paste_flag}", "send-keys -H -t \(pane.info.paneId) 58", "display-message -p input-unverified"])
            if unknown {
                #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "input-unverified")
                #expect(try Data(contentsOf: received).isEmpty)
            } else {
                for _ in 0..<100 {
                    if try Data(contentsOf: received) == Data("X".utf8) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(try Data(contentsOf: received) == Data("X".utf8))
            }
        } catch {
            _ = try? await run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }
}
