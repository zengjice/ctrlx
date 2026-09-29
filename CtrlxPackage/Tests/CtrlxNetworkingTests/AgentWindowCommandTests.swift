import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWindowCommandTests {
    @Test("Agent window requests preserve target/path/plugin without shipping executable commands")
    func roundTrip() throws {
        let request = CreateTmuxWindow(sessionName: "work space", workingDirectory: "~/Projects/a 'repo'", pluginID: "custom-agent")
        let message = CommandMessage(paneId: "", command: request.commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.command == request.commandType)
        #expect(decoded.command.requiresResponse)
        #expect(decoded.paneId.isEmpty)
    }

    @Test("Old window requests still create ordinary terminals")
    func legacyTerminal() throws {
        let json = #"{"sessionName":"work","workingDirectory":"/repo"}"#
        let request = try JSONDecoder().decode(CreateTmuxWindow.self, from: Data(json.utf8))
        #expect(request.pluginID == nil)
        #expect(request == CreateTmuxWindow(sessionName: "work", workingDirectory: "/repo"))
    }

    @Test("Missing capability means unsupported and survives per-pair copying when present")
    func capability() throws {
        let legacy = #"{"pairId":"old","paneStates":{},"homeDirectory":"/Host"}"#
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: Data(legacy.utf8)).supportsAgentWindowLaunch == nil)
        let state = SessionStateMessage(pairId: "", paneStates: [:], supportsAgentWindowLaunch: true).withPairId("office")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state))
        #expect(decoded.pairId == "office")
        #expect(decoded.supportsAgentWindowLaunch == true)
    }
}
