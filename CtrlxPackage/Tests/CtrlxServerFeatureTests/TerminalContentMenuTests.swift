import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct TerminalContentMenuTests {
    @MainActor
    @Test("Split shortcuts prefer native focus only on the same Host", arguments: [true, false], ["host-a", "host-b"])
    func splitShortcutFocus(visible: Bool, endpointHost: String) throws {
        let active = PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", paneIndex: 0, currentPath: "/active", isActive: true)
        let focused = PaneState(paneId: "%2", sessionName: "work", tmuxWindowId: "@1", paneIndex: 1, currentPath: "/focused")
        let endpoint = TerminalQuickActionEndpoint(hostID: endpointHost, paneID: "%2", isVisible: { visible }, enqueue: { _ in })
        let target = try #require(TerminalContentMenuTarget.focused(hostID: "host-a", sessionName: "work", windowID: "@1", panes: [active, focused], endpoint: endpoint))
        let usesFocus = visible && endpointHost == "host-a"
        #expect(target.paneID == (usesFocus ? "%2" : "%1"))
        #expect(target.directory == (usesFocus ? "/focused" : "/active"))
    }

    @MainActor
    @Test("A split shortcut stays in the selected window and session")
    func splitShortcutScope() throws {
        let other = PaneState(paneId: "%1", sessionName: "other", tmuxWindowId: "@1", paneIndex: 0, isActive: true)
        let first = PaneState(paneId: "%2", sessionName: "work", tmuxWindowId: "@2", paneIndex: 0)
        let second = PaneState(paneId: "%3", sessionName: "work", tmuxWindowId: "@2", paneIndex: 1)
        let endpoint = TerminalQuickActionEndpoint(hostID: nil, paneID: "%1", isVisible: { true }, enqueue: { _ in })
        let target = try #require(TerminalContentMenuTarget.focused(hostID: nil, sessionName: "work", windowID: "@2", panes: [second, other, first], endpoint: endpoint))
        #expect(target.paneID == "%2")
        #expect(TerminalContentMenuTarget.focused(hostID: nil, sessionName: "work", windowID: "@1", panes: [other], endpoint: endpoint) == nil)
    }

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

    @Test("A window menu can rename with a surviving pane and rejects a reused window route")
    func windowRenameTarget() throws {
        var identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let original = PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", workspaceIdentity: identity)
        let target = try #require(TerminalContentMenuTarget(hostID: nil, pane: original))
        identity.paneID = UUID()
        var sibling = PaneState(paneId: "%2", sessionName: "work", tmuxWindowId: "@1", workspaceIdentity: identity)
        #expect(target.matchesWindow(pane: sibling))
        #expect(!target.matches(hostID: nil, pane: sibling))
        sibling.workspaceIdentity?.windowID = UUID()
        #expect(!target.matchesWindow(pane: sibling))
    }

    @Test("Discovery without a session cannot produce menu actions")
    func undiscoveredPane() {
        #expect(TerminalContentMenuTarget(hostID: nil, pane: .init(paneId: "%1")) == nil)
    }
}
