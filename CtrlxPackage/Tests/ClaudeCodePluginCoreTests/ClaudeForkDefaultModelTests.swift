import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeForkDefaultModelTests {
    static func response(model: String?, shellModel: String = "", environmentModel: String? = nil, appliedModel: String? = "claude-sonnet-5-5") throws -> Data {
        var effective: [String: Any] = [:]
        effective["model"] = model
        if let environmentModel {
            effective["env"] = ["ANTHROPIC_MODEL": environmentModel]
        }
        var applied: [String: Any] = ["effort": "high"]
        applied["model"] = appliedModel
        let message: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": "ctrlx-fork-defaults", "response": [
                "effective": effective, "applied": applied,
            ]],
        ]
        return try ClaudeForkDefaultModel.environmentMarker + Data((shellModel + "\0").utf8) + (JSONSerialization.data(withJSONObject: message))
    }

    @Test("Fork reads the target CLI model without a prompt or conversation", arguments: [false, true])
    func defaultModel(official: Bool) async throws {
        let id = UUID().uuidString
        let root = "/source/claude"
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, _, _ in root }
            $0[ProcessRunner.self].runWithExactEnvironment = { executable, arguments, _, timeout, limit, input in
                #expect(executable == "/usr/bin/env")
                #expect(Array(arguments.prefix(2)) == ["-C", "/target repo"])
                #expect(arguments[3] == "-ilc")
                let script = try #require(arguments.last)
                #expect(script.contains("claude '-p'"))
                #expect(script.contains("--no-session-persistence"))
                #expect(script.contains("{\"disableAllHooks\":true}"))
                #expect(script.contains("--strict-mcp-config") && script.contains("{\"mcpServers\":{}}"))
                #expect(!script.contains("--resume") && !script.contains(id))
                #expect(script.contains("export CLAUDE_CONFIG_DIR='/source/claude'"))
                #expect(script.contains("unset CLAUDECODE"))
                if official {
                    #expect(script.contains("unset 'ANTHROPIC_MODEL'") && script.contains("unset 'ANTHROPIC_API_KEY'"))
                }
                #expect(timeout == 15 && limit == 2 * 1_024 * 1_024)
                let requests = try #require(input).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
                #expect(requests.count == 2)
                #expect(requests.allSatisfy { $0?["type"] as? String == "control_request" })
                return try ProcessResult(exitCode: 0, stdout: Self.response(model: "target-model"), stderr: Data())
            }
        } operation: {
            let launch = try await ClaudeCodePluginCore().commandForFork(
                sessionID: id, projectPath: "/target repo", targetProviderID: official ? ClaudeCodeSettings.builtInProviderID : nil
            )
            #expect(launch.command.args == ["--resume", id, "--fork-session"])
            #expect(launch.command.env["ANTHROPIC_MODEL"] == "target-model")
            #expect(launch.command.env["CLAUDE_CONFIG_DIR"] == root)
        }
    }

    @Test("Only the matching successful settings response supplies a model", arguments: [
        "{}", "{\"type\":\"system\",\"model\":\"old-model\"}",
        "{\"type\":\"control_response\",\"response\":{\"request_id\":\"other\",\"subtype\":\"success\",\"response\":{\"applied\":{\"model\":\"old-model\"}}}}",
        "{\"type\":\"control_response\",\"response\":{\"request_id\":\"ctrlx-fork-defaults\",\"subtype\":\"error\",\"error\":\"unsupported\"}}",
    ])
    func invalidResponse(value: String) {
        #expect(throws: AgentForkError.self) { try ClaudeForkDefaultModel.parse(ClaudeForkDefaultModel.environmentMarker + Data(("\0" + value).utf8)) }
    }

    @Test("Fork leaves the shell wrapper's explicit model as the only model argument", arguments: ["haiku", "opusplan"])
    func wrapperModel(model: String) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("ctrlx-fork-wrapper-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try """
        HISTFILE=/dev/null
        SAVEHIST=0
        claude() { printf '%s\\n' "$ANTHROPIC_MODEL" --model \(model) "$@"; }
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let id = UUID().uuidString
        let launch = try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, _, _ in root.path }
            // get_settings reports the settings file model even when a wrapper
            // supplies --model. It must remain a lower-priority default.
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                try ProcessResult(exitCode: 0, stdout: Self.response(model: "sonnet"), stderr: Data())
            }
        } operation: {
            try await ClaudeCodePluginCore().commandForFork(sessionID: id, projectPath: root.path)
        }
        let defaultModel = try #require(launch.command.env["ANTHROPIC_MODEL"])
        let result = try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            try await ProcessRunner.liveValue.runWithExactEnvironment(
                "/usr/bin/env", ["-C", root.path, "/bin/zsh", "-ilc", "export ANTHROPIC_MODEL=\"$1\"; shift; claude \"$@\"", "fork", defaultModel] + launch.command.args,
                ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"], 15, 100_000, nil
            )
        }
        #expect(result.isSuccess)
        #expect(result.stdoutString.split(separator: "\n").map(String.init) == ["sonnet", "--model", model, "--resume", id, "--fork-session"])
    }

    @Test("Fork retains model selectors and CLI environment precedence", arguments: ["opusplan", "opusplan[1m]", "haiku"])
    func selector(model: String) throws {
        #expect(try ClaudeForkDefaultModel.parse(Self.response(model: model)) == model)
        #expect(try ClaudeForkDefaultModel.parse(Self.response(model: "sonnet", shellModel: model)) == model)
        #expect(try ClaudeForkDefaultModel.parse(Self.response(model: "sonnet", shellModel: "haiku", environmentModel: model)) == model)
        #expect(try ClaudeForkDefaultModel.parse(Self.response(model: model, shellModel: "haiku", environmentModel: "")) == model)
    }

    @Test("Unconfigured Fork uses the CLI's actual default model", arguments: ["claude-opus-5-5", "claude-sonnet-5-5"], [false, true])
    func unconfiguredModel(model: String, official: Bool) async throws {
        let response = try Self.response(model: nil, appliedModel: model)
        #expect(try ClaudeForkDefaultModel.parse(response) == model)
        let id = UUID().uuidString
        let launch = try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, _, _ in "/source/claude" }
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                ProcessResult(exitCode: 0, stdout: response, stderr: Data())
            }
        } operation: {
            try await ClaudeCodePluginCore().commandForFork(
                sessionID: id, projectPath: "/target repo", targetProviderID: official ? ClaudeCodeSettings.builtInProviderID : nil
            )
        }
        #expect(launch.command.env["ANTHROPIC_MODEL"] == model)
        #expect(launch.command.args == ["--resume", id, "--fork-session"])
    }

    @Test("Missing or invalid native defaults fail before Fork launch", arguments: [nil, "", "  ", "default"] as [String?])
    func missingDefault(model: String?) async throws {
        let response = try Self.response(model: nil, appliedModel: model)
        #expect(throws: AgentForkError.self) { try ClaudeForkDefaultModel.parse(response) }
        await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, _, _ in "/source/claude" }
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                ProcessResult(exitCode: 0, stdout: response, stderr: Data())
            }
        } operation: {
            await #expect(throws: AgentForkError.self) {
                try await ClaudeCodePluginCore().commandForFork(sessionID: UUID().uuidString, projectPath: "/target repo")
            }
        }
    }

    @Test("The probe loads zsh startup variables in the destination before Provider overrides", arguments: [false, true])
    func loginShell(official: Bool) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("ctrlx-fork-shell-\(UUID().uuidString)")
        let project = root.appendingPathComponent("target repo")
        try files.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try """
        HISTFILE=/dev/null
        SAVEHIST=0
        printf 'startup noise without a newline'
        export ANTHROPIC_MODEL=haiku
        export CLAUDE_CONFIG_DIR='/wrong root from rc'
        export CLAUDECODE=1
        export FORK_STARTUP_DIRECTORY="$PWD"
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("metadata probe")
        try """
        #!/bin/sh
        [ "$PWD" = "$FORK_STARTUP_DIRECTORY" ] || exit 11
        [ "$CLAUDE_CONFIG_DIR" = '/expected config' ] || exit 12
        [ -z "${CLAUDECODE-}" ] || exit 13
        cat >/dev/null
        printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"ctrlx-fork-defaults","response":{"effective":{"model":"opusplan"},"applied":{"model":"claude-sonnet-5-5"}}}}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let arguments = ClaudeForkDefaultModel.probeArguments(
            command: executable.path, shell: "/bin/zsh", projectPath: project.path,
            environment: ["CLAUDE_CONFIG_DIR": "/expected config"],
            unsetEnvironment: official ? ["ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR"] : []
        )
        let result = try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            try await ProcessRunner.liveValue.runWithExactEnvironment(
                "/usr/bin/env", arguments, ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "ANTHROPIC_MODEL": "sonnet"],
                15, 100_000, Data()
            )
        }
        #expect(result.isSuccess)
        #expect(try ClaudeForkDefaultModel.parse(result.stdout) == (official ? "opusplan" : "haiku"))
    }

    @Test("Failed or truncated probes fail before launch", arguments: [false, true])
    func failedProbe(truncated: Bool) async {
        await withDependencies {
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                try ProcessResult(exitCode: truncated ? 0 : 1, stdout: Self.response(model: "target"), stderr: Data(), outputTruncated: truncated)
            }
        } operation: {
            await #expect(throws: AgentForkError.self) {
                try await ClaudeCodePluginCore().forkDefaultModel(command: "claude", projectPath: "/target", environment: [:], unsetEnvironment: [])
            }
        }
    }
}
