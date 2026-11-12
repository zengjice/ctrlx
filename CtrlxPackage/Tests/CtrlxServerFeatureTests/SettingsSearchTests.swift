import Testing
@testable import CtrlxServerFeature

struct SettingsSearchTests {
    @Test("Search accepts setting names, aliases and Chinese keywords", arguments: [
        ("font", SettingsTab.appearance, SettingsSection.terminalAppearance),
        ("字体", .appearance, .terminalAppearance),
        ("tmux socket", .general, .tmux),
        ("provider", .agents, .agentProviders),
        ("telemetry", .agents, .agentAdvanced),
        ("  LOG   level  ", .agents, .agentAdvanced),
        ("reconnect", .relay, .reconnection),
        ("Server URL", .relay, .relay),
        ("Relay Authorization", .relay, .relayAuthorization),
        ("access key", .relay, .relayAccess),
        ("Remote Hosts Relay Traffic", .relay, .relayTraffic),
        ("CLI update", .agents, .agentCLI),
        ("CtrlX Plugin", .agents, .agentStatus),
        ("Plugin Updates", .agents, .agentUpdates),
    ])
    func destinations(query: String, tab: SettingsTab, section: SettingsSection) throws {
        let result = try #require(SettingsSearchItem.matching(query).first)
        #expect(result.tab == tab)
        #expect(result.section == section)
    }

    @Test("Empty, whitespace-only and unrelated searches have no matches")
    func emptySearches() {
        for query in ["", " \n ", "not-a-setting-87492"] {
            #expect(SettingsSearchItem.matching(query).isEmpty)
        }
    }

    @Test("Search results have unique stable identities and cover every Settings page")
    func catalogCoverage() {
        let items = SettingsSearchItem.all
        #expect(Set(items.map(\.id)).count == items.count)
        let tabs: [SettingsTab] = [.general, .appearance, .browser, .sidebarLayout, .editors, .relay, .remoteAccess, .remoteHosts, .quickPhraseSync, .voiceInput, .agents, .about]
        for tab in tabs {
            #expect(items.contains { $0.tab == tab })
        }
    }
}
