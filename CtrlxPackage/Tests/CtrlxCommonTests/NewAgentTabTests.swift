import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct NewAgentTabTests {
    @Test("Agent cards select the configured default while explicit choices are preserved", arguments: ["codex", "claude-code"])
    func initialProvider(pluginID: String) throws {
        let providerID = pluginID == "codex" ? "openai" : "anthropic"
        let agent = SessionLaunchAgent(
            id: pluginID, name: pluginID,
            providers: [.init(id: "custom", name: "Custom"), .init(id: providerID, name: "Official login")],
            defaultProviderID: "custom"
        )
        let config = configuration(agents: [agent])
        #expect(agent.initialProviderID == "custom")
        #expect(agent.orderedProviders.map(\.id) == ["custom", providerID])
        #expect(try config.request(agentID: agent.id, directory: "/repo", providerID: agent.initialProviderID).providerID == "custom")
        #expect(try config.request(agentID: agent.id, directory: "/repo", providerID: nil).providerID == "custom")
        #expect(try config.request(agentID: agent.id, directory: "/repo", providerID: providerID).providerID == providerID)
        #expect(try config.request(agentID: agent.id, directory: "/repo", providerID: "custom").providerID == "custom")
    }

    @Test("The default appears once at the front and other Providers keep their order")
    func providerOrder() {
        let providers: [AgentProviderOption] = [
            .init(id: "openai", name: "OpenAI"), .init(id: "ark", name: "Ark"), .init(id: "plan", name: "Agent Plan"),
        ]
        let agent = SessionLaunchAgent(id: "codex", name: "Codex", providers: providers, defaultProviderID: "plan")
        #expect(agent.orderedProviders.map(\.id) == ["plan", "openai", "ark"])
        #expect(agent.orderedProviders.map(\.name) == ["Agent Plan", "OpenAI", "Ark"])
        #expect(agent.orderedProviders.count == providers.count)
        #expect(agent.providers == providers)
        #expect(agent.providerID(for: "ark") == "ark")
    }

    @Test("Missing or stale default metadata preserves official-login and CLI choices", arguments: ["codex", "claude-code"], [nil, "removed"] as [String?])
    func providerFallback(pluginID: String, defaultID: String?) {
        let official = pluginID == "codex" ? "openai" : "anthropic"
        let agent = SessionLaunchAgent(id: pluginID, name: pluginID, providers: [.init(id: "custom", name: "Custom"), .init(id: official, name: "Official")], defaultProviderID: defaultID)
        #expect(agent.defaultProvider == nil)
        #expect(agent.orderedProviders == agent.providers)
        #expect(agent.initialProviderID == official)
        #expect(agent.providerID(for: nil) == nil)
    }

    private func configuration(host: String? = nil, agents: [SessionLaunchAgent], reason: String? = nil) -> NewAgentTabConfiguration {
        NewAgentTabConfiguration(
            id: .init(hostID: host, sessionName: "work"), initialDirectory: "/Host/repo",
            agents: agents,
            directorySource: .init(id: host ?? "local") { _ in
                Issue.record("Opening the agent list must not browse directories")
                throw CancellationError()
            },
            unavailableReason: reason,
            start: { _ in }
        )
    }

    @Test("One card per supplied Host agent, Codex first without hard-coded catalog entries")
    func dynamicAgents() {
        let agents = [SessionLaunchAgent(id: "claude", name: "Claude Code"), .init(id: "pi", name: "Pi"), .init(id: "codex", name: "Codex")]
        #expect(configuration(agents: agents).orderedAgents.map(\.id) == ["codex", "claude", "pi"])
        #expect(configuration(agents: [.init(id: "pi", name: "Pi")]).orderedAgents.map(\.id) == ["pi"])
        #expect(configuration(agents: []).orderedAgents.isEmpty)
    }

    @Test("Captured host/session and literal path are retained; no Viewer home expansion")
    func scopedRequest() throws {
        let office = configuration(host: "office", agents: [.init(id: "codex", name: "Codex")])
        let home = configuration(host: "home", agents: [.init(id: "claude", name: "Claude Code")])
        #expect(office.id != home.id)
        let request = try office.request(agentID: "codex", directory: "~/Projects/one 'two'", providerID: "custom")
        #expect(request == CreateTmuxWindow(
            sessionName: "work",
            workingDirectory: "~/Projects/one 'two'",
            pluginID: "codex",
            providerID: "custom"
        ))
        #expect(throws: NewAgentTabConfiguration.LaunchError.self) {
            try home.request(agentID: "codex", directory: "/repo", providerID: nil)
        }
    }

    @Test("Offline/old hosts, missing agents and malformed paths never become shell requests")
    func invalidRequests() {
        let agents = [SessionLaunchAgent(id: "codex", name: "Codex")]
        for reason in ["Host offline", "Update Host"] {
            #expect(throws: NewAgentTabConfiguration.LaunchError.self) {
                try configuration(agents: agents, reason: reason).request(agentID: "codex", directory: "/repo", providerID: nil)
            }
        }
        for path in ["", "relative/path", "/repo\nother"] {
            #expect(throws: NewAgentTabConfiguration.LaunchError.self) {
                try configuration(agents: agents).request(agentID: "codex", directory: path, providerID: nil)
            }
        }
    }
}
