import Foundation

/// Uses only isolated preferences, credentials, plugin state and a private tmux socket.
/// Set CTRLX_SETTINGS_UI_SNAPSHOTS to capture screenshots when screen recording is allowed.
public enum SettingsInteractionScenario {
    public static let scenario = CtrlxE2ELib.scenario(
        "Settings Interaction",
        tags: ["settings", "macos-only", "persistent-e2e-storage", "isolated-api"]
    ) {
        TestStep.writeFile(path: "${ctrlxStateRoot}/e2e-storage.json", content: viewerStorage)
        TestStep.writeFile(path: "${ctrlxStateRoot}/plugins/codex/settings.json", content: providerSettings)
        TestStep.launchMacApp(browserMockKeychain: true)
        TestStep.wait(seconds: 3)
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Appearance")
        TestStep.macWaitForElementQuery(.identifier("settings-terminal-preview"))
        TestStep.macClickMenuItem(menuButtonTitle: "SF Mono", itemTitle: "Menlo")
        TestStep.macWaitForElement(titled: "Terminal preview, Menlo")
        TestStep.macClickMenuItem(menuButtonTitle: "Default Dark", itemTitle: "Codex Light")
        TestStep.macWaitForElementQuery(.allOf([.identifier("settings-terminal-preview"), .labelContains("Codex Light")]))
        if ProcessInfo.processInfo.environment["CTRLX_SETTINGS_UI_SNAPSHOTS"] != nil {
            TestStep.macScreenshot(label: "settings-appearance-narrow", compare: false)
        }

        TestStep.macPressKey(.escape)
        search("tmux socket")
        TestStep.macWaitForElementVisible(titled: "tmux Configuration")
        TestStep.macWaitForElementQuery(.identifier("settings-tmux-socket"))
        TestStep.macFocusElementQuery(.identifier("settings-tmux-socket"))
        replaceFocusedText("relative-fixture.sock")
        TestStep.macPressKey(.return)
        TestStep.macWaitForElement(titled: "absolute socket path")
        TestStep.macFocusElementQuery(.identifier("settings-tmux-socket"))
        TestStep.macPressKey(.escape)
        TestStep.macWaitForElementQueryToDisappear(.valueContains("relative-fixture.sock"))
        TestStep.macFocusElementQuery(.identifier("settings-tmux-path"))
        replaceFocusedText("/unapplied/tmux")
        TestStep.macSelectSettingsTab("Appearance")
        TestStep.macSelectSettingsTab("General")
        TestStep.macWaitForElementQuery(.valueContains("/unapplied/tmux"))
        TestStep.macPressKey(.character("w"), modifiers: .command)
        TestStep.macOpenSettings()
        search("tmux")
        TestStep.macWaitForElementQueryToDisappear(.valueContains("/unapplied/tmux"))

        TestStep.macSelectSettingsTab("Agents")
        TestStep.macWaitForElementQuery(.identifier("agentCommandPath-codex"))
        TestStep.macFocusElementQuery(.identifier("agentCommandPath-codex"))
        replaceFocusedText("/unapplied/codex")
        TestStep.macClickMenuItem(menuButtonTitle: "Codex", itemTitle: "Claude Code")
        TestStep.macPressKey(.escape)
        TestStep.macWaitForElementQuery(.identifier("agentCommandPath-claude-code"))
        TestStep.macClickMenuItem(menuButtonTitle: "Claude Code", itemTitle: "Codex")
        TestStep.macPressKey(.escape)
        TestStep.macWaitForElementQuery(.valueContains("/unapplied/codex"))
        TestStep.readFile(path: "${ctrlxStateRoot}/plugins/codex/settings.json", storeAs: "commandAfterFocusLoss")
        TestStep.assertStoredNotContains(key: "commandAfterFocusLoss", substring: "unapplied")
        TestStep.macFocusElementQuery(.identifier("agentCommandPath-codex"))
        replaceFocusedText("/does-not-exist-settings-cli")
        TestStep.macPressKey(.return)
        TestStep.macWaitForElementQuery(.identifier("agentWriteError-codex"))
        TestStep.macFocusElementQuery(.identifier("agentCommandPath-codex"))
        TestStep.macPressKey(.escape)
        TestStep.macWaitForElementQueryToDisappear(.valueContains("/does-not-exist-settings-cli"))
        TestStep.macFocusElementQuery(.identifier("agentCommandPath-codex"))
        replaceFocusedText("/usr/bin/true")
        TestStep.macPressKey(.return)
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/plugins/codex/settings.json", substring: "usr", storeAs: "savedAgentCommand")
        TestStep.macWaitForElement(titled: "Command path saved.")
        TestStep.macSelectSettingsTab("Appearance")
        TestStep.macSelectSettingsTab("Agents")
        TestStep.macWaitForElementQuery(.valueContains("/usr/bin/true"))

        search("telemetry")
        TestStep.macWaitForElementVisible(titled: "Export telemetry (tokens, latency, model)")
        TestStep.macWaitForElementQuery(.identifier("agentExportTelemetry-codex"))
        if ProcessInfo.processInfo.environment["CTRLX_SETTINGS_UI_SNAPSHOTS"] != nil {
            TestStep.macScreenshot(label: "settings-agent-advanced", compare: false)
        }
        search("provider")
        TestStep.macWaitForElementVisible(titled: "Launch Default Provider")
        TestStep.macClickButton(titled: "Delete Settings Test Provider")
        TestStep.macWaitForElement(titled: "Delete Provider")
        TestStep.macPressKey(.escape)
        TestStep.readFile(path: "${ctrlxStateRoot}/plugins/codex/settings.json", storeAs: "providerAfterCancel")
        TestStep.assertStoredContains(key: "providerAfterCancel", substring: "Settings Test Provider")
        TestStep.macClickButton(titled: "Delete Settings Test Provider")
        TestStep.macWaitForElement(titled: "Delete Provider")
        TestStep.macCGClickElement(query: .identifier("agentConfirmDeleteProvider-codex"))
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("Settings Test Provider"))

        search("Server URL")
        TestStep.macWaitForWindow(titled: "Relay", timeout: 5)
        TestStep.macWaitForElementQuery(.identifier("relay-server-url"))
        TestStep.macWaitForElement(titled: "Auto-connect on launch")
        TestStep.macWaitForElement(titled: "Auto-reconnect on connection loss")

        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.macWaitForElementQueryToDisappear(.identifier("relay-server-url"))
        TestStep.macWaitForElement(titled: "Settings Test iPhone")
        TestStep.macClickMenuItem(menuButtonTitle: "Manage Viewer", itemTitle: "Unpair…")
        TestStep.macWaitForElement(titled: "Unpair Settings Test iPhone?")
        TestStep.macPressKey(.escape)
        TestStep.macWaitForElement(titled: "Settings Test iPhone")
        TestStep.macClickMenuItem(menuButtonTitle: "Manage Viewer", itemTitle: "Unpair…")
        TestStep.macClickButton(titled: "Unpair Settings Test iPhone")
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("Settings Test iPhone"))
        TestStep.macSelectSettingsTab("Files & Editors")
        TestStep.macCGClickElement(query: .identifier("settings-open-clicked-file-in-new-tab"))
        TestStep.macWaitForElementQuery(.allOf([.identifier("settings-open-clicked-file-in-new-tab"), .valueContains("0")]))
        TestStep.macCGClickElement(query: .identifier("settings-open-clicked-file-in-new-tab"))
        TestStep.macWaitForElementQuery(.allOf([.identifier("settings-open-clicked-file-in-new-tab"), .valueContains("1")]))
        if ProcessInfo.processInfo.environment["CTRLX_SETTINGS_UI_SNAPSHOTS"] != nil {
            TestStep.macScreenshot(label: "settings-files-narrow", compare: false)
        }
        TestStep.macSelectSettingsTab("Browser")
        TestStep.macCGClickElement(query: .identifier("settings-always-open-links-in-split"))
        TestStep.macWaitForElementQuery(.allOf([.identifier("settings-always-open-links-in-split"), .valueContains("1")]))
        TestStep.macCGClickElement(query: .identifier("settings-always-open-links-in-split"))
        TestStep.macWaitForElementQuery(.allOf([.identifier("settings-always-open-links-in-split"), .valueContains("0")]))
        TestStep.macSelectSettingsTab("Sidebar")
        TestStep.macClickButton(titled: "Terminals")
        TestStep.macWaitForElement(titled: "Remove Terminal Title")
        TestStep.macClickButton(titled: "Agent Sessions")
        TestStep.macWaitForElement(titled: "Add Terminal Title")
        search("Sort Order")
        TestStep.macClickButton(titled: "Agent sessions first")
        TestStep.waitForFileContains(path: "${ctrlxStateRoot}/e2e-storage.json", substring: "claudeFirst", storeAs: "settingsAfterSort")
        if ProcessInfo.processInfo.environment["CTRLX_SETTINGS_UI_SNAPSHOTS"] != nil {
            TestStep.macScreenshot(label: "settings-sidebar-narrow", compare: false)
        }
        TestStep.terminateMacApp()
    }

    private static func replaceFocusedText(_ text: String) -> TestScenario {
        CtrlxE2ELib.scenario("Replace focused text", tags: ["shortcut"]) {
            TestStep.macSetFocusedText(text)
        }
    }

    private static func search(_ query: String) -> TestScenario {
        CtrlxE2ELib.scenario("Find setting", tags: ["shortcut"]) {
            TestStep.macFocusElementQuery(.subrole("AXSearchField"))
            replaceFocusedText(query)
            TestStep.macPressKey(.return)
        }
    }

    private static let providerSettings = #"{"command_path":"codex","providers":[{"id":"settings-fixture","name":"Settings Test Provider","base_url":"https://settings-test.invalid/v1","model":"fixture-model","environment_key":"SETTINGS_TEST_API_KEY"}],"default_provider_id":"settings-fixture"}"#

    private static var viewerStorage: String {
        let viewer = #"[{"id":"settings-fixture-viewer","deviceName":"Settings Test iPhone","partnerPublicKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","partnerPublicKeyId":"settings-fixture-key","pairedAt":0}]"#
        let data = Data(viewer.utf8).base64EncodedString()
        return "{\"preferences\":{\"pairedDevices\":{\"data\":{\"_0\":\"\(data)\"}}},\"sessionKeys\":{},\"secrets\":{}}"
    }
}
