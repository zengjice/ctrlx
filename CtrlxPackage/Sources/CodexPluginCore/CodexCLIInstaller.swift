import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Skills and lifecycle hooks are independently versioned native plugins.
/// All changes go through the Agent CLI, scoped to its configuration root.
struct CodexCLIInstaller {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    static let pluginName = "ctrlx"
    static let pluginRef = "ctrlx@ctrlx"
    static let hooksRef = "ctrlx-hooks@ctrlx"
    static let marketplaceName = "ctrlx"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CODEX_HOME": $0] }
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
            (Self.pluginRef, await resources.version(marketplaceSource.appendingPathComponent("ctrlx/.codex-plugin/plugin.json"))),
            (Self.hooksRef, await resources.version(marketplaceSource.appendingPathComponent("ctrlx-hooks/.codex-plugin/plugin.json"))),
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
            try await checked(["plugin", "add", ref], configRoot: configRoot)
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
        // Listing resolves the marketplace source, which may no longer exist.
        // Codex remove is idempotent and needs only the qualified plugin ID.
        var failures: [String] = []
        for ref in [Self.hooksRef, Self.pluginRef] {
            do {
                try await checked(["plugin", "remove", ref], configRoot: configRoot)
            } catch {
                failures.append("\(ref): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else { throw AgentPluginInstallError(failures.joined(separator: "\n")) }
    }

    private func checked(_ args: [String], configRoot: String?) async throws {
        let result = try await run(args, configRoot: configRoot)
        guard result.isSuccess else { throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString) }
    }

    private func verifyMarketplace(configRoot: String?) async throws {
        let result = try await run(["plugin", "marketplace", "list", "--json"], configRoot: configRoot, timeout: 30)
        guard result.isSuccess else { throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        struct Sources: Decodable {
            struct Entry: Decodable { let name: String
                let root: String
            }

            let marketplaces: [Entry]
        }
        let root = try JSONDecoder().decode(Sources.self, from: result.stdout).marketplaces.first { $0.name == Self.marketplaceName }?.root
        guard let root, URL(fileURLWithPath: root).resolvingSymlinksInPath() == marketplaceSource.resolvingSymlinksInPath() else {
            throw AgentPluginInstallError("The ctrlx marketplace does not point to this CtrlX app. No plugins were replaced.")
        }
    }

    private func installedComponents(configRoot: String?) async throws -> [String: PluginInstallStatus] {
        let result = try await run(["plugin", "list", "-m", "ctrlx"], configRoot: configRoot, timeout: 30)
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
            if let status = configuredInstallStatus(configRoot: configRoot), case .installed = status {
                return status
            }
            return .checkFailed(message: error.localizedDescription)
        }
    }

    /// A broken unrelated marketplace can make `codex plugin list -m ctrlx`
    /// fail even though Codex successfully added or removed our plugin. In that
    /// case, use Codex's own persisted plugin table as the narrow fallback.
    private func configuredInstallStatus(configRoot: String?) -> PluginInstallStatus? {
        let codexHome = configRoot
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? CodexScanner.defaultCodexHome()
        let configURL = codexHome.appendingPathComponent("config.toml")
        guard let toml = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return Self.parseConfiguredStatus(from: toml)
    }

    static func parseConfiguredStatus(from toml: String) -> PluginInstallStatus {
        let sections = Set(toml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if sections.contains(#"[plugins."ctrlx@ctrlx"]"#) {
            return .installed(version: nil)
        }
        if sections.contains(#"[plugins."ctrlx-hooks@ctrlx"]"#) {
            return .installed(version: AgentPluginResourceClient.hooksOnlyVersion(nil))
        }
        return .notInstalled
    }

    /// Parses `codex plugin list -m ctrlx` output. Only the `ctrlx@ctrlx`
    /// row's STATUS column is authoritative — `"not installed"` ⇒ `.notInstalled`,
    /// `"installed"` ⇒ `.installed`. The marketplace header line (`` Marketplace
    /// `ctrlx` ``) and the on-disk plugin path must NOT be mistaken for an
    /// install. Version is the first dot-bearing numeric token on the row, if any.
    static func parseStatus(from listing: String, pluginRef: String = Self.pluginRef) -> PluginInstallStatus {
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
