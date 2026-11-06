import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Skills and lifecycle hooks are independently versioned native plugins.
/// All changes go through the Agent CLI, scoped to its configuration root.
struct ClaudeCodeCLIInstaller {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    static let pluginName = "ctrlx"
    static let pluginRef = "ctrlx@ctrlx"
    static let hooksRef = "ctrlx-hooks@ctrlx"
    static let marketplaceName = "ctrlx"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CLAUDE_CONFIG_DIR": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval = 120) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        let (_, changed) = try await synchronize(configRoot: configRoot)
        return changed ? .installed(message: "Installed CtrlX skills and lifecycle hooks.") : .alreadyInstalled
    }

    func reinstall(configRoot: String?) async throws -> PluginInstallStatus {
        try await synchronize(configRoot: configRoot).0
    }

    private func bundledVersions() async throws -> [(String, String)] {
        @Dependency(AgentPluginResourceClient.self) var resources
        return try [
            (Self.pluginRef, await resources.version(marketplaceSource.appendingPathComponent("ctrlx/.claude-plugin/plugin.json"))),
            (Self.hooksRef, await resources.version(marketplaceSource.appendingPathComponent("ctrlx-hooks/.claude-plugin/plugin.json"))),
        ]
    }

    func bundledVersion() async throws -> String {
        let versions = try await bundledVersions()
        guard let value = AgentPluginResourceClient.combinedVersion(skills: versions[0].1, hooks: versions[1].1) else {
            throw AgentPluginInstallError("The bundled CtrlX plugin versions are invalid.")
        }
        return value
    }

    private func synchronize(configRoot: String?) async throws -> (PluginInstallStatus, Bool) {
        let targets = try await bundledVersions()
        // An already registered marketplace may reject add. Verify its actual
        // source before modifying either cached plugin.
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)
        try await verifyMarketplace(configRoot: configRoot)
        try await checked(["plugin", "marketplace", "update", "ctrlx"], configRoot: configRoot)
        let before = try await installedComponents(configRoot: configRoot)
        var changed = false
        // Update the former monolithic plugin first, removing its hooks before
        // installing the separate bridge. Retry repairs a partial installation.
        for (ref, target) in targets {
            let status = before[ref] ?? .notInstalled
            switch status {
            case let .installed(version):
                guard let version, AgentPluginResourceClient.isVersion(version) else {
                    throw AgentPluginInstallError("Cannot verify the installed version of \(ref). Update the Agent CLI and retry.")
                }
                if !AgentPluginResourceClient.updateAvailable(installed: version, bundled: target) {
                    continue
                }
            case .notInstalled: break
            default: throw AgentPluginInstallError("Cannot verify \(ref): \(status).")
            }
            if case .installed = status {
                try await checked(["plugin", "update", ref, "--scope", "user"], configRoot: configRoot)
            } else {
                try await checked(["plugin", "install", ref, "--scope", "user"], configRoot: configRoot)
            }
            changed = true
        }
        let after = try await installedComponents(configRoot: configRoot)
        for (ref, target) in targets {
            guard
                case let .installed(version) = after[ref], let version,
                AgentPluginResourceClient.isVersion(version),
                !AgentPluginResourceClient.updateAvailable(installed: version, bundled: target) else {
                throw AgentPluginInstallError("The Agent CLI did not confirm \(ref) version \(target). Retry installation in this configuration folder.")
            }
        }
        return (Self.combinedStatus(after), changed)
    }

    func uninstall(configRoot: String?) async throws {
        let installed = try await installedComponents(configRoot: configRoot)
        for ref in [Self.hooksRef, Self.pluginRef] {
            if case .installed = installed[ref] {
                try await checked(["plugin", "uninstall", ref, "--scope", "user", "--keep-data"], configRoot: configRoot)
            }
        }
    }

    private func checked(_ args: [String], configRoot: String?) async throws {
        let result = try await run(args, configRoot: configRoot)
        guard result.isSuccess else { throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString) }
    }

    private func verifyMarketplace(configRoot: String?) async throws {
        let result = try await run(["plugin", "marketplace", "list", "--json"], configRoot: configRoot, timeout: 30)
        guard result.isSuccess else { throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        struct Source: Decodable { let name: String
            let path: String?
        }
        let root = try JSONDecoder().decode([Source].self, from: result.stdout).first { $0.name == Self.marketplaceName }?.path
        guard let root, URL(fileURLWithPath: root).resolvingSymlinksInPath() == marketplaceSource.resolvingSymlinksInPath() else {
            throw AgentPluginInstallError("The ctrlx marketplace does not point to this CtrlX app. No plugins were replaced.")
        }
    }

    private func installedComponents(configRoot: String?) async throws -> [String: PluginInstallStatus] {
        let result = try await run(["plugin", "list", "--json"], configRoot: configRoot, timeout: 30)
        guard result.isSuccess else { throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        var statuses: [String: PluginInstallStatus] = [:]
        for ref in [Self.pluginRef, Self.hooksRef] {
            let status = Self.parseStatus(from: result.stdoutString, pluginRef: ref)
            if case let .checkFailed(message) = status {
                throw AgentPluginInstallError(message)
            }
            statuses[ref] = status
        }
        return statuses
    }

    private static func combinedStatus(_ statuses: [String: PluginInstallStatus]) -> PluginInstallStatus {
        if case let .installed(skills) = statuses[pluginRef] {
            if case let .installed(hooks) = statuses[hooksRef] {
                return .installed(version: AgentPluginResourceClient.combinedVersion(skills: skills, hooks: hooks))
            }
            return .installed(version: skills) // Legacy/missing bridge: the paired bundle produces an update notice.
        }
        if case let .installed(hooks) = statuses[hooksRef] {
            return .installed(version: AgentPluginResourceClient.hooksOnlyVersion(hooks))
        }
        return .notInstalled
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        do {
            return try Self.combinedStatus(await installedComponents(configRoot: configRoot))
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
    static func parseStatus(from listing: String, pluginRef: String = Self.pluginRef) -> PluginInstallStatus {
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
