import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentForkTests {
    @Test("Fork explains unsupported Agents, unverified IDs and unavailable directories without enabling invalid sources")
    func unavailableReasons() {
        var pane = PaneState(paneId: "%1", sessionName: "work", currentPath: "/repo", agentSession: .init(paneId: "%1", pluginID: "codex"))
        #expect(AgentForkSource.unavailableReason(panes: [pane])?.contains("not verified") == true)
        pane.claudeSessionID = UUID().uuidString
        #expect(AgentForkSource.unavailableReason(panes: [pane]) == nil)
        pane.currentPath = nil
        #expect(AgentForkSource.unavailableReason(panes: [pane])?.contains("directory") == true)
        pane.agentSession?.pluginID = "pi"
        #expect(AgentForkSource.unavailableReason(panes: [pane])?.contains("Codex or Claude Code") == true)
    }

    @Test("Only recognized native Agent conversations can be forked; window reordering preserves identity")
    func sourceIdentity() throws {
        var pane = PaneState(paneId: "%12", sessionName: "work", tmuxWindowId: "@4", currentPath: "/repo",
                             agentSession: .init(paneId: "%12", pluginID: "codex"), claudeSessionID: UUID().uuidString)
        let source = try #require(AgentForkSource(pane: pane))
        pane.windowIndex = 10
        #expect(AgentForkSource(pane: pane) == source)
        pane.claudeSessionID = UUID().uuidString
        #expect(AgentForkSource(pane: pane) != source)
        pane.claudeSessionID = nil
        #expect(AgentForkSource(pane: pane) == nil)
        pane.claudeSessionID = "--last"
        #expect(AgentForkSource(pane: pane) == nil)
        pane.claudeSessionID = UUID().uuidString
        pane.agentSession?.pluginID = "pi"
        #expect(AgentForkSource(pane: pane) == nil)
    }

    @Test("Native UUID, Host scope and worktree options survive the command wire")
    func wire() throws {
        let source = try #require(AgentForkSource(pane: .init(paneId: "%9", sessionName: "office", tmuxWindowId: "@3", currentPath: "/repo 'space'",
            agentSession: .init(paneId: "%9", pluginID: "claude-code"), claudeSessionID: UUID().uuidString)))
        let request = ForkAgentSession(source: source, windowName: "feature", worktree: .init(name: "feature", expectedHead: "abc", allowUncommittedChanges: true))
        let command = CommandMessage(paneId: "", command: request.commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(decoded.command == command.command)
        let oldState = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":"/Host"}"#.utf8))
        #expect(oldState.supportsAgentFork == nil)
        let state = SessionStateMessage(pairId: "one", paneStates: [:], supportsAgentFork: true)
        #expect(state.withPairId("two").supportsAgentFork == true)
        let oldResponse = try JSONDecoder().decode(CommandResponseMessage.self, from: Data("{\"commandId\":\"\(UUID().uuidString)\",\"success\":true}".utf8))
        #expect(oldResponse.forkPreparation == nil)
        let response = CommandResponseMessage(commandId: command.id, success: true, forkPreparation: .init(source: source, worktree: nil))
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).forkPreparation == response.forkPreparation)
    }

    @Test("Unnamed legacy Fork requests still decode; new names survive both Fork modes")
    func legacyNames() throws {
        let source = try #require(AgentForkSource(pane: .init(
            paneId: "%1", sessionName: "office", currentPath: "/repo",
            agentSession: .init(paneId: "%1", pluginID: "codex"), claudeSessionID: UUID().uuidString
        )))
        for worktree in [nil, ForkAgentSession.Worktree(name: "feature", expectedHead: "abc")] {
            let request = ForkAgentSession(source: source, worktree: worktree)
            let data = try JSONEncoder().encode(request)
            let dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(dictionary["windowName"] == nil)
            let legacy = try JSONDecoder().decode(ForkAgentSession.self, from: data)
            #expect(legacy == request)
            try legacy.validateName()
            let named = ForkAgentSession(source: source, windowName: worktree?.name ?? "我的 Fork", worktree: worktree)
            #expect(try JSONDecoder().decode(ForkAgentSession.self, from: JSONEncoder().encode(named)) == named)
            try named.validateName()
            #expect(throws: AgentForkError.self) { try ForkAgentSession(source: source, windowName: "\t").validateName() }
        }
        #expect(throws: AgentForkError.self) {
            try ForkAgentSession(source: source, windowName: "other", worktree: .init(name: "feature", expectedHead: "abc")).validateName()
        }
    }

    @Test("Worktree names cannot escape the primary repository or become Git options")
    func worktreeNames() {
        for name in ["codex-123", "feature.x", "fix_42"] { #expect(AgentForkWorktree.isValidName(name)) }
        for name in ["", "..", ".hidden", "../other", "a/b", "--force", "a b", "a\n", "HEAD", "a..b", "a.", "a.lock", String(repeating: "x", count: 81)] {
            #expect(!AgentForkWorktree.isValidName(name))
        }
    }
}
