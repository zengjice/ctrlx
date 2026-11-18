import CodexPluginCore
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing

/// Opt-in: scripts/tests/run_codex_model_refresh.py owns the private CLI and loopback catalog.
struct CodexModelRefreshNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_MODEL_REFRESH_FIXTURE"] != nil))
    func nativeCatalogRefresh() async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            try await runNative()
        }
    }

    private func runNative() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CTRLX_MODEL_REFRESH_FIXTURE"])
        guard path.hasPrefix("/tmp/ctrlx-model-refresh-"), !path.contains("..") else {
            Issue.record("Expected the private native fixture")
            return
        }
        let root = URL(fileURLWithPath: path)
        let environment = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("environment.json")))
        let runner = ProcessRunner.liveValue
        let tmux: @Sendable ([String]) async throws -> ProcessResult = { args in
            let result = try await runner.runWithExactEnvironment("/opt/homebrew/bin/tmux", ["-S", path + "/tmux.sock"] + args, environment, 5, 1_024 * 1_024, nil)
            guard result.isSuccess else { throw AgentModelError("Native fixture tmux failed: \(result.stderrString)") }
            return result
        }
        let config = root.appendingPathComponent("home/.codex/config.toml")
        let beforeConfig = try Data(contentsOf: config)
        let beforePID = try await tmux(["display-message", "-p", "-t", "probe:0.0", "#{pane_pid}"]).stdoutString
        actor Commands {
            var values: [String] = []
            func add(_ command: String) {
                values.append(command)
            }
        }
        let commands = Commands()
        do {
            let core = CodexPluginCore()
            let models = try await core.modelOptions(.init(invocation: .init(executable: "/opt/homebrew/bin/codex", arguments: [], version: "codex-cli fixture"), environment: environment, directory: path))
            #expect(models.contains { $0.id == "gpt-6.2-sol" })
            let result = try await core.selectModel(.init(model: "gpt-6.2-sol", effort: "high"), models: models, terminal: .init(read: {
                try await tmux(["capture-pane", "-p", "-t", "probe:0.0"]).stdoutString.components(separatedBy: "\n")
            }, submit: { command in
                await commands.add(command)
                let bytes = try AgentModelTerminal.commandBytes(command)
                _ = try await tmux(["send-keys", "-t", "probe:0.0", "-H"] + bytes.map { String(format: "%02x", $0) })
            }, send: { keys in
                #expect(keys == [.escape])
                _ = try await tmux(["send-keys", "-t", "probe:0.0", "Escape"])
            }))
            #expect(result == .init(model: "gpt-6.2-sol", effort: "high"))
        }
        #expect(await commands.values == ["/model gpt-6.2-sol --reasoning=high", "/model", "/model gpt-6.2-sol --reasoning=high"])
        #expect(try Data(contentsOf: config) == beforeConfig)
        #expect(try await tmux(["display-message", "-p", "-t", "probe:0.0", "#{pane_pid}"]).stdoutString == beforePID)
        let screen = try await tmux(["capture-pane", "-p", "-t", "probe:0.0"]).stdoutString
        #expect(screen.contains("Model 'gpt-6.2-sol' is unavailable"))
        #expect(screen.contains("Model changed to gpt-6.2-sol high for this session only"))
        try screen.write(to: root.appendingPathComponent("confirmed.txt"), atomically: true, encoding: .utf8)
    }
}
