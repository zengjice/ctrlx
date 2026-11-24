import CtrlxNetworking
import Testing
@testable import CtrlxCommon

@Suite("TmuxWindow attention")
struct TmuxWindowAttentionTests {
    @Test("A window needs attention when any pane's agent is waiting")
    func aggregatesPaneAttention() throws {
        let windows = TmuxWindow.groupPanes([
            PaneState(
                paneId: "%1", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1",
                agentSession: AgentSession(paneId: "%1", state: .idle)
            ),
            PaneState(
                paneId: "%2", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 1,
                agentSession: AgentSession(paneId: "%2", state: .awaitingReplies(
                    AskUserQuestionRequest(questions: []), requestID: "request-1"
                ))
            ),
            PaneState(
                paneId: "%3", sessionName: "work", windowIndex: 1, tmuxWindowId: "@2",
                agentSession: AgentSession(paneId: "%3", state: .working)
            ),
        ])

        let attentionWindow = try #require(windows.first(where: { $0.stableId == "@1" }))
        let workingWindow = try #require(windows.first(where: { $0.stableId == "@2" }))
        #expect(attentionWindow.needsAttention)
        #expect(workingWindow.needsAttention == false)
    }

    @Test("A question is shown ahead of completion in a split window")
    func questionTakesPriority() throws {
        let completed = PaneState(
            paneId: "%1", sessionName: "work", tmuxWindowId: "@1",
            agentSession: .init(paneId: "%1", state: .doneWorking(summary: nil))
        )
        let question = PaneState(
            paneId: "%2", sessionName: "work", tmuxWindowId: "@1", paneIndex: 1,
            agentSession: .init(paneId: "%2", state: .awaitingReplies(.init(questions: []), requestID: "question"))
        )

        let split = try #require(TmuxWindow.groupPanes([completed, question]).first)
        #expect(split.attention?.symbol == .questionmarkCircle)
        let done = try #require(TmuxWindow.groupPanes([completed]).first)
        #expect(done.attention?.symbol == .bellBadgeFill)
    }

    @Test("Handling a completed agent clears the window attention")
    func handledStateIsNotAttention() {
        var session = AgentSession(paneId: "%1", state: .doneWorking(summary: "Done"))
        session.markHandled()
        let window = TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", windowIndex: 0, agentSession: session),
        ]).first

        #expect(window?.needsAttention == false)
    }
}
