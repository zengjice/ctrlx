import CodexPluginCore
import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentHookTrustTmuxCompatibilityTests {
    private let core = CodexPluginCore()
    private let pending = ["Hooks", "Lifecycle hooks from config and enabled plugins.", "Event Active/Installed", "› UserPromptSubmit 1/1", "t trust all · enter review · esc close"]
    private let trusted = ["Hooks", "Lifecycle hooks from config and enabled plugins.", "Event Active/Installed", "› UserPromptSubmit 1/1", "enter details · esc close"]
    private let details = ["UserPromptSubmit hooks", "Turn hooks on or off. Your changes are saved automatically.", "› [x] 1 CtrlX", "Source Plugin - ctrlx@ctrlx", "Command /fixture/ctrlx-hook", "Mode Sync", "Event UserPromptSubmit", "Trust Trusted", "space/enter toggle · esc back"]

    private func capture(_ lines: [String], paste: String = "") throws -> AgentWorkflowTerminalCapture {
        try AgentWorkflowTerminalCapture.parse(["80", "24", "2", "1", "1", paste, "0", "codex"].joined(separator: "\u{1f}") + "\n" + lines.joined(separator: "\n"))
    }

    @Test("Unknown panels and changed selections never receive approval keys", arguments: ["", "1"])
    func panelChecks(paste: String) throws {
        for lines in [trusted, ["Unknown dialog"]] {
            #expect(throws: AgentHookTrustError.self) {
                try AgentHookTrustTmuxSubmission.commands(.trustAll, paneID: "%1", capture: capture(lines, paste: paste), provider: core)
            }
        }
        #expect(throws: AgentHookTrustError.self) {
            try AgentHookTrustTmuxSubmission.commands(.close, paneID: "%1", capture: capture(["Unknown dialog"], paste: paste), provider: core)
        }
        #expect(throws: AgentHookTrustError.self) {
            try AgentHookTrustTmuxSubmission.commands(.press(.toggle, screen: details + ["changed"]), paneID: "%1", capture: capture(details, paste: paste), provider: core)
        }
        #expect(throws: AgentHookTrustError.self) {
            try AgentHookTrustTmuxSubmission.commands(.press(.toggle, screen: trusted), paneID: "%1", capture: capture(trusted, paste: paste), provider: core)
        }
    }

    @Test("Explicitly disabled paste mode blocks opening and all panel actions")
    func disabledMode() throws {
        for action: AgentHookTrustAction in [.open, .trustAll, .close, .press(.toggle, screen: details)] {
            #expect(throws: AgentHookTrustError.self) {
                try AgentHookTrustTmuxSubmission.commands(action, paneID: "%1", capture: capture(pending, paste: "0"), provider: core)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"] != nil), arguments: [true, false])
    func nativeServerCaptureAndHookKeys(pasteEnabled: Bool) async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await runNative(pasteEnabled: pasteEnabled) }
    }

    private func runNative(pasteEnabled: Bool) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"])
        let unknown = ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXPECT_UNKNOWN"] == "1"
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-hook-mode-\(UUID())")
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
        os.write(1, '\u{1b}[?2004\(pasteEnabled ? "h" : "l")\u{1b}[2J\u{1b}[2;1H› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\u{1b}[2;3H'.encode())
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
                if screen.plainLines.contains(where: { $0.contains("Ask Codex") }), FileManager.default.fileExists(atPath: received.path) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
                screen = try await service.captureAgentTerminal(paneID: pane.info.paneId, identity: pane.identity)
            }
            #expect(screen.bracketedPaste == (unknown ? nil : pasteEnabled))
            if !unknown, !pasteEnabled {
                #expect(throws: AgentHookTrustError.self) {
                    try AgentHookTrustTmuxSubmission.commands(.open, paneID: pane.info.paneId, capture: screen, provider: core)
                }
                #expect(try Data(contentsOf: received).isEmpty)
            } else {
                let commands = try AgentHookTrustTmuxSubmission.commands(.open, paneID: pane.info.paneId, capture: screen, provider: core)
                _ = try await run(["set-buffer", "-b", "kept-buffer", "untouched"])
                for (index, replacement) in [(0, "81"), (1, "25"), (2, "3"), (3, "2"), (7, "exited-agent")] {
                    var fields = [String(screen.width), String(screen.height), String(screen.cursorX), String(screen.cursorY), "1", unknown ? "" : "1", "0", screen.foregroundCommand]
                    fields[index] = replacement
                    let changed = try AgentWorkflowTerminalCapture.parse(fields.joined(separator: "\u{1f}") + "\n" + screen.ansi)
                    let denied = try AgentHookTrustTmuxSubmission.commands(.open, paneID: pane.info.paneId, capture: changed, provider: core)
                    let result = try await service.runWorkspaceCommand(denied, target: pane.info.paneId, identity: pane.identity)
                    #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == AgentHookTrustTmuxSubmission.rejection)
                }
                _ = try await run(["copy-mode", "-t", pane.info.paneId])
                let inCopyMode = try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: pane.identity)
                #expect(inCopyMode.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == AgentHookTrustTmuxSubmission.rejection)
                _ = try await run(["send-keys", "-X", "-t", pane.info.paneId, "cancel"])
                var staleIdentity = pane.identity
                staleIdentity.paneID = UUID()
                await #expect(throws: TmuxError.self) {
                    try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: staleIdentity)
                }
                #expect(try Data(contentsOf: received).isEmpty)

                _ = try await service.runWorkspaceCommand(commands, target: pane.info.paneId, identity: pane.identity)
                var expected = Data((pasteEnabled ? "\u{1b}[200~/hooks\u{1b}[201~\r" : "/hooks\r").utf8)
                try await waitForBytes(expected, at: received)
                let panels: [(AgentHookTrustAction, [String], String)] = [
                    (.trustAll, pending, "t"), (.close, trusted, "\u{1b}"),
                    (.press(.next, screen: trusted), trusted, "\u{1b}[B"),
                    (.press(.details, screen: trusted), trusted, "\r"),
                    (.press(.toggle, screen: details), details, " "),
                    (.press(.back, screen: details), details, "\u{1b}"),
                ]
                for (action, lines, bytes) in panels {
                    let panel = AgentWorkflowTerminalCapture(ansi: lines.joined(separator: "\n"), width: screen.width, height: screen.height, cursorX: screen.cursorX, cursorY: screen.cursorY, cursorVisible: screen.cursorVisible, bracketedPaste: screen.bracketedPaste, inCopyMode: false, foregroundCommand: screen.foregroundCommand)
                    let input = try AgentHookTrustTmuxSubmission.commands(action, paneID: pane.info.paneId, capture: panel, provider: core)
                    _ = try await service.runWorkspaceCommand(input, target: pane.info.paneId, identity: pane.identity)
                    expected.append(contentsOf: bytes.utf8)
                    try await waitForBytes(expected, at: received)
                }
                #expect(try await run(["list-buffers", "-F", "#{buffer_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "kept-buffer")
                #expect(try await run(["show-buffer", "-b", "kept-buffer"]).stdoutString == "untouched")
            }
        } catch {
            _ = try? await run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }

    private func waitForBytes(_ expected: Data, at url: URL) async throws {
        for _ in 0..<100 {
            if try Data(contentsOf: url).count >= expected.count {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try Data(contentsOf: url) == expected)
    }
}
