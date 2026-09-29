import ConcurrencyExtras
import CtrlxCommon
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWindowTmuxTests {
    @Test("Agent launch targets only the returned pane and preserves per-window env/cwd/name")
    func launchArguments() async throws {
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                calls.withValue { $0.append(arguments) }
                return ProcessResult(exitCode: 0, stdout: Data((arguments.contains("new-window") ? "%42:9\n" : "").utf8), stderr: Data())
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/test/tmux")
            let pane = try await tmux.newWindow(
                sessionName: "existing", workingDirectory: "/repo with 'quotes'",
                windowName: "codex", runCommand: "codex '-c' 'otel.log_user_prompt=false'",
                extraEnvironment: ["CODEX_HOME=/Host/config"]
            )
            #expect(pane == "%42")
        }
        let creation = try #require(calls.value.first(where: { $0.contains("new-window") }))
        #expect(creation.contains("=existing:"))
        #expect(creation.contains("/repo with 'quotes'"))
        #expect(creation.contains("CODEX_HOME=/Host/config"))
        #expect(creation.contains("codex"))
        #expect(!creation.contains("new-session"))
        #expect(calls.value.filter { $0.contains("send-keys") } == [
            ["send-keys", "-t", "%42", "codex '-c' 'otel.log_user_prompt=false'", "Enter"],
        ])
        #expect(!calls.value.contains { $0.contains("resize-window") || $0.contains("split-window") })
    }

    @Test("Plain Terminal still sends no startup input")
    func plainTerminal() async throws {
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                calls.withValue { $0.append(arguments) }
                return ProcessResult(exitCode: 0, stdout: Data((arguments.contains("new-window") ? "%42:9\n" : "").utf8), stderr: Data())
            }
        } operation: {
            _ = try await TmuxService(tmuxPath: "/test/tmux").newWindow(sessionName: "existing")
        }
        #expect(!calls.value.contains { $0.contains("send-keys") })
        #expect(calls.value.contains { $0.contains("rename-window") && $0.contains("terminal 1") })
    }

    @Test("Creation failure never injects input; send failure is reported, not retried", arguments: ["new-window", "send-keys"])
    func failures(failingCommand: String) async throws {
        let calls = LockIsolated<[[String]]>([])
        await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                calls.withValue { $0.append(arguments) }
                return ProcessResult(
                    exitCode: arguments.contains(failingCommand) ? 1 : 0,
                    stdout: Data((arguments.contains("new-window") ? "%42:9\n" : "").utf8),
                    stderr: Data("fixture failure".utf8)
                )
            }
        } operation: {
            await #expect(throws: TmuxError.self) {
                try await TmuxService(tmuxPath: "/test/tmux").newWindow(sessionName: "existing", windowName: "codex", runCommand: "codex")
            }
        }
        #expect(calls.value.filter { $0.contains("new-window") }.count == 1)
        #expect(calls.value.filter { $0.contains("send-keys") }.count == (failingCommand == "new-window" ? 0 : 1))
    }

    @Test("Agent windows retain the opted-in editor override")
    func editorOverride() async throws {
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                calls.withValue { $0.append(arguments) }
                return ProcessResult(exitCode: 0, stdout: Data((arguments.contains("new-window") ? "%42:9\n" : "").utf8), stderr: Data())
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/test/tmux")
            tmux.editorCLIPath = "/Apps/CtrlX.app/Contents/MacOS/CtrlXCLI"
            tmux.overrideVisualInShellPanes = true
            _ = try await tmux.newWindow(sessionName: "existing", windowName: "codex", runCommand: "codex")
        }
        let send = try #require(calls.value.first(where: { $0.contains("send-keys") }))
        #expect(send[3].contains("VISUAL="))
        #expect(send[3].hasSuffix("; codex"))
        #expect(calls.value.filter { $0.contains("send-keys") }.count == 1)
    }

    @Test("Isolated live tmux: new Agent window keeps the original pane, cwd and launch env")
    func liveWindow() async throws {
        let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tab-\(UUID().uuidString.prefix(8))")
        let directory = root.appendingPathComponent("repo with space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("tmux.sock").path
        let runner = ProcessRunner.liveValue

        do {
            try await withDependencies {
                $0[ProcessRunner.self] = runner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                // An empty, isolated ZDOTDIR: no user rc files or shell history.
                tmux.zdotDirOverride = root.path
                let original = try await tmux.createSession(baseName: "agent-test", width: 220, height: 24, workingDirectory: root.path)
                let pane = try await tmux.newWindow(
                    sessionName: original.sessionName, workingDirectory: directory.path,
                    windowName: "test-agent", runCommand: #"printf 'AGENT_PROBE[%s][%s]\n' "$CTRLX_AGENT_TEST" "$PWD""#,
                    extraEnvironment: ["CTRLX_AGENT_TEST=ready"]
                )
                var screen = ""
                for _ in 0..<30 {
                    screen = try await tmux.capturePaneText(pane)
                    if screen.contains("AGENT_PROBE[ready][") { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(screen.contains("AGENT_PROBE[ready]["))
                #expect(screen.contains("repo with space]"))
                let refreshed = await tmux.refreshPanes()
                #expect(refreshed.count == 2)
                #expect(refreshed.contains { $0.paneId == original.paneId })
                #expect(refreshed.contains { $0.paneId == pane && $0.sessionName == original.sessionName })
                #expect(pane != original.paneId)
                let originalScreen = try await tmux.capturePaneText(original.paneId)
                #expect(!originalScreen.contains("AGENT_PROBE"))
            }
        } catch {
            _ = try? await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, nil)
            throw error
        }
        let cleanup = try await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, nil)
        #expect(cleanup.isSuccess)
    }
}
