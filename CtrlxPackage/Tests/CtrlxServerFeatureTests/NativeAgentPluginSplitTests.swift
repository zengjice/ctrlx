import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore
@testable import CodexPluginCore

/// Actual native plugin managers, private HOME/configuration/cache, no model calls.
struct NativeAgentPluginSplitTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_SPLIT_NATIVE_PLUGINS"] == "1"), arguments: ["codex", "claude"], ["normal", "hooks-only", "source-missing", "hooks-only-source-missing"])
    func unchangedHooksSurviveSkillsUpdate(_ agent: String, scenario: String) async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            try await run(agent, scenario: scenario)
        }
    }

    private func run(_ agent: String, scenario: String) async throws {
        let root = URL(fileURLWithPath: "/tmp/cx-split-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("CtrlX.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("plugin"), to: resources.appendingPathComponent("plugin"))
        let synchronized = try await ProcessRunner.liveValue.run("/bin/bash", [repository.appendingPathComponent("scripts/sync-codex-skills.sh").path], ["BUILT_PRODUCTS_DIR": root.path, "PRODUCT_NAME": "CtrlX"], 20)
        try #require(synchronized.isSuccess)
        let marketplace = resources.appendingPathComponent(agent == "codex" ? "plugin/codex" : "plugin")
        let config = root.appendingPathComponent("config")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let native = ProcessRunner.liveValue
        let runner = ProcessRunner { executable, args, environment, timeout in
            var isolated = environment ?? [:]
            isolated["HOME"] = home.path
            isolated["DISABLE_AUTOUPDATER"] = "1"
            isolated["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            isolated["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
            return try await native.run(executable, args, isolated, timeout)
        }
        try await withDependencies {
            $0[AgentPluginResourceClient.self] = .liveValue
        } operation: {
            let install: () async throws -> Void
            let update: () async throws -> PluginInstallStatus
            let uninstall: () async throws -> Void
            let status: () async -> PluginInstallStatus
            let overlay: String
            if agent == "codex" {
                let installer = CodexCLIInstaller(processRunner: runner, command: "/opt/homebrew/bin/codex", marketplaceSource: marketplace)
                install = { _ = try await installer.install(configRoot: config.path) }
                update = { try await installer.reinstall(configRoot: config.path) }
                uninstall = { try await installer.uninstall(configRoot: config.path) }
                status = { await installer.installStatus(configRoot: config.path) }
                overlay = ".codex-plugin"
            } else {
                let installer = ClaudeCodeCLIInstaller(processRunner: runner, command: "/opt/homebrew/bin/claude", marketplaceSource: marketplace)
                install = { _ = try await installer.install(configRoot: config.path) }
                update = { try await installer.reinstall(configRoot: config.path) }
                uninstall = { try await installer.uninstall(configRoot: config.path) }
                status = { await installer.installStatus(configRoot: config.path) }
                overlay = ".claude-plugin"
            }
            try await install()
            let cache = config.appendingPathComponent("plugins/cache/ctrlx/ctrlx-hooks/1.0.0")
            let manifest = cache.appendingPathComponent("\(overlay)/plugin.json")
            let before = try snapshot(cache)
            let metadata = try FileManager.default.attributesOfItem(atPath: manifest.path)
            let skillsManifest = marketplace.appendingPathComponent("ctrlx/\(overlay)/plugin.json")
            var data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: skillsManifest)) as? [String: Any])
            data["version"] = "9.0.0"
            try JSONSerialization.data(withJSONObject: data).write(to: skillsManifest)
            try "\nNative skills-only update fixture.\n".append(to: marketplace.appendingPathComponent("ctrlx/skills/file-links/SKILL.md"))
            let updated = try await update()
            #expect(updated == .installed(version: "9.0.0 + hooks 1.0.0"))
            #expect(try snapshot(cache) == before)
            let after = try FileManager.default.attributesOfItem(atPath: manifest.path)
            #expect(metadata[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
            #expect(metadata[.modificationDate] as? Date == after[.modificationDate] as? Date)
            if scenario.contains("hooks-only") {
                let args = agent == "codex" ? ["plugin", "remove", "ctrlx@ctrlx"] : ["plugin", "uninstall", "ctrlx@ctrlx", "--scope", "user", "--keep-data"]
                let key = agent == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
                let removed = try await runner.run("/usr/bin/env", ["/opt/homebrew/bin/\(agent)"] + args, [key: config.path], 30)
                try #require(removed.isSuccess)
                #expect(await status() == .installed(version: "missing + hooks 1.0.0"))
            }
            if scenario.contains("source-missing") {
                try FileManager.default.moveItem(at: marketplace, to: root.appendingPathComponent("removed-marketplace"))
                // A missing source must retain the remaining component's uninstall entry.
                guard case .installed = await status() else {
                    Issue.record("Installed components were hidden after their source moved")
                    return
                }
            }
            try await uninstall()
            if agent == "codex", scenario.contains("source-missing") {
                // Listing still requires the now-missing catalog. Verify the
                // native remove commands cleared both registration entries.
                let saved = try String(contentsOf: config.appendingPathComponent("config.toml"), encoding: .utf8)
                #expect(CodexCLIInstaller.parseConfiguredStatus(from: saved) == .notInstalled)
            } else {
                #expect(await status() == .notInstalled)
            }
        }
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
        #expect(!result.isEmpty)
        return result
    }
}

private extension String {
    func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
