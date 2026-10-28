import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor @Suite("iOS Files workspace lifetime")
struct IOSFileBrowserWorkspaceStoreTests {
    @Test("Independent Files keeps live navigation when the last terminal server disappears")
    func independentSessionLifetime() throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        let hostID = UUID(), sessionID = UUID()
        let session = ResourceSession(id: sessionID, name: "work", directory: "/host/project")
        let file = HostFileTab(sessionName: session.name, initialDirectory: session.directory, resourceSessionID: sessionID)
        let catalog = IndependentResourceCatalog(sessions: [session], files: [file])
        let before = SessionStateMessage(pairId: "office", paneStates: [:], workspaceIdentity: .init(hostID: hostID, serverID: "old"), independentResources: catalog)
        store.update(before, client: client)
        let original = try #require(store.workspace(hostID: "office", sessionName: "work"))
        original.tabs.first?.navigate("/host/other")
        original.selectedID = file.id
        let after = SessionStateMessage(pairId: "office", paneStates: [:], workspaceIdentity: .init(hostID: hostID, serverID: nil), independentResources: catalog)
        store.update(after, client: client)
        let retained = try #require(store.workspace(hostID: "office", sessionName: "work"))
        #expect(retained === original)
        #expect(retained.selected?.path == "/host/other")
        let replaced = SessionStateMessage(pairId: "office", paneStates: [:], workspaceIdentity: .init(hostID: UUID(), serverID: nil), independentResources: catalog)
        store.update(replaced, client: client)
        #expect(store.workspace(hostID: "office", sessionName: "work") !== original)
    }

    @Test("Independent Files ignores a migrated source reference to a closed terminal")
    func migratedSourceDoesNotDisableFiles() async throws {
        let hostID = UUID(), sessionID = UUID()
        let reference = ViewerWorkspaceReference(pairID: "office", hostID: hostID, sessionID: sessionID)
        var oldSource = reference
        oldSource.windowID = UUID()
        oldSource.paneID = UUID()
        let file = HostFileTab(sessionName: "work", initialDirectory: "/host/project", resourceSessionID: sessionID)
        let savedTab = FileBrowserTab(hostTab: file)
        savedTab.navigate("/host/nested")
        let snapshot = try #require(savedTab.snapshot)
        let saved = IOSWorkspaceRecoverySnapshot(sessions: [.init(reference: reference, name: "work", files: [.init(snapshot: snapshot, source: oldSource)])])
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory(saved)
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            let state = SessionStateMessage(pairId: "office", paneStates: [:], workspaceIdentity: .init(hostID: hostID, serverID: nil), independentResources: .init(sessions: [.init(id: sessionID, name: "work", directory: "/host/project")], files: [file]))
            store.update(state, client: client)
            let workspace = try #require(store.workspace(hostID: "office", sessionName: "work"))
            #expect(workspace.tabs.first?.path == "/host/nested")
            #expect(workspace.tabs.first?.sourcePaneID == nil)
            #expect(workspace.unavailableFileSources.isEmpty)
            workspace.save()
            await store.flushRecovery()
            #expect(store.recovery.sessions.first?.files.first?.source == nil)
        }
    }

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
        let panes = tabs.compactMap { tab -> PaneState? in
            guard let paneID = tab.sourcePaneID else { return nil }
            return PaneState(
                paneId: paneID,
                sessionName: tab.sessionName,
                windowIndex: 1,
                tmuxWindowId: tab.windowID,
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
