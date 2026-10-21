import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Agent notification presentation")
struct AgentNotificationPresentationTests {
    @Test(arguments: ["Session Idle", "Permission: Bash", "Codex wants answers", "Claude wants answers"])
    func hostAndViewerDeliveryKeepTheSamePresentation(title: String) throws {
        let pane = PaneState(
            paneId: "%3", sessionName: "work", windowName: "review",
            agentSession: AgentSession(paneId: "%3", detectedProjectPath: "/Projects/intelligence-ui")
        )
        let host = AgentNotificationPresentation(title: title, body: "intelligence-ui: Task details", paneState: pane)
        let push = NotificationContent(
            title: host.title, subtitle: host.subtitle, body: host.body,
            eventType: "cli.notify", pairId: "host-a", paneId: pane.paneId
        )
        let decodedPush = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(push))
        let live = AgentNotificationMessage(
            pairId: "host-a", sessionId: pane.paneId,
            title: host.title, subtitle: host.subtitle, body: host.body, timestamp: Date()
        )
        let decodedLive = try JSONDecoder().decode(AgentNotificationMessage.self, from: JSONEncoder().encode(live))

        #expect(host.title == "work · review")
        #expect(host.subtitle == (title == "Session Idle" ? "Finished" : title))
        #expect(host.body == "Task details")
        #expect(decodedPush.title == host.title)
        #expect(decodedPush.subtitle == host.subtitle)
        #expect(decodedPush.body == host.body)
        // Mac/iOS live delivery may have pane metadata already or receive the alert first.
        for metadata in [pane, nil] as [PaneState?] {
            #expect(AgentNotificationPresentation(
                title: decodedLive.title, subtitle: decodedLive.subtitle, body: decodedLive.body,
                paneState: metadata
            ) == host)
        }
    }

    @Test("Uses tmux context and removes a repeated project prefix")
    func tmuxContext() {
        let pane = PaneState(
            paneId: "%1",
            sessionName: "coding",
            windowName: "agent",
            agentSession: AgentSession(
                paneId: "%1",
                detectedProjectPath: "/Users/me/Projects/coding"
            )
        )

        let presentation = AgentNotificationPresentation(
            title: "Session Idle",
            body: "coding: Finished the change",
            paneState: pane
        )

        #expect(presentation.title == "coding · agent")
        #expect(presentation.subtitle == "Finished")
        #expect(presentation.body == "Finished the change")
    }

    @Test("Preserves an explicit status and falls back to the session name")
    func explicitStatus() {
        let pane = PaneState(paneId: "%1", sessionName: "coding")
        let presentation = AgentNotificationPresentation(
            title: "Codex wants answers",
            subtitle: "Needs input",
            body: "coding: Choose an option",
            paneState: pane
        )

        #expect(presentation.title == "coding")
        #expect(presentation.subtitle == "Needs input")
        #expect(presentation.body == "Choose an option")
    }

    @Test("Keeps legacy copy when pane metadata is unavailable")
    func missingPaneMetadata() {
        let presentation = AgentNotificationPresentation(
            title: "Session Idle",
            body: "coding: Finished the change",
            paneState: nil
        )

        #expect(presentation.title == "Session Idle")
        #expect(presentation.subtitle == nil)
        #expect(presentation.body == "coding: Finished the change")
    }

    @Test("Bounds contextual copy for the encrypted APNs envelope")
    func boundsContextCopy() {
        let pane = PaneState(
            paneId: "%1",
            sessionName: String(repeating: "会话", count: 100),
            windowName: String(repeating: "窗口", count: 100)
        )
        let presentation = AgentNotificationPresentation(
            title: String(repeating: "状态", count: 100),
            body: "Result",
            paneState: pane
        )

        #expect(presentation.title.utf8.count <= NotificationContent.maximumContextTitleBytes)
        #expect(presentation.title.hasSuffix("…"))
        #expect(
            presentation.subtitle?.utf8.count ?? 0
                <= NotificationContent.maximumContextSubtitleBytes
        )
        #expect(presentation.subtitle?.hasSuffix("…") == true)
    }
}
