import CtrlxCommon
import Foundation
import CtrlxPluginProtocol

/// Installs the CtrlX Codex plugin through Codex's own CLI
/// (`codex plugin …`), scoped to a `CODEX_HOME`. Mirrors `ClaudeCodeCLIInstaller`.
struct CodexCLIInstaller: Sendable {
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
        _ = try await run(["plugin", "remove", Self.pluginRef], configRoot: configRoot, timeout: 60)
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        // `-m ctrlx` scopes the listing to our marketplace, so the only
        // `ctrlx@ctrlx` row is ours.
        guard
            let result = try? await run(
                ["plugin", "list", "-m", Self.marketplaceName], configRoot: configRoot, timeout: 30
            ) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return configuredInstallStatus(configRoot: configRoot) }
        return Self.parseStatus(from: result.stdoutString)
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
        for line in listing.split(separator: "\n") where line.contains(pluginRef) {
            let lower = line.lowercased()
            if lower.contains("not installed") { return .notInstalled }
            guard lower.contains("installed") else { continue }
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
