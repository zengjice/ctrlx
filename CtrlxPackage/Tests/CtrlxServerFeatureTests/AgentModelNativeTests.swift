import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing

/// Opt-in acceptance against the dedicated, no-network CLI fixtures only.
/// Never attaches to the default tmux server or sends a conversational prompt.
struct AgentModelNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_MODEL_PROBE_SOCKET"] != nil))
    func nativeSessionOnlySwitches() async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await runNative() }
    }

    private func runNative() async throws {
        let socket = try #require(ProcessInfo.processInfo.environment["CTRLX_MODEL_PROBE_SOCKET"])
        #expect(socket.hasSuffix("/.build-local/model-switch-probe/tmux.sock"))
        guard socket.hasSuffix("/.build-local/model-switch-probe/tmux.sock") else { return }
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
        @Dependency(ProcessRunner.self) var runner
        let processRunner = runner
        for (name, provider, executable, version) in [
            ("codex", CodexPluginCore() as any AgentModelProviding, "/opt/homebrew/bin/codex", "codex-cli 0.164.0"),
            ("claude", ClaudeCodePluginCore() as any AgentModelProviding, "/opt/homebrew/bin/claude", "2.1.310 (Claude Code)"),
        ] {
            let before = try await processRunner.run("/opt/homebrew/bin/tmux", ["-S", socket, "display-message", "-p", "-t", name, "#{pane_current_path}"], nil, 5)
            #expect(before.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == directory.path)
            guard before.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == directory.path else { return }
            var environment = ProcessInfo.processInfo.environment
            for key in Array(environment.keys) where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key == "CLAUDECODE" {
                environment[key] = nil
            }
            environment["CODEX_HOME"] = directory.appendingPathComponent("codex").path
            environment["CLAUDE_CONFIG_DIR"] = directory.appendingPathComponent("claude").path
            environment["ANTHROPIC_API_KEY"] = "ctrlx-no-network"
            environment["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:9"
            let context = AgentModelContext(invocation: .init(executable: executable, arguments: [], version: version), environment: environment, directory: directory.path)
            let models = try await provider.modelOptions(context)
            let model = try #require(models.first { name == "codex" ? $0.id == "gpt-6.1-sol" : $0.name == "Sonnet" })
            let terminal = AgentModelTerminal(read: {
                let capture = try await processRunner.run("/opt/homebrew/bin/tmux", ["-S", socket, "capture-pane", "-p", "-t", name], nil, 5)
                return capture.stdoutString.components(separatedBy: "\n")
            }, submit: { command in
                let bytes = try AgentModelTerminal.commandBytes(command)
                let result = try await processRunner.run("/opt/homebrew/bin/tmux", ["-S", socket, "send-keys", "-t", name, "-H"] + bytes.map { String(format: "%02x", $0) }, nil, 5)
                #expect(result.isSuccess)
            }, send: { keys in
                for key in keys {
                    if case let .delay(milliseconds) = key {
                        try await Task.sleep(for: .milliseconds(milliseconds))
                        continue
                    }
                    let args: [String]
                    if case let .text(value) = key {
                        args = ["-l", "--", value]
                    } else {
                        args = [key.tmuxKeyName]
                    }
                    let result = try await processRunner.run("/opt/homebrew/bin/tmux", ["-S", socket, "send-keys", "-t", name] + args, nil, 5)
                    #expect(result.isSuccess)
                }
            })
            for effort in ["low", "high"] {
                let selection = AgentModelSelection(model: model.id, effort: effort)
                let confirmed = try await provider.selectModel(selection, models: models, terminal: terminal)
                #expect(confirmed == selection)
            }
        }
    }
}
