import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Installs the CtrlX Claude Code plugin through Claude's own CLI
/// (`claude plugin …`), scoped to a `CLAUDE_CONFIG_DIR`. The app never edits
/// Claude's settings files directly (spec §1–2). All invocations are wrapped in
/// `/usr/bin/env <command> …` so PATH resolution works and a missing binary
/// surfaces as exit 127 → `.agentUnavailable`.
struct ClaudeCodeCLIInstaller {
    let processRunner: ProcessRunner
    /// The configured claude command (full path or bare `claude`).
    let command: String
    /// Bundled marketplace dir (`<app>/Contents/Resources/plugin`).
    let marketplaceSource: URL

    static let pluginName = "ctrlx"
    /// Fully-qualified plugin id (`<name>@<marketplace>`) as it appears in
    /// `claude plugin list --json`. Matching this — not a bare "ctrlx"
    /// substring — scopes status detection to our plugin.
    static let pluginRef = "ctrlx@ctrlx"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CLAUDE_CONFIG_DIR": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        // Marketplace add is idempotent; tolerate "already registered".
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)

        let result = try await run(["plugin", "install", Self.pluginName, "--scope", "user"], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginName) via claude plugin install")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") && stderr.contains("install") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        try await checked(["plugin", "uninstall", Self.pluginRef, "--scope", "user", "--keep-data"], configRoot: configRoot)
    }

    func bundledVersion() async throws -> String {
        @Dependency(AgentPluginResourceClient.self) var resources
        return try await resources.version(marketplaceSource.appendingPathComponent("ctrlx/.claude-plugin/plugin.json"))
    }

    func reinstall(configRoot: String?) async throws -> PluginInstallStatus {
        let target = try await bundledVersion()
        try await checked(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot)
        let sources = try await run(["plugin", "marketplace", "list", "--json"], configRoot: configRoot, timeout: 30)
        struct Source: Decodable { let name: String
            let path: String?
        }
        let root = try JSONDecoder().decode([Source].self, from: sources.stdout)
            .first { $0.name == "ctrlx" }?.path
        guard
            sources.isSuccess, let root,
            URL(fileURLWithPath: root).resolvingSymlinksInPath() == marketplaceSource.resolvingSymlinksInPath() else {
            throw AgentPluginInstallError("The ctrlx marketplace does not point to this CtrlX app. The existing plugin was not removed.")
        }
        try await checked(["plugin", "marketplace", "update", "ctrlx"], configRoot: configRoot)
        let prior = await installStatus(configRoot: configRoot)
        switch prior {
        case .installed: try await uninstall(configRoot: configRoot)
        case .notInstalled: break
        case .agentUnavailable,
             .checkFailed:
            throw AgentPluginInstallError("Cannot verify the existing CtrlX plugin: \(prior). Nothing was removed.")
        }
        do {
            try await checked(["plugin", "install", Self.pluginRef, "--scope", "user"], configRoot: configRoot)
            let status = await installStatus(configRoot: configRoot)
            guard status == .installed(version: target) else {
                throw AgentPluginInstallError("Expected bundled version \(target), but the CLI reported \(status).")
            }
            return status
        } catch {
            throw AgentPluginInstallError("CtrlX plugin reinstall did not finish: \(error.localizedDescription) Retry installation in this config folder; the previous copy may have been removed.")
        }
    }

    private func checked(_ args: [String], configRoot: String?) async throws {
        let result = try await run(args, configRoot: configRoot, timeout: 120)
        guard result.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        // `--json` yields a machine-readable array of installed plugins, so we can
        // match our exact id instead of grepping for a "ctrlx" substring (which
        // a marketplace header or another plugin could spuriously satisfy).
        do {
            let result = try await run(["plugin", "list", "--json"], configRoot: configRoot, timeout: 30)
            if result.exitCode == 127 { return .agentUnavailable }
            guard result.isSuccess else {
                let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .checkFailed(message: detail.isEmpty ? "Claude Code CLI exited with code \(result.exitCode)." : detail)
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

    /// Parses `claude plugin list --json` output (an array of installed-plugin
    /// objects). Our plugin is the entry whose `id` equals `ctrlx@ctrlx`;
    /// its `version` field is authoritative. `claude plugin list` lists only
    /// *installed* plugins. Only the user-scoped entry belongs to this installer;
    /// a project/local install must not mask a missing user-scoped copy.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        guard let entries = try? JSONDecoder().decode([PluginListEntry].self, from: Data(listing.utf8)) else {
            return .checkFailed(message: "Claude Code returned an invalid plugin list.")
        }
        guard let entry = entries.first(where: { $0.id == pluginRef && ($0.scope == nil || $0.scope == "user") }) else { return .notInstalled }
        return .installed(version: entry.version)
    }

    /// Minimal projection of a `claude plugin list --json` entry; unknown keys
    /// (scope, enabled, installPath, …) are ignored by the decoder.
    private struct PluginListEntry: Decodable {
        let id: String
        let version: String?
        let scope: String?
    }
}
