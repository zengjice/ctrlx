import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("PaneState.agentRowTitle")
struct PaneStateAgentRowTitleTests {
    @Test("The session name leads and description remains visible")
    func sessionNameWithDescription() {
        let pane = PaneState(
            paneId: "%1",
            sessionName: "work",
            customDescription: "My feature work",
            agentSession: AgentSession(paneId: "%1", detectedProjectPath: "/Users/me/Dev/CtrlX")
        )
        #expect(pane.agentRowTitle == "work — My feature work")
    }

    @Test("Without a description the project is appended; empty counts as unset")
    func appendsProjectName() {
        let project = PaneState(
            paneId: "%1",
            sessionName: "work",
            customDescription: "",
            agentSession: AgentSession(paneId: "%1", detectedProjectPath: "/Users/me/Dev/CtrlX")
        )
        #expect(project.agentRowTitle == "work — CtrlX")

        let bare = PaneState(paneId: "%2", sessionName: "scratch", agentSession: AgentSession(paneId: "%2"))
        #expect(bare.agentRowTitle == "scratch — %2")
    }

    @Test("An unreconciled pane falls back to the agent display name")
    func missingSessionNameFallback() {
        let pane = PaneState(
            paneId: "%1",
            customDescription: "Description",
            agentSession: AgentSession(paneId: "%1", detectedProjectPath: "/Users/me/Dev/CtrlX")
        )
        #expect(pane.agentRowTitle == "CtrlX")
    }

    @Test("A pane without an agent session has no agent row title")
    func nilWithoutAgent() {
        #expect(PaneState(paneId: "%1", customDescription: "desc").agentRowTitle == nil)
    }
}
