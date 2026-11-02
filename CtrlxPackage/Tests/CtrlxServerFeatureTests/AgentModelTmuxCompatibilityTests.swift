import ClaudeCodePluginCore
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

    @Test("Older servers allow manual model switching while explicit disabled paste still blocks it", arguments: ["", "0", "1"])
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
            if paste == "0" {
                #expect(issue != nil)
            } else {
                #expect(issue == nil)
            }
            // Automatic workflows and hook approval still require a known mode.
            #expect(AgentWorkflowComposerInspection.readiness(screen, composer: core.modelComposer) == (paste == "1" ? .ready : .unavailable))
            if paste.isEmpty {
                #expect(coordinator.hookTrustInputIssue(paneID: "%1", screen: screen, composer: core.modelComposer) != nil)
            }
        }
    }

    @Test("Missing paste metadata does not bypass native composer or Agent state checks", arguments: ["draft", "question", "working", "busy-footer", "copy-mode", "unknown-screen"])
    func legacyInputGuards(scenario: String) throws {
        var terminal = output(paste: "")
        var state: AgentState = .idle
        switch scenario {
        case "draft": terminal = terminal.replacingOccurrences(of: "\u{1b}[2mAsk Codex to do anything\u{1b}[0m", with: "unsent draft")
        case "question": state = .awaitingReplies(.init(questions: []), requestID: "request")
        case "working": state = .working
        case "busy-footer": terminal = terminal.replacingOccurrences(of: "\n\n›", with: "\nesc to interrupt\n›")
        case "copy-mode": terminal = terminal.replacingOccurrences(of: "\u{1f}0\u{1f}codex", with: "\u{1f}1\u{1f}codex")
        default: terminal = terminal.replacingOccurrences(of: "› ", with: "$ ")
        }
        let screen = try AgentWorkflowTerminalCapture.parse(terminal)
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.windowManager.setPaneStatesForPreview([PaneState(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "codex", state: state))])
            #expect(coordinator.agentModelInputIssue(paneID: "%1", screen: screen, provider: CodexPluginCore(), models: models) != nil)
        }
    }

    @Test("Claude's legacy composer still distinguishes an empty inverse caret from a draft", arguments: ["", "unsent draft"])
    func legacyClaudeComposer(draft: String) {
        let rule = String(repeating: "─", count: 80)
        let screen = AgentWorkflowTerminalCapture(
            ansi: [rule, "❯\u{a0}\u{1b}[7m \u{1b}[0m" + draft, rule, ""].joined(separator: "\n"),
            width: 80, height: 4, cursorX: 2, cursorY: 1, cursorVisible: false,
            bracketedPaste: nil, inCopyMode: false, foregroundCommand: "claude"
        )
        #expect(AgentWorkflowComposerInspection.readiness(screen, composer: ClaudeCodePluginCore().modelComposer, allowUnknownBracketedPaste: true) == (draft.isEmpty ? .ready : .draft))
    }

    @Test("Legacy submission keeps model-command validation", arguments: ["/hooks", "/model a\nunsafe", "/model a\r", "/model \u{1b}[201~"])
    func invalidCommand(_ command: String) throws {
        let screen = try AgentWorkflowTerminalCapture.parse(output(paste: ""))
        #expect(throws: AgentModelError.self) { try AgentModelTmuxSubmission.commands(command, paneID: "%1", capture: screen) }
    }

    @Test("Malformed mode data is not treated as an older server", arguments: ["invalid", "2", "-1"])
    func invalidMode(paste: String) {
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowTerminalCapture.parse(output(paste: paste)) }
    }

    @Test("Incomplete terminal metadata remains an error", arguments: ["", "80\u{1f}5\n", "80\u{1f}5\u{1f}?\u{1f}1\u{1f}1\u{1f}\u{1f}0\u{1f}codex\n"])
    func invalidMetadata(_ output: String) {
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowTerminalCapture.parse(output) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"] != nil), arguments: [true, false])
    func nativeServerCaptureAndInputGuard(pasteEnabled: Bool) async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await runNative(pasteEnabled: pasteEnabled) }
    }

    private func runNative(pasteEnabled: Bool) async throws {
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
        os.write(1, '\u{1b}[?2004\(pasteEnabled ? "h" : "l")\u{1b}[2J\u{1b}[4;3HTest Model low · /fixture\u{1b}[2;1H› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\u{1b}[2;3H'.encode())
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
            #expect(screen.bracketedPaste == (unknown ? nil : pasteEnabled))
            #expect(CodexPluginCore().modelSelection(lines: screen.plainLines, models: models) == .init(model: "test-model", effort: "low"))
            #expect(AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().modelComposer) == (!unknown && pasteEnabled ? .ready : .unavailable))
            if !unknown, !pasteEnabled {
                #expect(throws: AgentModelError.self) { try AgentModelTmuxSubmission.commands("/model", paneID: pane.info.paneId, capture: screen) }
                #expect(try Data(contentsOf: received).isEmpty)
            } else {
                let command = "/model test-model --reasoning=high"
                let commands = try AgentModelTmuxSubmission.commands(command, paneID: pane.info.paneId, capture: screen)
                _ = try await run(["set-buffer", "-b", "kept-buffer", "untouched"])
                // Stale foreground, cursor, dimensions and pane identity must reject
                // before creating a buffer or sending any part of the command.
                for (index, replacement) in [(0, "81"), (1, "25"), (2, "3"), (3, "2"), (7, "exited-agent")] {
                    var fields = [String(screen.width), String(screen.height), String(screen.cursorX), String(screen.cursorY), "1", unknown ? "" : "1", "0", screen.foregroundCommand]
                    fields[index] = replacement
                    let changed = try AgentWorkflowTerminalCapture.parse(fields.joined(separator: "\u{1f}") + "\n" + screen.ansi)
                    let denied = try AgentModelTmuxSubmission.commands(command, paneID: pane.info.paneId, capture: changed)
                    let result = try await service.runWorkspaceCommand(denied, target: pane.info.paneId, identity: pane.identity)
                    #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == AgentModelTmuxSubmission.rejection)
                }
                let replaced = WorkspacePaneIdentity(serverID: pane.identity.serverID, sessionID: pane.identity.sessionID, windowID: pane.identity.windowID, paneID: UUID())
                await #expect(throws: TmuxError.self) { try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: replaced) }
                _ = try await run(["copy-mode", "-t", pane.info.paneId])
                let inCopyMode = try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: pane.identity)
                #expect(inCopyMode.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == AgentModelTmuxSubmission.rejection)
                _ = try await run(["send-keys", "-X", "-t", pane.info.paneId, "cancel"])
                #expect(try Data(contentsOf: received).isEmpty)

                _ = try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: pane.identity)
                let expected = pasteEnabled ? try AgentModelTerminal.commandBytes(command) : Data((command + "\r").utf8)
                for _ in 0..<100 {
                    if try Data(contentsOf: received).count >= expected.count {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(try Data(contentsOf: received) == expected)
                let buffers = try await run(["list-buffers", "-F", "#{buffer_name}"])
                #expect(buffers.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "kept-buffer")
                let kept = try await run(["show-buffer", "-b", "kept-buffer"])
                #expect(kept.stdoutString == "untouched")
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
