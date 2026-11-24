import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxServerFeature

struct SessionSidebarDataTests {
    private func session() -> LocalTmuxSession {
        let panes = ["%1", "%2"].enumerated().map { index, id in
            PaneInfo(paneId: id, target: "work:0.\(index)", sessionName: "work", windowIndex: 0, paneIndex: index, command: "zsh", currentPath: "/repo", width: 80, height: 24, isActive: index == 0, windowName: "main", isWindowActive: true)
        }
        return LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))[0]
    }

    @Test("Inactive pane attention, manual state and real progress retain their existing priorities")
    func stateProjection() {
        let session = session()
        let states: [String: PaneState] = [
            "%1": .init(paneId: "%1", customDescription: "My session", customEmoji: "🐈", terminalTitle: "Active title", agentSession: .init(paneId: "%1", state: .working), progress: .normal(40)),
            "%2": .init(paneId: "%2", agentSession: .init(paneId: "%2", state: .doneWorking(summary: nil)), cliSessionState: .idle),
        ]
        let data = SessionSidebarData(session: session, paneStates: states, includeTelemetry: true)
        #expect(data.agentPaneID == "%2")
        #expect(data.agent?.state == .doneWorking(summary: nil))
        #expect(data.displayedState == .idle)
        #expect(data.progress == .normal(40))
        #expect(data.metadata.terminalTitle == "Active title")
        #expect(data.customDescription == "My session")
        #expect(data.customEmoji == "🐈")
    }

    @Test("Host and Viewer rows observe a question from a nonrepresentative pane")
    func questionOnSiblingPane() {
        let local = session()
        let completed = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(
            paneId: "%1", state: .doneWorking(summary: nil)
        ))
        var sibling = PaneState(paneId: "%2", sessionName: "work", paneIndex: 1, agentSession: .init(paneId: "%2"))

        func rows() -> [SessionSidebarData] {
            let windows = TmuxWindow.groupPanes([completed, sibling])
            return [
                .init(session: local, paneStates: ["%1": completed, "%2": sibling], includeTelemetry: false),
                .init(session: TmuxSession.groupWindows(windows)[0]),
            ]
        }

        let completedRows = rows()
        #expect(completedRows.map(\.status?.label) == ["Done", "Done"])
        sibling.agentSession?.state = .awaitingReplies(.init(questions: []), requestID: "question")
        let questionRows = rows()
        #expect(questionRows.map(\.status?.label) == ["Questions", "Questions"])
        #expect(questionRows.map(\.agentPaneID) == ["%1", "%1"])
        #expect(questionRows != completedRows)

        sibling.cliSessionState = .idle
        #expect(rows().map(\.status?.label) == ["Idle", "Idle"])
    }

    @Test("Unrelated panes and hidden telemetry do not change row inputs")
    func unrelatedChanges() {
        let session = session()
        var states: [String: PaneState] = ["%1": .init(paneId: "%1", agentSession: .init(paneId: "%1", state: .idle))]
        let original = SessionSidebarData(session: session, paneStates: states, includeTelemetry: false)
        states["%99"] = .init(paneId: "%99", terminalTitle: "Other session", agentSession: .init(paneId: "%99", state: .working))
        states["%1"]?.telemetry = .init(tokensUsed: 50, costUSD: 0.1, model: "model")
        states["%1"]?.permissionMode = "default"
        #expect(SessionSidebarData(session: session, paneStates: states, includeTelemetry: false) == original)
        #expect(SessionSidebarData(session: session, paneStates: states, includeTelemetry: true) != original)
        states["%1"]?.terminalTitle = "New title"
        #expect(SessionSidebarData(session: session, paneStates: states, includeTelemetry: false) != original)
    }

    @Test("Viewer row keeps session-scoped metadata from nonactive panes")
    func remoteProjection() {
        let panes: [PaneState] = [
            .init(paneId: "%1", sessionName: "work", isActive: true, terminalTitle: "Active"),
            .init(paneId: "%2", sessionName: "work", paneIndex: 1, customDescription: "Shared", customEmoji: "🐈", agentSession: .init(paneId: "%2", state: .working), progress: .normal(70)),
        ]
        let session = TmuxSession.groupWindows(TmuxWindow.groupPanes(panes))[0]
        let data = SessionSidebarData(session: session)
        #expect(data.customDescription == "Shared")
        #expect(data.metadata.terminalTitle == "Active")
        #expect(data.agentPaneID == "%2")
        #expect(data.progress == .normal(70))
    }
}
