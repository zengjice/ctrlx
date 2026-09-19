import Foundation
import Testing
@testable import CtrlxNetworking

struct DirectorySessionCommandTests {
    @Test("Strict directory launches round-trip without Viewer path expansion")
    func roundTrip() throws {
        let spec = CreateTmuxSession(sessionName: "new", width: 120, height: 40,
                                     workingDirectory: "~/Projects/new", pluginID: "codex", requireAgentLaunch: true)
        let data = try JSONEncoder().encode(spec.commandType)
        #expect(try JSONDecoder().decode(CommandType.self, from: data) == .createTmuxSession(spec))
    }

    @Test("Older requests retain optional auto-run behavior")
    func legacy() throws {
        let data = Data(#"{"sessionName":"terminal","width":80,"height":24}"#.utf8)
        let spec = try JSONDecoder().decode(CreateTmuxSession.self, from: data)
        #expect(!spec.requireAgentLaunch)
        #expect(spec.pluginID == "claude-code")
        #expect(spec.workingDirectory == nil)
    }
}
