import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentLaunchDefaultsTests {
    @Test("Codex is preferred regardless of the available agents' display order")
    func prefersCodex() {
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["claude-code", "codex", "pi"]) == "codex")
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["pi", "codex", "claude-code"]) == "codex")
    }

    @Test("Explicit choices survive default selection", arguments: ["claude-code", "codex", "pi"])
    func preservesSelection(pluginID: String) {
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["claude-code", "codex", "pi"], selection: pluginID) == pluginID)
    }

    @Test("Removed choices and unavailable Codex never select an absent Host agent")
    func unavailableAgents() {
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["claude-code", "codex"], selection: "removed") == "codex")
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["claude-code", "pi"], selection: "codex") == "claude-code")
        #expect(AgentLaunchDefaults.selectedID(availableIDs: ["pi"]) == "pi")
        #expect(AgentLaunchDefaults.selectedID(availableIDs: [], selection: "codex") == nil)
    }

    @Test("New session requests explicitly encode the Codex default")
    func newRequests() throws {
        let spec = CreateTmuxSession(sessionName: "new", width: 80, height: 24, workingDirectory: "/Host")
        #expect(spec.pluginID == "codex")
        let decoded = try JSONDecoder().decode(CreateTmuxSession.self, from: JSONEncoder().encode(spec))
        #expect(decoded.pluginID == "codex")
        #expect(CommandType.createTmuxSession(sessionName: "new", width: 80, height: 24, workingDirectory: "/Host") == spec.commandType)
    }

    @Test("Explicit Claude launches and historical wire defaults remain Claude")
    func preservesClaude() throws {
        let spec = CreateTmuxSession(sessionName: "new", width: 80, height: 24, workingDirectory: "/Host", pluginID: "claude-code")
        #expect(try JSONDecoder().decode(CreateTmuxSession.self, from: JSONEncoder().encode(spec)).pluginID == "claude-code")
        let legacy = Data(#"{"sessionName":"old","width":80,"height":24,"workingDirectory":"/Host"}"#.utf8)
        #expect(try JSONDecoder().decode(CreateTmuxSession.self, from: legacy).pluginID == "claude-code")
    }
}
