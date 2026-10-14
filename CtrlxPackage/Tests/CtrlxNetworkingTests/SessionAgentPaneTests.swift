import Testing
@testable import CtrlxNetworking

@Suite("Session representative agent")
struct SessionAgentPaneTests {
    @Test("A working sibling outranks an idle first pane")
    func workingSibling() {
        let panes = [pane("%1", .idle), pane("%2", .working)]
        #expect(panes.representativeAgentPane?.paneId == "%2")
        #expect(panes.effectiveProgress == .indeterminate)
    }

    @Test("Attention outranks working regardless of pane order", arguments: [
        AgentState.doneWorking(summary: nil),
        .awaitingPermission(PermissionRequest(title: "Bash", description: "ls"), requestID: "request"),
    ])
    func attentionWins(state: AgentState) {
        let panes = [pane("%1", .working), pane("%2", state), pane("%3", .idle)]
        #expect(panes.representativeAgentPane?.paneId == "%2")
        #expect(Array(panes.reversed()).representativeAgentPane?.paneId == "%2")
    }

    @Test("Equal priorities keep the first agent in window and pane order", arguments: [
        AgentState.idle, .working, .doneWorking(summary: nil),
    ])
    func stableTies(state: AgentState) {
        let panes = [PaneState(paneId: "%0"), pane("%1", state), pane("%2", state)]
        #expect(panes.representativeAgentPane?.paneId == "%1")
    }

    @Test("Terminal progress does not manufacture an agent working state")
    func terminalProgressIsIndependent() {
        let panes = [pane("%1", .idle), PaneState(paneId: "%2", progress: .normal(42))]
        #expect(panes.representativeAgentPane?.agentSession?.state == .idle)
        #expect(panes.effectiveProgress == .normal(42))
        #expect([PaneState(paneId: "%3")].representativeAgentPane == nil)
    }

    private func pane(_ id: String, _ state: AgentState) -> PaneState {
        PaneState(paneId: id, agentSession: AgentSession(paneId: id, state: state))
    }
}
