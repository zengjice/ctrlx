import CtrlxNetworking
import Testing
@testable import CtrlxCommon

struct SessionStatusPresentationTests {
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
