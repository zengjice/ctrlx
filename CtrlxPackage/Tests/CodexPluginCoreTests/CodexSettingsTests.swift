import CodexPluginCore
import CtrlxPluginProtocol
import Foundation
import Testing

struct CodexSettingsTests {
    @Test("defaults match the spec")
    func defaults() {
        let settings = CodexSettings()
        #expect(settings.commandPath == "codex")
        #expect(settings.autoRun == true)
        #expect(settings.logLevel == .info)
    }

    @Test("decodes snake_case settings.json")
    func decodeSnakeCase() throws {
        let json = Data("""
        { "command_path": "/opt/homebrew/bin/codex", "auto_run": false, "log_level": "error" }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.commandPath == "/opt/homebrew/bin/codex")
        #expect(settings.autoRun == false)
        #expect(settings.logLevel == .error)
    }

    @Test("decode(from:) falls back to defaults on empty or malformed data")
    func defensiveDecode() {
        #expect(CodexSettings.decode(from: Data()) == CodexSettings())
        #expect(CodexSettings.decode(from: Data("nope".utf8)) == CodexSettings())
    }

    @Test("closePaneOnSessionEnd defaults to false")
    func closePaneOnSessionEndDefault() {
        let settings = CodexSettings()
        #expect(settings.closePaneOnSessionEnd == false)
    }

    @Test("decodes close_pane_on_session_end from JSON")
    func decodesClosePaneOnSessionEnd() throws {
        let json = Data("""
        { "close_pane_on_session_end": true }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.closePaneOnSessionEnd == true)
    }

    @Test("additionalConfigFolders defaults to empty array")
    func additionalConfigFoldersDefault() {
        let settings = CodexSettings()
        #expect(settings.additionalConfigFolders == [])
    }

    @Test("decodes additional_config_folders from JSON")
    func decodesAdditionalConfigFolders() throws {
        let json = Data("""
        { "additional_config_folders": ["/home/user/.codex", "/opt/codex"] }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.additionalConfigFolders == ["/home/user/.codex", "/opt/codex"])
    }

    @Test("exportTelemetry defaults to true")
    func exportTelemetryDefault() {
        #expect(CodexSettings().exportTelemetry == true)
    }

    @Test("decodes export_telemetry from JSON and defaults true when absent (older settings)")
    func decodesExportTelemetry() throws {
        let off = try JSONDecoder().decode(CodexSettings.self, from: Data(#"{ "export_telemetry": false }"#.utf8))
        #expect(off.exportTelemetry == false)
        // An older settings.json without the key keeps the opt-in default.
        let legacy = try JSONDecoder().decode(CodexSettings.self, from: Data(#"{ "auto_run": true }"#.utf8))
        #expect(legacy.exportTelemetry == true)
    }

    @Test("new fields round-trip through JSON")
    func newFieldsRoundTrip() throws {
        let original = CodexSettings(
            closePaneOnSessionEnd: true,
            additionalConfigFolders: ["/custom/path"],
            exportTelemetry: false
        )
        let data = try JSONEncoder().encode(original)
        #expect(CodexSettings.decode(from: data) == original)
    }

    @Test("Provider profiles decode from snake_case and older settings keep the CLI default")
    func providers() throws {
        let json = Data("""
        {
          "providers": [{
            "id": "custom",
            "name": "Custom API",
            "base_url": "https://api.example.com/v1",
            "model": "custom-model",
            "environment_key": "CUSTOM_API_KEY"
          }],
          "default_provider_id": "custom"
        }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.providers == [CodexProviderProfile(
            id: "custom",
            name: "Custom API",
            baseURL: "https://api.example.com/v1",
            model: "custom-model",
            environmentKey: "CUSTOM_API_KEY"
        )])
        #expect(settings.providerOptions.map(\.id) == ["openai", "custom"])
        #expect(settings.resolvedDefaultProviderID == "custom")

        let legacy = try JSONDecoder().decode(CodexSettings.self, from: Data(#"{"auto_run":true}"#.utf8))
        #expect(legacy.providers.isEmpty && legacy.defaultProviderID == nil)
        #expect(legacy.providerOptions.map(\.id) == ["openai"])

        var invalid = settings
        invalid.defaultProviderID = "removed"
        #expect(invalid.resolvedDefaultProviderID == nil)
    }

    @Test("Provider IDs and credential environment keys reject unsafe values")
    func providerValidation() {
        #expect(CodexSettings.isValidProviderID("custom_1"))
        for id in ["", "openai", "-custom", "has space", "a/b", String(repeating: "a", count: 65)] {
            #expect(!CodexSettings.isValidProviderID(id))
        }
        #expect(CodexSettings.isValidEnvironmentKey("CUSTOM_API_KEY"))
        for key in ["", "1KEY", "HAS-DASH", "PATH", "HOME", "CODEX_HOME", "CTRLX_AGENT_PROVIDER_ID"] {
            #expect(!CodexSettings.isValidEnvironmentKey(key))
        }
    }
}
