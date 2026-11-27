import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct SessionStatusPresentationTests {
    @Test("Async questions survive working updates, viewing and snapshot round trips")
    func asyncQuestionLifecycle() throws {
        var agent = AgentSession(paneId: "%1", pluginID: "codex", state: .working)
        agent.recordQuestion("session:first")
        agent.recordQuestion("session:first")
        agent.recordQuestion("session:second")
        agent.state = .working
        agent.markHandled()
        var pane = PaneState(paneId: "%1", sessionName: "work", agentSession: agent)
        pane = try JSONDecoder().decode(PaneState.self, from: JSONEncoder().encode(pane))
        #expect(pane.agentSession?.pendingQuestionIDs?.count == 2)
        #expect(pane.displayedState == .waiting)
        #expect([pane].pendingAttentionPanes.count == 1)
        #expect(SessionStatusPresentation(agent: pane.agentSession, cliState: nil, panes: [pane])?.indicator == .attention(.question))
        agent.resolveQuestion("session:first")
        #expect(agent.hasPendingQuestions && agent.isWorking)
        agent.resolveQuestion("session:second")
        pane.agentSession = agent
        #expect([pane].pendingAttentionPanes.isEmpty)
        #expect(SessionStatusPresentation(agent: agent, cliState: nil, panes: [pane])?.indicator == .working)
    }

    @Test("A terminal-only session shows waiting from its inactive pane")
    func inactiveTerminalPaneOverride() throws {
        let panes = [
            PaneState(paneId: "%1", sessionName: "work", isActive: true),
            PaneState(paneId: "%2", sessionName: "work", paneIndex: 1, cliSessionState: .waiting),
        ]
        let session = try #require(TmuxSession.groupWindows(TmuxWindow.groupPanes(panes)).first)
        let active = try #require(session.activeWindow?.activePane)
        #expect(active.paneId == "%1")
        #expect(active.cliSessionState == nil)

        let status = SessionStatusPresentation(agent: session.agentSession, cliState: session.cliSessionState, panes: panes)
        #expect(status?.indicator == .attention(.other))
        #expect(status?.label == "Waiting for input")
    }

    @Test("Session rows show questions in either pane order and honor manual overrides", arguments: [false, true])
    func questionPriority(questionFirst: Bool) {
        let states: [AgentState] = [
            .doneWorking(summary: nil),
            .awaitingReplies(.init(questions: []), requestID: "question"),
        ]
        let panes = (questionFirst ? Array(states.reversed()) : states).enumerated().map { index, state in
            let id = "%\(index)"
            return PaneState(paneId: id, agentSession: .init(paneId: id, state: state))
        }
        let agent = panes.representativeAgentPane?.agentSession
        let question = SessionStatusPresentation(agent: agent, cliState: nil, panes: panes)
        #expect(question?.indicator == .attention(.question))
        #expect(question?.label == "Questions")

        for cliState in CLISessionState.allCases {
            let overridden = SessionStatusPresentation(agent: agent, cliState: cliState, panes: panes)
            #expect(overridden == SessionStatusPresentation(cliState: cliState))
        }
    }
}
