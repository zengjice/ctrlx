import CtrlxPluginProtocol
import Dependencies
import DependenciesMacros
import Foundation

/// Native resume resolves the saved Provider ID from config.toml, not the original CLI overrides.
@DependencyClient
struct CodexProviderConfigurationClient: Sendable {
    var synchronize: @Sendable (_ command: String, _ roots: [String], _ providers: [CodexProviderProfile]) async throws -> Void
}

extension CodexProviderConfigurationClient: DependencyKey {
    static let testValue = Self(synchronize: { _, _, _ in })

    static let liveValue = Self(synchronize: { command, roots, providers in
        guard !providers.isEmpty else { return }
        guard providers.allSatisfy(\.isValid) else {
            throw AgentProviderError("A Codex Provider has invalid settings. Edit it in Settings → Agents → Codex → Providers.")
        }
        #if os(macOS)
            // Let Codex edit TOML and enforce managed policy. Never write a key or
            // change model_provider/model: those remain per-launch choices.
            var visited = Set<String>()
            for root in roots where visited.insert(root).inserted {
                do {
                    _ = try await CodexAppServerProcess().run(command: command, configRoot: root) { server, input in
                        let edits = providers.map { profile -> [String: Any] in
                            [
                                "keyPath": "model_providers.\(profile.id)",
                                "mergeStrategy": "upsert",
                                "value": [
                                    "name": profile.name,
                                    "base_url": profile.baseURL,
                                    "env_key": profile.environmentKey,
                                    "wire_api": "responses",
                                    "requires_openai_auth": false,
                                ],
                            ]
                        }
                        return try await server.request(2, method: "config/batchWrite", params: ["edits": edits], input: input)
                    }
                } catch {
                    throw AgentProviderError("Could not save Codex Providers for native resume in \(root). Check that the Codex CLI is available and its configuration is writable and valid.")
                }
            }
        #else
            throw AgentProviderError("Codex Provider configuration must be saved on the Mac Host.")
        #endif
    })
}
