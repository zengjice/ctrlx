import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexProviderConfigurationTests {
    private let profile = CodexProviderProfile(
        id: "12aef66f-d154-4926-841b-f4fda2f284c7", name: "Fixture API",
        baseURL: "http://127.0.0.1:9/v1", model: "fixture-model", environmentKey: "FIXTURE_API_KEY"
    )

    #if os(macOS)
        @Test("Provider synchronization writes only native Provider definitions and deduplicates roots")
        func nativeWriteProtocol() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-provider-rpc-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let command = root.appendingPathComponent("fixture codex")
            let script = #"""
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            for line in sys.stdin:
                request = json.loads(line)
                if 'id' not in request:
                    continue
                if request['method'] == 'config/batchWrite':
                    with (Path(__file__).parent / 'writes.jsonl').open('a') as f:
                        f.write(json.dumps({'root': os.environ['CODEX_HOME'], 'params': request['params']}) + '\n')
                print(json.dumps({'id': request['id'], 'result': {}}), flush=True)
            """#
            try Data(script.utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                try await CodexProviderConfigurationClient.liveValue.synchronize(command.path, ["/fixture/a", "/fixture/b", "/fixture/a"], [profile])
            }
            let writes = try String(contentsOf: root.appendingPathComponent("writes.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            #expect(writes.compactMap { $0["root"] as? String } == ["/fixture/a", "/fixture/b"])
            let params = try #require(writes.first?["params"] as? [String: Any])
            let edits = try #require(params["edits"] as? [[String: Any]])
            #expect(edits.count == 1)
            #expect(edits.first?["keyPath"] as? String == "model_providers.\(profile.id)")
            #expect(edits.first?["mergeStrategy"] as? String == "upsert")
            let value = try #require(edits.first?["value"] as? [String: Any])
            #expect(Set(value.keys) == ["name", "base_url", "env_key", "wire_api", "requires_openai_auth"])
            #expect(value["env_key"] as? String == "FIXTURE_API_KEY")
        }

        @Test("Fresh native Codex processes recognize the saved Provider after model edits", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_NATIVE_PROVIDER_CONFIGURATION"] == "1"))
        func nativeResumeProviderLookup() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-provider-native-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let config = root.appendingPathComponent("config.toml")
            let original = """
            # Preserve the user's model and default Provider.
            model = "original-model"
            model_provider = "openai"
            [model_providers.other]
            name = "Other"
            base_url = "http://127.0.0.1:9/other"
            wire_api = "responses"
            """
            try Data(original.utf8).write(to: config)
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                // This is the same lookup that fails before the user's native resume.
                await #expect(throws: CodexAccountError.self) {
                    try await lookup(root: root)
                }
                try await CodexProviderConfigurationClient.liveValue.synchronize("/opt/homebrew/bin/codex", [root.path], [profile])
                let first = try await lookup(root: root)
                #expect(first["providerId"] as? String == profile.id)
                var edited = profile
                edited.name = "Edited API"
                edited.baseURL = "http://127.0.0.1:9/updated"
                edited.models = ["second-model"]
                try await CodexProviderConfigurationClient.liveValue.synchronize("/opt/homebrew/bin/codex", [root.path], [edited])
                let second = try await lookup(root: root)
                #expect(second["providerId"] as? String == profile.id)
                #expect(second["providerName"] as? String == edited.name)
                let saved = try String(contentsOf: config, encoding: .utf8)
                #expect(saved.contains("model = \"original-model\""))
                #expect(saved.contains("model_provider = \"openai\""))
                #expect(saved.contains("[model_providers.other]"))
                #expect(saved.contains("base_url = \"http://127.0.0.1:9/updated\""))
                #expect(!saved.contains("api_key ="))
            }
        }

        private func lookup(root: URL) async throws -> [String: Any] {
            let reply = try await CodexAppServerProcess().run(command: "/opt/homebrew/bin/codex", configRoot: root.path) { server, input in
                try await server.request(2, method: "account/gatewayOAuth/read", params: ["modelProvider": profile.id], input: input)
            }
            return try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }
    #endif
}
