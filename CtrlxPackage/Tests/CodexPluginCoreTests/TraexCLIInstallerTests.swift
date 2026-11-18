import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct TraexCLIInstallerTests {
    @Test("Traex plugin IDs are marketplace-qualified; malformed output is unknown")
    func listing() throws {
        #expect(try TraexCLIInstaller.installedReferences(from: "No plugins installed.\n").isEmpty)
        let listing = "Plugins:\n\n✓ ctrlx-hooks\n  id: ctrlx-hooks@other\n\n✓ ctrlx\n  id: ctrlx@ctrlx\n"
        #expect(try TraexCLIInstaller.installedReferences(from: listing) == ["ctrlx-hooks@other", "ctrlx@ctrlx"])
        for malformed in ["", "garbage", "Plugins:\n✓ ctrlx"] {
            #expect(throws: AgentPluginInstallError.self) { try TraexCLIInstaller.installedReferences(from: malformed) }
        }
    }

    @Test("Traex marketplace verification reads the exact ctrlx root")
    func marketplace() {
        let listing = "Marketplaces:\n\n✓ unrelated\n path: /wrong/.agents/plugins/marketplace.json\n\n✓ ctrlx\n path: /bundle/plugin/traex/.agents/plugins/marketplace.json\n plugins: 2\n"
        #expect(TraexCLIInstaller.marketplaceRoot(from: listing)?.path == "/bundle/plugin/traex")
        #expect(TraexCLIInstaller.marketplaceRoot(from: "✓ ctrlx\npath: relative/.agents/plugins/marketplace.json") == nil)
        #expect(TraexCLIInstaller.marketplaceRoot(from: "✓ unrelated\npath: /bundle/.agents/plugins/marketplace.json") == nil)
    }

    @Test("Traex command failures never infer installation from a stale cache")
    func failures() async {
        let missing = TraexCLIInstaller(processRunner: ProcessRunner { _, _, environment, _ in
            #expect(environment == ["TRAE_HOME": "/isolated/traex"])
            return ProcessResult(exitCode: 127, stdout: Data(), stderr: Data())
        }, command: "traex", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        #expect(await missing.installStatus(configRoot: "/isolated/traex") == .agentUnavailable)
        let timeout = TraexCLIInstaller(processRunner: ProcessRunner { _, _, _, _ in
            throw ProcessRunnerError.timeout
        }, command: "traex", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        #expect(await timeout.installStatus(configRoot: "/isolated/traex") == .checkFailed(message: ProcessRunnerError.timeout.localizedDescription))
    }

    @Test("Native Traex install, readback, repeat and scoped uninstall", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_TRAEX_NATIVE_TESTS"] == "1"))
    func nativeInstallation() async throws {
        let executable = ProcessInfo.processInfo.environment["CTRLX_TRAEX_TEST_EXECUTABLE"] ?? "traex"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-install-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marketplace = root.appendingPathComponent("marketplace")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("plugin/traex"), to: marketplace)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("plugin/ctrlx/skills"), to: marketplace.appendingPathComponent("ctrlx/skills"))
        let configRoot = root.appendingPathComponent("trae")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let live = ProcessRunner.liveValue
        let runner = ProcessRunner(run: { path, args, environment, timeout in
            let environment = (environment ?? [:]).merging([
                "HOME": root.path, "TRAECLI_AUTO_UPDATE_ON_STARTUP": "0", "TRAEX_AUTO_UPDATE_ON_STARTUP": "0",
            ]) { _, isolated in isolated }
            return try await live.run(path, args, environment, timeout)
        })
        let installer = TraexCLIInstaller(processRunner: runner, command: executable, marketplaceSource: marketplace)
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[AccountConfigurationClient.self] = .liveValue
            $0[AgentPluginResourceClient.self] = .liveValue
        } operation: {
            #expect(await installer.installStatus(configRoot: configRoot.path) == .notInstalled)
            _ = try await installer.install(configRoot: configRoot.path)
            let status = await installer.installStatus(configRoot: configRoot.path)
            let bundled = try await installer.bundledVersion()
            #expect(status == .installed(version: bundled))
            guard case .alreadyInstalled = try await installer.install(configRoot: configRoot.path) else {
                Issue.record("An up-to-date Traex installation was replaced.")
                return
            }
            #expect(try await installer.reinstall(configRoot: configRoot.path) == status)
            try await installer.uninstall(configRoot: configRoot.path)
            #expect(await installer.installStatus(configRoot: configRoot.path) == .notInstalled)

            // A Traex home may already contain the formerly compatible Codex bridge.
            let manifest = marketplace.appendingPathComponent("ctrlx-hooks/.codex-plugin/plugin.json")
            let bridge = marketplace.appendingPathComponent("ctrlx-hooks/scripts/hook.py")
            let originalManifest = try Data(contentsOf: manifest)
            let originalBridge = try String(contentsOf: bridge, encoding: .utf8)
            let version = try await AgentPluginResourceClient.liveValue.version(manifest)
            var legacy = try #require(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
            legacy["version"] = "1.0.0"
            try JSONSerialization.data(withJSONObject: legacy).write(to: manifest)
            try originalBridge.replacingOccurrences(of: "PLUGIN_ID = \"traex\"", with: "PLUGIN_ID = \"codex\"").write(to: bridge, atomically: true, encoding: .utf8)
            let seeded = try await runner.run("/usr/bin/env", [executable, "plugin", "install", "ctrlx-hooks@ctrlx", "--yes"], ["TRAE_HOME": configRoot.path], 120)
            try #require(seeded.isSuccess)
            try originalManifest.write(to: manifest)
            try originalBridge.write(to: bridge, atomically: true, encoding: .utf8)
            #expect(try await installer.reinstall(configRoot: configRoot.path) == status)
            let cached = configRoot.appendingPathComponent("plugins/cache/ctrlx/ctrlx-hooks/\(version)/scripts/hook.py")
            #expect(try String(contentsOf: cached, encoding: .utf8).contains("PLUGIN_ID = \"traex\""))
            try await installer.uninstall(configRoot: configRoot.path)
        }
    }
}
