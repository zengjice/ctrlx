import Foundation
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

    @Test("Finished workflow history does not expand a session row", arguments: [AgentWorkflowRunStatus.completed, .ended])
    func finishedWorkflowsStayInHistory(status: AgentWorkflowRunStatus) {
        let panes = (0..<3).map { index in
            var pane = pane("%\(index)", .idle)
            pane.workflow = workflow("Workflow \(index)", status: status)
            return pane
        }
        #expect(panes.activeWorkflowStatuses.isEmpty)
        #expect(panes.compactMap(\.workflow).count == 3)
        #expect(panes.pendingAttentionPanes.isEmpty)
    }

    @Test("Active workflows remain visible once per run", arguments: [AgentWorkflowRunStatus.running, .finishing, .paused])
    func activeWorkflowsRemainVisible(status: AgentWorkflowRunStatus) {
        var first = pane("%1", .idle), sibling = pane("%2", .idle), second = pane("%3", .idle), completed = pane("%4", .idle)
        first.workflow = workflow("B", status: status, needsAttention: status == .paused)
        sibling.workflow = first.workflow
        second.workflow = workflow("A", status: status)
        completed.workflow = workflow("Finished", status: .completed)
        let panes = [first, sibling, second, completed]
        #expect(panes.activeWorkflowStatuses == [second.workflow, first.workflow].compactMap { $0 })
        if status == .paused {
            #expect(panes.pendingAttentionPanes.map(\.paneId) == [first.paneId])
        }
    }

    @Test("Hiding workflow history preserves unanswered questions")
    func questionsRemainActionable() {
        var pane = pane("%1", .working)
        pane.agentSession?.recordQuestion("question")
        pane.workflow = workflow("Finished", status: .completed)
        #expect([pane].activeWorkflowStatuses.isEmpty)
        #expect([pane].representativeAgentPane?.agentSession?.hasPendingQuestions == true)
        #expect([pane].pendingAttentionPanes.map(\.paneId) == [pane.paneId])
    }

    private func workflow(_ name: String, status: AgentWorkflowRunStatus, needsAttention: Bool = false) -> AgentWorkflowPaneStatus {
        let hostID = UUID(), node = AgentWorkflowNode(name: "Review", content: .init(text: "Review"))
        var run = AgentWorkflowRun(
            definition: .init(name: name, hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id),
            instances: [], createdAt: .distantPast, authorizationExpiresAt: .distantFuture
        )
        run.status = status
        return .init(run: run, hostID: hostID, needsAttention: needsAttention)
    }

    private func pane(_ id: String, _ state: AgentState) -> PaneState {
        PaneState(paneId: id, agentSession: AgentSession(paneId: id, state: state))
    }
}
