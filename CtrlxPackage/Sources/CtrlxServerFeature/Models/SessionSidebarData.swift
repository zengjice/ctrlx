import CtrlxCommon
import CtrlxNetworking

/// Only values used by a row and its menus; unrelated pane changes compare equal.
struct SessionSidebarData: Equatable, Sendable {
    let sessionName: String
    let metadata: ActiveWindowMetadata
    let agentPaneID: String?
    let agent: AgentSession?
    let cliState: CLISessionState?
    let customDescription: String?
    let customColor: SessionColor?
    let customEmoji: String?
    let progress: TerminalProgressState?
    let telemetry: SessionTelemetry?
    let permissionMode: String?

    var displayedState: CLISessionState? {
        CLISessionState.displayed(override: cliState, agentState: agent?.state)
    }

    init(session: LocalTmuxSession, paneStates: [String: PaneState], includeTelemetry: Bool) {
        let states = session.windows.flatMap(\.panes).compactMap { paneStates[$0.paneId] }
        let primary = session.activeWindow?.activePane.flatMap { paneStates[$0.paneId] }
        let representative = states.representativeAgentPane
        self.sessionName = session.sessionName
        self.metadata = session.activeWindowMetadata(paneStates: paneStates)
        self.agentPaneID = representative?.paneId
        self.agent = representative?.agentSession
        self.cliState = states.lazy.compactMap(\.cliSessionState).first
        self.customDescription = primary?.customDescription
        self.customColor = primary?.customColor
        self.customEmoji = primary?.customEmoji
        self.progress = states.effectiveProgress
        self.telemetry = includeTelemetry ? representative?.telemetry : nil
        self.permissionMode = includeTelemetry ? representative?.permissionMode : nil
    }

    init(session: TmuxSession) {
        let states = session.windows.flatMap(\.panes)
        let representative = states.representativeAgentPane
        self.sessionName = session.sessionName
        self.metadata = session.activeWindowMetadata
        self.agentPaneID = representative?.paneId
        self.agent = representative?.agentSession
        self.cliState = states.lazy.compactMap(\.cliSessionState).first
        self.customDescription = session.customDescription
        self.customColor = session.customColor
        self.customEmoji = session.customEmoji
        self.progress = states.effectiveProgress
        self.telemetry = nil
        self.permissionMode = nil
    }
}
