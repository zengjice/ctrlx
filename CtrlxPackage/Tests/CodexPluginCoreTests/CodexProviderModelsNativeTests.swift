import CtrlxCommon
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexProviderModelsNativeTests {
    @Test("Native Codex-family CLIs read the generated multi-model catalog", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_NATIVE_PROVIDER_MODELS"] == "1"), arguments: [CodexDistribution.codex, .traex])
    func nativeCatalog(distribution: CodexDistribution) async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            try await readCatalog(distribution: distribution)
        }
    }

    private func readCatalog(distribution: CodexDistribution) async throws {
        let executable = distribution == .codex ? "/opt/homebrew/bin/codex" : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/traex").path
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-provider-models-\(UUID())")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "PATH": "/opt/homebrew/bin:/usr/bin:/bin", distribution == .codex ? "CODEX_HOME" : "TRAE_HOME": config.path]
        let live = ProcessRunner.liveValue
        var runner = live
        runner.runBounded = { command, arguments, _, timeout, limit in
            try await live.runWithExactEnvironment(command, arguments, environment, #require(timeout), limit, nil)
        }
        let profile = CodexProviderProfile(id: "fixture", name: "Fixture", baseURL: "http://127.0.0.1:9/v1", model: "fixture-a", models: ["vendor/model@revision"], environmentKey: "FIXTURE_KEY")
        let catalog = try await CodexProviderModelCatalog.write(provider: profile, command: executable, stateDirectory: root, processRunner: runner)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let catalogPath = try String(decoding: encoder.encode(catalog.path), as: UTF8.self)
        let result = try await live.runWithExactEnvironment(executable, [
            "-c", #"model_provider="fixture""#,
            "-c", #"model_providers.fixture.name="Fixture""#,
            "-c", #"model_providers.fixture.base_url="http://127.0.0.1:9/v1""#,
            "-c", #"model_providers.fixture.wire_api="responses""#,
            "-c", "model_providers.fixture.requires_openai_auth=false",
            "-c", "model_catalog_json=\(catalogPath)",
            "debug", "models",
        ], environment, 15, 4 * 1_024 * 1_024, nil)
        try #require(result.isSuccess, "\(result.stderrString)")
        #expect(try CodexModelCatalog.parse(result.stdout).map(\.id) == ["fixture-a", "vendor/model@revision"])
    }
}
