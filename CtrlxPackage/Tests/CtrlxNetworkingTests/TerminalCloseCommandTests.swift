import Foundation
import Testing
@testable import CtrlxNetworking

struct TerminalCloseCommandTests {
    private enum LegacyCloseCommand: Codable, Equatable {
        case killTmuxWindow(KillTmuxWindow)
        case killTmuxSession(KillTmuxSession)
    }

    @Test("A Host must understand the guarded command to close a terminal tab", arguments: [CloseTerminalTab.Scope.window, .session])
    func guardedCloseWireFormat(scope: CloseTerminalTab.Scope) throws {
        let spec = CloseTerminalTab(sessionName: "project", windowID: "@7", scope: scope)
        let encoded = try JSONEncoder().encode(spec.commandType)
        let decoded = try JSONDecoder().decode(CommandType.self, from: encoded)
        #expect(decoded == .closeTerminalTab(spec))
        #expect(decoded.requiresResponse)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LegacyCloseCommand.self, from: encoded)
        }

        let explicitClose = KillTmuxSession(sessionName: "project")
        let legacy = try JSONEncoder().encode(explicitClose.commandType)
        #expect(try JSONDecoder().decode(LegacyCloseCommand.self, from: legacy) == .killTmuxSession(explicitClose))

        let explicitWindowClose = KillTmuxWindow(windowId: "@7")
        let legacyWindow = try JSONEncoder().encode(explicitWindowClose.commandType)
        #expect(try JSONDecoder().decode(LegacyCloseCommand.self, from: legacyWindow) == .killTmuxWindow(explicitWindowClose))
    }
}
