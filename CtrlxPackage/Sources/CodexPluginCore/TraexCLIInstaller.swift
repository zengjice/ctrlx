import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Traex reads Codex-format plugins but has its own native maintenance commands and cache.
struct TraexCLIInstaller {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    private let names = ["ctrlx", "ctrlx-hooks"]

    private func root(_ configRoot: String?) -> URL {
        configRoot.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? CodexDistribution.traex.defaultHome()
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval = 30) async throws -> String {
        let result = try await processRunner.run("/usr/bin/env", [command] + args, ["TRAE_HOME": root(configRoot).path], timeout)
        guard result.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdoutString
    }

    func bundledVersion() async throws -> String {
        let versions = try await bundledVersions()
        guard let version = AgentPluginResourceClient.combinedVersion(skills: versions[0], hooks: versions[1]) else {
            throw AgentPluginInstallError("The bundled Traex plugins have invalid versions.")
        }
        return version
    }

    private func bundledVersions() async throws -> [String] {
        @Dependency(AgentPluginResourceClient.self) var resources
        var versions: [String] = []
        for name in names {
            try versions.append(await resources.version(marketplaceSource.appendingPathComponent("\(name)/.codex-plugin/plugin.json")))
        }
        return versions
    }

    func install(configRoot: String?) async throws -> InstallResult {
        let (_, changed) = try await synchronize(configRoot: configRoot)
        return changed ? .installed(message: "Installed CtrlX skills and lifecycle hooks for Traex.") : .alreadyInstalled
    }

    func reinstall(configRoot: String?) async throws -> PluginInstallStatus {
        try await synchronize(configRoot: configRoot).0
    }

    private func synchronize(configRoot: String?) async throws -> (PluginInstallStatus, Bool) {
        let targets = try await bundledVersions()
        _ = try await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 120)
        let sources = try await run(["plugin", "marketplace", "list"], configRoot: configRoot)
        guard
            let registered = Self.marketplaceRoot(from: sources),
            registered.resolvingSymlinksInPath() == marketplaceSource.resolvingSymlinksInPath() else {
            throw AgentPluginInstallError("The ctrlx marketplace does not point to this CtrlX app. No plugins were replaced.")
        }
        let before = try await installedVersions(configRoot: configRoot)
        var changed = false
        for (name, target) in zip(names, targets) {
            if let current = before[name], !AgentPluginResourceClient.updateAvailable(installed: current, bundled: target) {
                continue
            }
            // Traex's upgrade command requires a Git marketplace. Native install
            // refreshes local marketplace caches without an uninstall gap.
            _ = try await run(["plugin", "install", "\(name)@ctrlx", "--yes"], configRoot: configRoot, timeout: 120)
            changed = true
        }
        let after = try await installedVersions(configRoot: configRoot)
        for (name, target) in zip(names, targets) {
            guard let current = after[name], !AgentPluginResourceClient.updateAvailable(installed: current, bundled: target) else {
                throw AgentPluginInstallError("Traex did not confirm \(name) version \(target). Retry installation in this configuration folder.")
            }
        }
        return (Self.status(after), changed)
    }

    func uninstall(configRoot: String?) async throws {
        var failures: [String] = []
        for name in names.reversed() {
            do {
                _ = try await run(["plugin", "uninstall", "\(name)@ctrlx"], configRoot: configRoot)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else { throw AgentPluginInstallError(failures.joined(separator: "\n")) }
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        do {
            let versions = try await installedVersions(configRoot: configRoot)
            return Self.status(versions)
        } catch ProcessRunnerError.executionFailed(exitCode: 127, stderr: _) {
            return .agentUnavailable
        } catch ProcessRunnerError.executableNotFound {
            return .agentUnavailable
        } catch {
            return .checkFailed(message: error.localizedDescription)
        }
    }

    private func installedVersions(configRoot: String?) async throws -> [String: String] {
        let listing = try await run(["plugin", "list"], configRoot: configRoot)
        let references = try Self.installedReferences(from: listing)
        @Dependency(AccountConfigurationClient.self) var files
        @Dependency(AgentPluginResourceClient.self) var resources
        var result: [String: String] = [:]
        for name in names where references.contains("\(name)@ctrlx") {
            let cache = root(configRoot).appendingPathComponent("plugins/cache/ctrlx/\(name)")
            guard
                let active = try await files.read(cache.appendingPathComponent(".active-version")),
                let version = String(data: active, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                AgentPluginResourceClient.isVersion(version) else {
                throw AgentPluginInstallError("Traex's active \(name) version could not be verified.")
            }
            let confirmed = try await resources.version(cache.appendingPathComponent("\(version)/.codex-plugin/plugin.json"))
            guard confirmed == version else {
                throw AgentPluginInstallError("Traex's installed \(name) manifest does not match its active version.")
            }
            result[name] = version
        }
        return result
    }

    static func installedReferences(from listing: String) throws -> Set<String> {
        let text = listing.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "No plugins installed." {
            return []
        }
        let references = Set(text.split(separator: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("id: ") ? String(line.dropFirst(4)) : nil
        })
        guard text.hasPrefix("Plugins:"), !references.isEmpty else {
            throw AgentPluginInstallError("Traex returned an unrecognized plugin list.")
        }
        return references
    }

    static func marketplaceRoot(from listing: String) -> URL? {
        var matching = false
        for line in listing.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("✓ ") {
                matching = line == "✓ ctrlx"
            }
            if matching, line.hasPrefix("path: ") {
                let path = String(line.dropFirst(6))
                guard path.hasPrefix("/"), path.hasSuffix("/.agents/plugins/marketplace.json") else { return nil }
                return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        return nil
    }

    private static func status(_ versions: [String: String]) -> PluginInstallStatus {
        if let skills = versions["ctrlx"] {
            return .installed(version: AgentPluginResourceClient.combinedVersion(skills: skills, hooks: versions["ctrlx-hooks"]) ?? skills)
        }
        if let hooks = versions["ctrlx-hooks"] {
            return .installed(version: AgentPluginResourceClient.hooksOnlyVersion(hooks))
        }
        return .notInstalled
    }
}
