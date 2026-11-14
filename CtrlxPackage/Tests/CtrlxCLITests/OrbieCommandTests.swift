import ArgumentParser
import Foundation
import Testing
@testable import CtrlxCLI

struct OrbieCommandTests {
    @Test
    func readOnlyCommandsPreserveFiltersAndTaskIDs() throws {
        let list = try #require(CtrlxCLI.parseAsRoot(["orbie", "tasks", "list", "--query", "音频 project", "--limit", "3", "--since", "2026-11-12T00:00:00Z", "--include-archived"]) as? OrbieTasksListCommand)
        let params = try list.parameters()
        #expect(params["query"] == .string("音频 project") && params["limit"] == .int(3))
        #expect(params["includeArchived"] == .bool(true))
        let id = UUID()
        let show = try #require(CtrlxCLI.parseAsRoot(["orbie", "tasks", "show", id.uuidString]) as? OrbieTasksShowCommand)
        #expect(try show.parameters() == ["taskId": .string(id.uuidString)])
        #expect(throws: (any Error).self) { try CtrlxCLI.parseAsRoot(["orbie", "tasks", "send", id.uuidString]) }
    }

    @Test(arguments: ["--pane", "--window", "--session"])
    func targetOverridesCannotSelectAnotherAgent(flag: String) throws {
        let list = try OrbieTasksListCommand.parse([flag, "%1"])
        let show = try OrbieTasksShowCommand.parse([UUID().uuidString, flag, "%1"])
        #expect(throws: (any Error).self) { try list.parameters() }
        #expect(throws: (any Error).self) { try show.parameters() }
    }

    @Test(arguments: [["--limit", "0"], ["--limit", "13"], ["--since", "yesterday"], ["--query", String(repeating: "猫", count: 86)]])
    func invalidQueriesFailBeforeConnecting(arguments: [String]) throws {
        let command = try OrbieTasksListCommand.parse(arguments)
        #expect(throws: (any Error).self) { try command.parameters() }
    }
}
