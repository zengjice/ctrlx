import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct WindowTabMenuStateTests {
    private func pane() -> PaneState {
        .init(
            paneId: "%1",
            sessionName: "work",
            tmuxWindowId: "@1",
            currentPath: "/repo",
            agentSession: .init(paneId: "%1", pluginID: "codex", processRuntimeID: "process-one"),
            claudeSessionID: UUID().uuidString,
            workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        )
    }

    private func state(_ pane: PaneState, hostID: String = "host", focusedPaneID: String? = "%1", files: [FileBrowserTab] = [], browsers: [RemoteBrowserTab] = []) -> WindowTabMenuState {
        .init(hostID: hostID, window: TmuxWindow.groupPanes([pane]).first, focusedPaneID: focusedPaneID, files: files, browsers: browsers, simulators: [])
    }

    @Test("Terminal activity and layout refreshes do not change the open menu")
    func terminalRefresh() {
        var pane = pane()
        let before = state(pane)
        pane.lastAgentActivityAt = .now
        pane.terminalTitle = "A tool is running"
        pane.width = 120
        pane.height = 40
        pane.windowLayout = "new layout"
        pane.gitBranch = "another-branch"
        pane.agentSession?.state = .working
        #expect(state(pane) == before)
    }

    @Test("A new conversation, process, pane, directory or plugin refreshes action targets", arguments: ["conversation", "process", "pane", "directory", "plugin", "active"])
    func targetChanges(change: String) {
        var pane = pane()
        let before = state(pane)
        switch change {
        case "conversation": pane.claudeSessionID = UUID().uuidString
        case "process": pane.agentSession?.processRuntimeID = "process-two"
        case "pane": pane.workspaceIdentity?.paneID = UUID()
        case "directory": pane.currentPath = "/another/repo"
        case "plugin": pane.agentSession?.pluginID = "claude-code"
        default: pane.isActive.toggle()
        }
        #expect(state(pane) != before)
    }

    @Test("Host, focus and availability changes must not reuse stale menu actions")
    func availabilityChanges() {
        let pane = pane()
        let before = state(pane)
        #expect(state(pane, hostID: "another-host") != before)
        #expect(state(pane, focusedPaneID: nil) != before)
        var after = before
        after.isConnected = true
        #expect(after != before)
        after = before
        after.canTrustHooks = true
        #expect(after != before)
        after = before
        after.restartingAgentPaneIDs = [pane.paneId]
        #expect(after != before)
        after = before
        after.logoutUnavailableReason = "Update this Host"
        #expect(after != before)
    }

    @Test("Browser loading and unrelated tabs do not reset the menu; visible tab changes do")
    func resourceRefresh() {
        let pane = pane()
        let id = UUID()
        func browser(title: String = "Page", loading: Bool = false, source: String = "%1") -> RemoteBrowserTab {
            .init(id: id, sessionName: "work", title: title, url: loading ? "https://new.invalid" : "https://old.invalid", isLoading: loading, isAgentOwned: false, sourcePaneID: source)
        }
        let before = state(pane, browsers: [browser()])
        #expect(state(pane, browsers: [browser(loading: true)]) == before)
        #expect(state(pane, browsers: [browser(), browser(title: "Other window", source: "%9")]) == before)
        #expect(state(pane, browsers: [browser(title: "New title")]) != before)
        #expect(state(pane) != before)
        #expect(state(pane, browsers: [browser(source: "%9")]) != before)
    }

    @Test("Files labels are captured as values, not aliased through the mutable tab")
    func fileSnapshot() {
        let pane = pane()
        let id = UUID()
        let file = FileBrowserTab(hostTab: .init(id: id, sessionName: "work", sourcePaneID: "%1", initialDirectory: "/repo"))
        let before = state(pane, files: [file])
        file.query = "search text"
        #expect(state(pane, files: [file]) == before)
        file.updateHostTab(.init(id: id, sessionName: "work", sourcePaneID: "%9", initialDirectory: "/repo"))
        #expect(state(pane, files: [file]) != before)
    }
}
