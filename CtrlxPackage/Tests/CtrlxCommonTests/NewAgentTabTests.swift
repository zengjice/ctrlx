import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct NewAgentTabTests {
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
        let request = try office.request(agentID: "codex", directory: "~/Projects/one 'two'")
        #expect(request == CreateTmuxWindow(sessionName: "work", workingDirectory: "~/Projects/one 'two'", pluginID: "codex"))
        #expect(throws: NewAgentTabConfiguration.LaunchError.self) { try home.request(agentID: "codex", directory: "/repo") }
    }

    @Test("Offline/old hosts, missing agents and malformed paths never become shell requests")
    func invalidRequests() {
        let agents = [SessionLaunchAgent(id: "codex", name: "Codex")]
        for reason in ["Host offline", "Update Host"] {
            #expect(throws: NewAgentTabConfiguration.LaunchError.self) {
                try configuration(agents: agents, reason: reason).request(agentID: "codex", directory: "/repo")
            }
        }
        for path in ["", "relative/path", "/repo\nother"] {
            #expect(throws: NewAgentTabConfiguration.LaunchError.self) {
                try configuration(agents: agents).request(agentID: "codex", directory: path)
            }
        }
    }
}
