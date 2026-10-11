import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Agent image recipient")
struct AgentImageTargetTests {
    func pane(_ id: String = "%1", plugin: String = "codex") -> PaneState {
        PaneState(paneId: id, sessionName: "work", tmuxWindowId: "@2", windowName: "Agent",
                  agentSession: AgentSession(paneId: id, pluginID: plugin), claudeSessionID: "conversation-1")
    }

    @Test(arguments: ["codex", "claude-code"])
    func validatesRecipientWithoutRequiringIdle(plugin: String) throws {
        var pane = pane(plugin: plugin)
        let target = try #require(AgentImageTarget(pane: pane))
        try target.validate(pane)
        pane.agentSession?.state = .working
        try target.validate(pane)
        pane.windowName = "Renamed"; pane.windowIndex = 42
        try target.validate(pane)
    }

    @Test func refusesChangedAgentAndNoImplicitRetarget() throws {
        let original = pane()
        let target = try #require(AgentImageTarget(pane: original))
        var changed = original
        changed.claudeSessionID = "new-conversation"
        let replacement = try #require(AgentImageTarget(pane: changed))
        #expect(throws: AgentImageError.self) { try target.validate(changed) }
        #expect(AgentImageTarget.defaultTarget(in: [replacement], preferred: target) == nil)
        changed = original; changed.agentSession = nil
        #expect(throws: AgentImageError.self) { try target.validate(changed) }
        #expect(throws: AgentImageError.self) { try target.validate(nil) }
        changed = original; changed.sessionName = "another-session"
        #expect(throws: AgentImageError.self) { try target.validate(changed) }
        changed = original; changed.tmuxWindowId = "@3"
        #expect(throws: AgentImageError.self) { try target.validate(changed) }
    }

    @Test func multiplePanesRequireExplicitChoiceUnlessSourceMatches() throws {
        let first = try #require(AgentImageTarget(pane: pane()))
        let second = try #require(AgentImageTarget(pane: pane("%2", plugin: "claude-code")))
        #expect(AgentImageTarget.defaultTarget(in: [first, second], preferred: nil) == nil)
        #expect(AgentImageTarget.defaultTarget(in: [second, first], preferred: first) == first)
        #expect(AgentImageTarget.defaultTarget(in: [first], preferred: nil) == first)
        #expect(AgentImageTarget.defaultTarget(in: [], preferred: first) == nil)
        #expect(AgentImageTarget(pane: PaneState(paneId: "%3")) == nil)
        var unverified = pane(); unverified.claudeSessionID = nil
        #expect(AgentImageTarget(pane: unverified) == nil)
    }

    @Test func protocolIsAdditiveAndCapabilitySurvivesPairCopy() throws {
        let target = try #require(AgentImageTarget(pane: pane()))
        let command = SendDroppedFiles(files: [.init(name: "screenshot.png", data: Data([1, 2]))], expectedAgent: target)
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(command.commandType)) == command.commandType)
        let legacy = try JSONDecoder().decode(SendDroppedFiles.self, from: Data(#"{"files":[]}"#.utf8))
        #expect(legacy.expectedAgent == nil)
        let oldState = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8))
        #expect(oldState.supportsAgentImageInput == nil)
        let state = SessionStateMessage(pairId: "a", paneStates: [:], supportsAgentImageInput: true).withPairId("b")
        #expect(state.supportsAgentImageInput == true)
        let tab = RemoteBrowserTab(id: UUID(), sessionName: "work", title: "Page", url: "about:blank",
                                   isLoading: false, isAgentOwned: true, sourceAgent: target)
        #expect(try JSONDecoder().decode(RemoteBrowserTab.self, from: JSONEncoder().encode(tab)) == tab)
        let request = BrowseBrowser(sessionName: "work", surfaceID: UUID(), operation: .create, sourcePaneID: "%1")
        #expect(try JSONDecoder().decode(BrowseBrowser.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func openFormsCannotReceiveAnImagePath() throws {
        var pane = pane()
        let target = try #require(AgentImageTarget(pane: pane))
        let states: [AgentState] = [
            .awaitingReplies(.init(questions: []), requestID: "question"),
            .awaitingPermission(.init(title: "Tool", description: "Allow?"), requestID: "permission"),
            .awaitingPlanApproval(.init(title: "Plan", plan: "Steps"), requestID: "plan"),
        ]
        for state in states {
            pane.agentSession?.state = state
            #expect(throws: AgentImageError.self) { try target.validate(pane) }
        }
    }

    @Test func guardedImagePayloadFitsTheExistingRelayBudget() throws {
        let target = try #require(AgentImageTarget(pane: pane()))
        let command = SendDroppedFiles(files: [.init(name: "browser.png", data: Data(repeating: 0, count: SendDroppedFiles.maxRawBytes))], expectedAgent: target)
        let encoded = try JSONEncoder().encode(CommandMessage(paneId: target.paneID, command: command.commandType))
        #expect(encoded.count * 4 / 3 + 8192 < RelayPayloadLimits.maxWebSocketFrameBytes)
    }
}
