import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct TerminalNotificationContentTests {
    @Test(arguments: [nil, "host-a"] as [String?], ["Session Idle", "Permission: Bash", "Codex wants answers"])
    func nativeContentPreservesContextStatusAndRouting(hostID: String?, title: String) {
        let presentation = AgentNotificationPresentation(
            title: title, body: "intelligence-ui: Task details",
            paneState: PaneState(
                paneId: "%3", sessionName: "work", windowName: "review",
                agentSession: AgentSession(paneId: "%3", detectedProjectPath: "/Projects/intelligence-ui")
            )
        )
        let content = TerminalNotificationService.content(paneId: "%3", notification: presentation, hostId: hostID)

        #expect(content.title == "work · review")
        #expect(content.subtitle == (title == "Session Idle" ? "Finished" : title))
        #expect(content.body == "Task details")
        #expect(content.categoryIdentifier == "terminalNotification")
        #expect(content.userInfo["paneId"] as? String == "%3")
        #expect(content.userInfo["hostId"] as? String == hostID)
    }

    @Test
    func notificationsWithoutPaneMetadataKeepTheirOriginalCopy() {
        let presentation = AgentNotificationPresentation(title: "Custom alert", body: "Original body", paneState: nil)
        let content = TerminalNotificationService.content(paneId: "system", notification: presentation, hostId: nil)
        #expect(content.title == "Custom alert")
        #expect(content.subtitle.isEmpty)
        #expect(content.body == "Original body")
        #expect(content.userInfo["paneId"] as? String == "system")
        #expect(content.userInfo["hostId"] == nil)
    }

    @Test
    func acceptanceLogRetainsEventStatusAndHostRouting() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-notification-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let presentation = AgentNotificationPresentation(
            title: "Permission: Bash", body: "work: Needs approval",
            paneState: PaneState(paneId: "%3", sessionName: "work", windowName: "review")
        )
        TerminalNotificationService.e2eTest(logPath: log.path).showNotification("%3", presentation, "host-a")
        #expect(try String(contentsOf: log, encoding: .utf8) == "%3|work · review|Permission: Bash\nNeeds approval|host-a\n")
    }
}
