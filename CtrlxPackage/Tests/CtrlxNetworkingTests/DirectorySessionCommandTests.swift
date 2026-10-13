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
        #expect(spec.worktree == nil)
    }

    @Test("Worktree requests and previews round-trip independently of agent conversations")
    func worktreeRoundTrip() throws {
        let worktree = ForkAgentSession.Worktree(name: "new-branch", expectedHead: "abc123", allowUncommittedChanges: true)
        let spec = CreateTmuxSession(
            sessionName: "new-branch",
            width: 120,
            height: 40,
            workingDirectory: "~/repo",
            pluginID: "custom-agent",
            requireAgentLaunch: true,
            worktree: worktree,
        )
        let inspect = PrepareSessionWorktree(path: "~/repo")
        for command in [spec.commandType, inspect.commandType] {
            #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(command)) == command)
        }
        let plan = AgentForkWorktree(repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "abc123", relativeDirectory: "", hasUncommittedChanges: true)
        let response = CommandResponseMessage(commandId: UUID(), success: true, sessionWorktree: plan)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).sessionWorktree == plan)
        let legacyResponse = Data(#"{"commandId":"00000000-0000-0000-0000-000000000001","success":true}"#.utf8)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: legacyResponse).sessionWorktree == nil)
        let state = SessionStateMessage(pairId: "", paneStates: [:], supportsSessionWorktrees: true).withPairId("office")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state))
        #expect(decoded.pairId == "office")
        #expect(decoded.supportsSessionWorktrees == true)
        let legacyState = Data(#"{"pairId":"old","paneStates":{},"homeDirectory":"/Host"}"#.utf8)
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: legacyState).supportsSessionWorktrees == nil)
    }
}
