import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor @Suite("iOS Files workspace lifetime")
struct IOSFileBrowserWorkspaceStoreTests {
    @Test("A Host catalog arriving before first entry cannot overwrite saved private tabs")
    func restorePrivateTabsAfterHostCatalog() throws {
        try withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let descriptor = descriptor()
            let snapshot = state([descriptor])
            let context = try #require(IOSFileBrowserWorkspace.Context(hostID: "office", windows: TmuxWindow.groupPanes(Array(snapshot.paneStates.values))))
            let legacy = FileBrowserTab(path: "/host/legacy")
            legacy.selectedFile = "/host/legacy/report.md"
            let old = IOSFileBrowserWorkspace()
            old.updateContext(context)
            old.tabs = [legacy]
            old.save()

            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            store.update(snapshot, client: client)
            let workspace = try #require(store.workspace(hostID: "office", sessionName: "work"))
            let hostModel = try #require(workspace.tabs.first)
            hostModel.navigate("/host/live")
            workspace.selectedID = hostModel.id
            workspace.updateContext(context)
            workspace.save()
            store.update(snapshot, client: client)
            workspace.updateContext(context)

            #expect(workspace.tabs.count == 2)
            #expect(workspace.selected === hostModel)
            #expect(hostModel.path == "/host/live")
            #expect(workspace.tabs.first { $0.id == legacy.id }?.selectedFile == legacy.selectedFile)
            #expect(workspace.snapshots.map(\.id) == [legacy.id])
            let coldRestore = IOSFileBrowserWorkspace()
            coldRestore.updateContext(context)
            #expect(coldRestore.snapshots == old.snapshots)
        }
    }

    private func descriptor(session: String = "work", pane: String = "%1", window: String = "@1") -> HostFileTab {
        .init(sessionName: session, windowID: window, sourcePaneID: pane, initialDirectory: "/host/project")
    }

    private func state(_ tabs: [HostFileTab], host: String = "office") -> SessionStateMessage {
        let panes = tabs.map {
            PaneState(
                paneId: $0.sourcePaneID,
                sessionName: $0.sessionName,
                windowIndex: 1,
                tmuxWindowId: $0.windowID,
                currentPath: "/host/project",
                isActive: true,
                isWindowActive: true
            )
        }
        return .init(
            pairId: host,
            paneStates: Dictionary(panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first }),
            supportsPaneFiles: true,
            fileTabs: tabs
        )
    }

    @Test("Tab/session re-entry and connection replacement retain the same model")
    func reentryAndReconnect() throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        let tab = descriptor()
        store.update(state([tab]), client: client)
        let workspace = try #require(store.workspace(hostID: "office", sessionName: "work"))
        let model = workspace.adopt(tab)
        for index in 0..<3 {
            workspace.selectedID = nil
            store.update(state([tab]), client: client)
            let reopened = try #require(store.workspace(hostID: "office", sessionName: "work"))
            #expect(reopened === workspace)
            let reused = reopened.adopt(tab)
            reused.openTerminalFile(.init(directory: "/host/output", file: "/host/output/\(index).md"), paneID: "%1")
            #expect(reused === model)
            #expect(reopened.tabs.count == 1)
        }
        store.suspendHost("office")
        #expect(workspace.tabs.first === model)
        store.update(state([tab]), client: ViewerRelayClient())
        #expect(workspace.adopt(tab) === model)
        #expect(model.path == "/host/output")
    }

    @Test("Session rename and pane migration preserve model and navigation")
    func routes() throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        var tab = descriptor()
        store.update(state([tab]), client: client)
        let original = try #require(store.workspace(hostID: "office", sessionName: "work")?.tabs.first)
        original.navigate("/host/child")
        tab.sessionName = "renamed"
        tab.windowID = "@2"
        store.update(state([tab]), client: client)
        let moved = try #require(store.workspace(hostID: "office", sessionName: "renamed")?.tabs.first)
        #expect(moved === original)
        #expect(moved.path == "/host/child")
        #expect(moved.hostTab == tab)
        #expect(store.workspace(hostID: "office", sessionName: "work") == nil)
    }

    @Test("Host close/restart replaces identities despite recycled pane IDs")
    func authoritativeClose() throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        let original = descriptor()
        store.update(state([original]), client: client)
        let workspace = try #require(store.workspace(hostID: "office", sessionName: "work"))
        workspace.selectedID = original.id
        let replacement = descriptor()
        store.update(state([replacement]), client: client)
        #expect(workspace.tabs.map(\.id) == [replacement.id])
        #expect(workspace.selectedID == nil)
        store.update(state([]), client: client)
        #expect(store.workspace(hostID: "office", sessionName: "work") == nil)
    }

    @Test("Even equal catalog IDs from different Hosts never share presentation")
    func hostIsolation() throws {
        let store = IOSFileBrowserWorkspaceStore()
        let tab = descriptor()
        store.update(state([tab]), client: ViewerRelayClient())
        store.update(state([tab], host: "home"), client: ViewerRelayClient())
        let office = try #require(store.workspace(hostID: "office", sessionName: "work")?.tabs.first)
        let home = try #require(store.workspace(hostID: "home", sessionName: "work")?.tabs.first)
        #expect(office !== home)
        office.navigate("/office")
        #expect(home.path == "/host/project")
        store.retainHosts(["home"])
        #expect(store.workspace(hostID: "office", sessionName: "work") == nil)
        #expect(store.workspace(hostID: "home", sessionName: "work")?.tabs.first === home)
    }
}
