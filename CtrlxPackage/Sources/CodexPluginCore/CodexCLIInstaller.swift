import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Installs the CtrlX Codex plugin through Codex's own CLI
/// (`codex plugin …`), scoped to a `CODEX_HOME`. Mirrors `ClaudeCodeCLIInstaller`.
struct CodexCLIInstaller {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    static let pluginRef = "ctrlx@ctrlx"
    static let marketplaceName = "ctrlx"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CODEX_HOME": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)
        let result = try await run(["plugin", "add", Self.pluginRef], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginRef) via codex plugin add")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") && stderr.contains("add") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        try await checked(["plugin", "remove", Self.pluginRef], configRoot: configRoot)
    }

    func bundledVersion() async throws -> String {
        @Dependency(AgentPluginResourceClient.self) var resources
        return try await resources.version(marketplaceSource.appendingPathComponent("ctrlx/.codex-plugin/plugin.json"))
    }

    func reinstall(configRoot: String?) async throws -> PluginInstallStatus {
        let target = try await bundledVersion()
        try await checked(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot)
        // Confirm the CLI is reading OUR bundle before replacing its cached copy.
        let sources = try await run(["plugin", "marketplace", "list", "--json"], configRoot: configRoot, timeout: 30)
        guard sources.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: sources.exitCode, stderr: sources.stderrString)
        }
        struct Sources: Decodable {
            struct Entry: Decodable { let name: String
                let root: String
            }

            let marketplaces: [Entry]
        }
        let root: String?
        do {
            root = try JSONDecoder().decode(Sources.self, from: sources.stdout).marketplaces
                .first { $0.name == Self.marketplaceName }?.root
        } catch {
            throw AgentPluginInstallError(
                "Codex returned an unexpected response to 'plugin marketplace list --json'. "
                    + "Expected a JSON marketplace list with name and root fields. The existing plugin was not replaced."
            )
        }
        guard
            let root,
            URL(fileURLWithPath: root).resolvingSymlinksInPath() == marketplaceSource.resolvingSymlinksInPath() else {
            throw AgentPluginInstallError("The ctrlx marketplace does not point to this CtrlX app. The existing plugin was not removed.")
        }
        // Codex 0.162.1's add refreshes even a same-version cache (verified with
        // a removed hook file). Do not introduce an unnecessary uninstall gap.
        let result = try await run(["plugin", "add", Self.pluginRef], configRoot: configRoot, timeout: 120)
        guard result.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        guard !(result.stdoutString + result.stderrString).lowercased().contains("already") else {
            throw AgentPluginInstallError("This Codex CLI reported an existing installation without reinstalling it. Update Codex and retry.")
        }
        let status = await installStatus(configRoot: configRoot)
        guard status == .installed(version: target) else {
            throw AgentPluginInstallError("Expected bundled version \(target), but the CLI reported \(status).")
        }
        return status
    }

    private func checked(_ args: [String], configRoot: String?) async throws {
        let result = try await run(args, configRoot: configRoot, timeout: 120)
        guard result.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        // `-m ctrlx` scopes the listing to our marketplace, so the only
        // `ctrlx@ctrlx` row is ours.
        do {
            let result = try await run(["plugin", "list", "-m", Self.marketplaceName], configRoot: configRoot, timeout: 30)
            if result.exitCode == 127 {
                return .agentUnavailable
            }
            guard result.isSuccess else {
                if configuredInstallStatus(configRoot: configRoot) == .installed(version: nil) {
                    return .installed(version: nil)
                }
                let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .checkFailed(message: detail.isEmpty ? "Codex CLI exited with code \(result.exitCode)." : detail)
            }
            return Self.parseStatus(from: result.stdoutString)
        } catch ProcessRunnerError.executionFailed(exitCode: 127, stderr: _) {
            return .agentUnavailable
        } catch ProcessRunnerError.executableNotFound {
            return .agentUnavailable
        } catch {
            return .checkFailed(message: error.localizedDescription)
        }
    }

    /// A broken unrelated marketplace can make `codex plugin list -m ctrlx`
    /// fail even though Codex successfully added or removed our plugin. In that
    /// case, use Codex's own persisted plugin table as the narrow fallback.
    private func configuredInstallStatus(configRoot: String?) -> PluginInstallStatus {
        let codexHome = configRoot
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? CodexScanner.defaultCodexHome()
        let configURL = codexHome.appendingPathComponent("config.toml")
        let toml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return Self.parseConfiguredStatus(from: toml)
    }

    static func parseConfiguredStatus(from toml: String) -> PluginInstallStatus {
        let section = #"[plugins."ctrlx@ctrlx"]"#
        let isConfigured = toml.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == section }
        return isConfigured ? .installed(version: nil) : .notInstalled
    }

    /// Parses `codex plugin list -m ctrlx` output. Only the `ctrlx@ctrlx`
    /// row's STATUS column is authoritative — `"not installed"` ⇒ `.notInstalled`,
    /// `"installed"` ⇒ `.installed`. The marketplace header line (`` Marketplace
    /// `ctrlx` ``) and the on-disk plugin path must NOT be mistaken for an
    /// install. Version is the first dot-bearing numeric token on the row, if any.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        for line in listing.split(separator: "\n") where line.split(whereSeparator: \.isWhitespace).first == Substring(pluginRef) {
            let lower = line.lowercased()
            if lower.contains("not installed") {
                return .notInstalled
            }
            guard lower.contains("installed") else { continue }
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        if listing.contains("PLUGIN"), listing.contains("STATUS") {
            return .notInstalled
        }
        if listing.trimmingCharacters(in: .whitespacesAndNewlines) == "No plugins found in marketplace `ctrlx`." {
            return .notInstalled
        }
        return .checkFailed(message: "Codex returned an unrecognized plugin list.")
    }
}
