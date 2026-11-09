import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct TerminalContentMenuTests {
    @Test("A content menu retains its clicked pane's directory and Host")
    func clickedPane() throws {
        var pane = PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", currentPath: "/Host/clicked")
        let target = try #require(TerminalContentMenuTarget(hostID: "host-a", pane: pane))
        #expect(target.directory == "/Host/clicked")
        #expect(target.matches(hostID: "host-a", pane: pane))
        #expect(!target.matches(hostID: "host-b", pane: pane))
        #expect(!target.matches(hostID: nil, pane: pane))
        #expect(!target.matches(hostID: "host-a", pane: nil))
        pane.currentPath = "/Host/later"
        pane.windowIndex = 7
        #expect(target.matches(hostID: "host-a", pane: pane))
        #expect(target.directory == "/Host/clicked")
    }

    @Test("A moved or replacement pane invalidates the menu", arguments: ["server", "session", "window", "pane", "route", "name", "missing-identity"])
    func stalePane(change: String) throws {
        let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        var pane = PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", workspaceIdentity: identity)
        let target = try #require(TerminalContentMenuTarget(hostID: nil, pane: pane))
        #expect(target.matches(hostID: nil, pane: pane))
        switch change {
        case "server": pane.workspaceIdentity?.serverID = "replacement"
        case "session": pane.workspaceIdentity?.sessionID = UUID()
        case "window": pane.workspaceIdentity?.windowID = UUID()
        case "pane": pane.workspaceIdentity?.paneID = UUID()
        case "route": pane.tmuxWindowId = "@2"
        case "name": pane.sessionName = "other"
        default: pane.workspaceIdentity = nil
        }
        #expect(!target.matches(hostID: nil, pane: pane))
    }

    @Test("Discovery without a session cannot produce menu actions")
    func undiscoveredPane() {
        #expect(TerminalContentMenuTarget(hostID: nil, pane: .init(paneId: "%1")) == nil)
    }
}
