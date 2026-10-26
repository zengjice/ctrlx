import ClaudeCodePluginCore
import CtrlxPluginProtocol
import Foundation
import Testing

@Suite("ClaudeCodeSettings")
struct ClaudeCodeSettingsTests {
    @Test("defaults match the spec")
    func defaults() {
        let settings = ClaudeCodeSettings()
        #expect(settings.commandPath == "claude")
        #expect(settings.autoRun == true)
        #expect(settings.logLevel == .info)
    }

    @Test("decodes snake_case settings.json")
    func decodeSnakeCase() throws {
        let json = Data("""
        { "command_path": "/usr/local/bin/claude", "auto_run": false, "log_level": "debug" }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.commandPath == "/usr/local/bin/claude")
        #expect(settings.autoRun == false)
        #expect(settings.logLevel == .debug)
    }

    @Test("decode(from:) falls back to defaults on empty or malformed data")
    func defensiveDecode() {
        #expect(ClaudeCodeSettings.decode(from: Data()) == ClaudeCodeSettings())
        #expect(ClaudeCodeSettings.decode(from: Data("not json".utf8)) == ClaudeCodeSettings())
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let original = ClaudeCodeSettings(commandPath: "claude", autoRun: true, logLevel: .warn)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }

    @Test("closePaneOnSessionEnd defaults to false")
    func closePaneOnSessionEndDefault() {
        let settings = ClaudeCodeSettings()
        #expect(settings.closePaneOnSessionEnd == false)
    }

    @Test("decodes close_pane_on_session_end from JSON")
    func decodesClosePaneOnSessionEnd() throws {
        let json = Data("""
        { "close_pane_on_session_end": true }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.closePaneOnSessionEnd == true)
    }

    @Test("closePaneOnSessionEnd round-trips through JSON")
    func closePaneOnSessionEndRoundTrip() throws {
        let original = ClaudeCodeSettings(closePaneOnSessionEnd: true)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }

    @Test("detectFalseStops defaults to true (also when the key is absent)")
    func detectFalseStopsDefault() throws {
        #expect(ClaudeCodeSettings().detectFalseStops == true)
        let json = Data(#"{ "command_path": "claude" }"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: json).detectFalseStops == true)
    }

    @Test("decodes detect_false_stops from JSON and round-trips")
    func detectFalseStopsRoundTrip() throws {
        let json = Data(#"{ "detect_false_stops": false }"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: json).detectFalseStops == false)

        let original = ClaudeCodeSettings(detectFalseStops: false)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }

    @Test("Provider profiles decode from snake_case and older settings keep the CLI default")
    func providers() throws {
        let json = Data("""
        {
          "providers": [{
            "id": "custom",
            "name": "Custom Anthropic",
            "base_url": "https://api.example.com/v1",
            "model": "claude-custom",
            "auth_kind": "auth_token",
            "environment_key": "ANTHROPIC_AUTH_TOKEN"
          }],
          "default_provider_id": "custom"
        }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.providers == [ClaudeProviderProfile(
            id: "custom",
            name: "Custom Anthropic",
            baseURL: "https://api.example.com/v1",
            model: "claude-custom",
            authKind: .authToken,
            environmentKey: "ANTHROPIC_AUTH_TOKEN"
        )])
        #expect(settings.providerOptions.map(\.id) == ["anthropic", "custom"])
        #expect(settings.resolvedDefaultProviderID == "custom")

        let legacy = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(#"{"auto_run":true}"#.utf8))
        #expect(legacy.providers.isEmpty && legacy.defaultProviderID == nil)
        #expect(legacy.providerOptions.map(\.id) == ["anthropic"])

        var invalid = settings
        invalid.defaultProviderID = "removed"
        #expect(invalid.resolvedDefaultProviderID == nil)
    }

    @Test("Provider effort and context window decode and round-trip")
    func providerEffortAndContextWindow() throws {
        let json = Data("""
        {
          "providers": [{
            "id": "custom",
            "name": "Custom Anthropic",
            "base_url": "https://api.example.com/v1",
            "model": "claude-custom",
            "auth_kind": "auth_token",
            "environment_key": "ANTHROPIC_AUTH_TOKEN",
            "reasoning_effort": "xhigh",
            "context_window_tokens": 1000000
          }]
        }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.providers.first?.reasoningEffort == .xhigh)
        #expect(settings.providers.first?.contextWindowTokens == 1_000_000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("Claude auth kinds map to their SDK environment variables")
    func providerValidation() {
        #expect(ClaudeProviderAuthKind.apiKey.environmentKey == "ANTHROPIC_API_KEY")
        #expect(ClaudeProviderAuthKind.authToken.environmentKey == "ANTHROPIC_AUTH_TOKEN")
        #expect(ClaudeReasoningEffort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
        #expect(ClaudeCodeSettings.isValidContextWindowTokens(1))
        #expect(ClaudeCodeSettings.isValidContextWindowTokens(1_000_000))
        #expect(!ClaudeCodeSettings.isValidContextWindowTokens(0))
        #expect(!ClaudeCodeSettings.isValidContextWindowTokens(-1))
        #expect(!ClaudeCodeSettings.isValidContextWindowTokens(10_000_001))
        #expect(ClaudeCodeSettings.isValidProviderID("custom_1"))
        for id in ["", "anthropic", "-custom", "has space", "a/b", String(repeating: "a", count: 65)] {
            #expect(!ClaudeCodeSettings.isValidProviderID(id))
        }
        #expect(ClaudeCodeSettings.isValidEnvironmentKey("ANTHROPIC_API_KEY"))
        for key in ["", "1KEY", "HAS-DASH", "PATH", "HOME", "CLAUDE_CONFIG_DIR", "CTRLX_AGENT_PROVIDER_ID"] {
            #expect(!ClaudeCodeSettings.isValidEnvironmentKey(key))
        }
    }
}
