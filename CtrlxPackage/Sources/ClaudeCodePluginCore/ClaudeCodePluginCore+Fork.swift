import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension ClaudeCodePluginCore {
    func forkDefaultModel(command: String, projectPath: String, environment: [String: String], unsetEnvironment: [String]) async throws -> String {
        @Dependency(ProcessRunner.self) var runner
        #if os(macOS)
            let shell = LoginShellPath.resolveUserShell()
        #else
            let shell = "/bin/sh"
        #endif
        let arguments = ClaudeForkDefaultModel.probeArguments(command: command, shell: shell, projectPath: projectPath, environment: environment, unsetEnvironment: unsetEnvironment)
        // Same metadata-only transport as model discovery: no prompt, hooks,
        // MCP servers or persisted conversation. Let the CLI merge its settings.
        let input = Data("""
        {"type":"control_request","request_id":"ctrlx-fork-initialize","request":{"subtype":"initialize"}}
        {"type":"control_request","request_id":"ctrlx-fork-defaults","request":{"subtype":"get_settings"}}

        """.utf8)
        let result = try await runner.runWithExactEnvironment("/usr/bin/env", arguments, ProcessInfo.processInfo.environment, 15, 2 * 1_024 * 1_024, input)
        guard result.isSuccess, !result.outputTruncated else {
            throw AgentForkError("Claude Code could not read the default model for Fork. Check the CLI configuration and retry.")
        }
        return try ClaudeForkDefaultModel.parse(result.stdout)
    }
}

enum ClaudeForkDefaultModel {
    static let environmentMarker = Data("\0CTRLX_FORK_MODEL\0".utf8)

    static func probeArguments(command: String, shell: String, projectPath: String, environment: [String: String], unsetEnvironment: [String]) -> [String] {
        let executable = command.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
            ? command : quote(command)
        let arguments = [
            "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
            "--no-session-persistence", "--settings", "{\"disableAllHooks\":true}",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        ]
        // Match Fork: startup files run in the target directory before Provider
        // overrides. Keep bare command names so shell aliases/functions still apply.
        let script = (unsetEnvironment.map { "unset \(quote($0))" }
            + environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(quote($0.value))" }
            + [
                "unset CLAUDECODE",
                "printf '\\000CTRLX_FORK_MODEL\\000%s\\000' \"${ANTHROPIC_MODEL-}\"",
                ([executable] + arguments.map(quote)).joined(separator: " "),
            ]).joined(separator: "\n")
        return ["-C", projectPath, shell, "-ilc", script]
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func parse(_ data: Data) throws -> String {
        // Ignore startup output and read only the model variable, not the full
        // shell environment (which can contain credentials). NUL preserves bytes.
        guard
            let marker = data.range(of: environmentMarker),
            let end = data[marker.upperBound...].firstIndex(of: 0),
            let shellModel = String(data: data[marker.upperBound..<end], encoding: .utf8) else {
            throw AgentForkError("The login shell did not return the model configuration for Fork.")
        }
        for line in String(decoding: data[(end + 1)...], as: UTF8.self).split(separator: "\n") {
            guard
                let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                message["type"] as? String == "control_response",
                let envelope = message["response"] as? [String: Any],
                envelope["request_id"] as? String == "ctrlx-fork-defaults",
                envelope["subtype"] as? String == "success",
                let response = envelope["response"] as? [String: Any],
                let effective = response["effective"] as? [String: Any] else { continue }
            let environment = effective["env"] as? [String: Any]
            // Claude applies settings.env over the launch environment. Keep the
            // selector, including opusplan; applied.model is only the current phase.
            let model = environment?["ANTHROPIC_MODEL"] as? String ?? shellModel
            if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return model
            }
            if let configured = effective["model"] as? String, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return configured
            }
            // ANTHROPIC_MODEL treats "default" literally, unlike --model.
            // With no selector, use the CLI's resolved fresh-launch model.
            if
                let applied = response["applied"] as? [String: Any],
                let resolved = applied["model"] as? String,
                !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                resolved != "default" {
                return resolved
            }
            break
        }
        throw AgentForkError("Claude Code did not return its default model for Fork. Update the CLI and retry.")
    }
}
