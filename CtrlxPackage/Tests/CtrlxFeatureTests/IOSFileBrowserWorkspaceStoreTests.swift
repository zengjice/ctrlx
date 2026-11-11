import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon
@testable import CtrlxFeature

@MainActor @Suite("iOS Files workspace lifetime")
struct IOSFileBrowserWorkspaceStoreTests {
    @Test("Moving a live Files tab retains its upload; closing or replacing its Host/session cancels it", arguments: ["move", "close", "host", "server", "session"], [false, true])
    func uploadCatalogLifetime(change: String, keepsSourceSession: Bool) async throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        let hostID = UUID(), replacementHostID = UUID(), sourceSessionID = UUID(), replacementSessionID = UUID(), destinationSessionID = UUID()
        let windowIDs = [UUID(), UUID(), UUID()], paneIDs = [UUID(), UUID(), UUID()]
        let descriptor = HostFileTab(sessionName: "source", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host/target")
        func snapshot(updated: Bool) -> SessionStateMessage {
            let server = updated && change == "server" ? "replacement-server" : "server"
            let sessionID = updated && change == "session" ? replacementSessionID : sourceSessionID
            var tab = descriptor
            if updated, change == "move" {
                tab.sessionName = "destination"
            }
            let indices = (0..<3).filter { index in
                !updated || keepsSourceSession || (index != 1 && !(index == 0 && change == "close"))
            }
            let panes = indices.map { index in
                let destination = index == 2 || (index == 0 && updated && change == "move")
                return PaneState(
                    paneId: "%\(index + 1)", sessionName: destination ? "destination" : "source", windowIndex: index,
                    tmuxWindowId: "@\(index + 1)", currentPath: "/host/target", isActive: true,
                    workspaceIdentity: .init(serverID: server, sessionID: destination ? destinationSessionID : sessionID, windowID: windowIDs[index], paneID: paneIDs[index])
                )
            }
            return .init(
                pairId: "office", paneStates: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) }),
                supportsPaneFiles: true, fileTabs: updated && change == "close" ? [] : [tab],
                workspaceIdentity: .init(hostID: updated && change == "host" ? replacementHostID : hostID, serverID: server)
            )
        }
        let before = snapshot(updated: false), after = snapshot(updated: true)
        try #require(ViewerWorkspaceCatalog(state: before) != nil && ViewerWorkspaceCatalog(state: after) != nil)
        store.update(before, client: client)
        let tab = try #require(store.workspace(hostID: "office", sessionName: "source")?.tabs.first)
        defer { tab.cancelUploads() }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
        var blocked = false, allowFinish = false, cancelled = false, completed = false
        var filename = "", begins = 0, saves = 0
        let source = FileBrowserSource(id: "office", paneID: "%1") { operation in
            guard case let .upload(request) = operation else { throw FileBrowserError.message("Unexpected request") }
            switch request {
            case let .begin(_, directory, name, _):
                #expect(directory == "/host/target")
                filename = name
                begins += 1
                return .uploaded(offset: 0, path: nil)
            case let .append(_, offset, data):
                blocked = true
                while !allowFinish {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return .uploaded(offset: offset + data.count, path: nil)
            case .finish:
                completed = true
                return .uploaded(offset: png.count, path: "/host/target/\(filename)")
            case .cancel:
                cancelled = true
                return .uploaded(offset: 0, path: nil)
            }
        }
        tab.uploadSession.start(.image(.init(kind: .png, data: png)), directory: "/host/target", source: source) { saves += 1 }
        for _ in 0..<200 where !blocked {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(blocked)
        let upload = tab.uploadSession.upload
        store.update(after, client: client)
        if change == "move" {
            #expect(store.workspace(hostID: "office", sessionName: "destination")?.tabs.first === tab)
            #expect(store.workspace(hostID: "office", sessionName: "source")?.tabs.isEmpty ?? true)
            #expect((store.workspace(hostID: "office", sessionName: "source") != nil) == keepsSourceSession)
            #expect(tab.uploadSession.upload === upload)
            #expect(tab.uploadSession.directory == "/host/target")
        } else {
            #expect(store.workspace(hostID: "office", sessionName: "source")?.tabs.first !== tab)
        }
        allowFinish = true
        for _ in 0..<200 where tab.uploadSession.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!tab.uploadSession.isRunning)
        #expect(completed == (change == "move"))
        #expect(cancelled == (change != "move"))
        #expect(saves == (change == "move" ? 1 : 0))
        #expect(begins == 1)
        #expect(tab.uploadSession.upload.summary == (change == "move" ? "Image saved." : "Upload cancelled."))
    }

    @Test("Backgrounding cancels uploads in every hidden workspace; disconnect affects only its Host", arguments: [false, true])
    func hiddenUploadsAreCancelled(background: Bool) async throws {
        let store = IOSFileBrowserWorkspaceStore()
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII="))
        var started: Set<String> = [], cancelled: Set<String> = []
        var tabs: [FileBrowserTab] = []
        defer { tabs.forEach { $0.cancelUploads() } }
        for host in ["office", "home"] {
            let descriptor = descriptor()
            store.update(state([descriptor], host: host), client: ViewerRelayClient())
            let workspace = try #require(store.workspace(hostID: host, sessionName: "work"))
            let tab = workspace.adopt(descriptor)
            tabs.append(tab)
            workspace.selectedID = nil
            let source = FileBrowserSource(id: host, paneID: nil) { operation in
                guard case let .upload(request) = operation else { throw CancellationError() }
                switch request {
                case .begin: return .uploaded(offset: 0, path: nil)
                case .append:
                    started.insert(host)
                    while true {
                        try await Task.sleep(for: .seconds(1))
                    }
                case .cancel:
                    cancelled.insert(host)
                    return .uploaded(offset: 0, path: nil)
                case .finish: throw FileBrowserError.message("A blocked upload must not finish")
                }
            }
            tab.uploadSession.start(.image(.init(kind: .png, data: png)), directory: "/host", source: source) { }
        }
        for _ in 0..<200 where started.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(started.count == 2)
        if background {
            store.cancelUploads()
        } else {
            store.suspendHost("office")
        }
        for _ in 0..<200 where tabs[0].uploadSession.isRunning || (background && tabs[1].uploadSession.isRunning) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelled == (background ? ["office", "home"] : ["office"]))
        #expect(!tabs[0].uploadSession.isRunning)
        #expect(tabs[1].uploadSession.isRunning == !background)
        tabs[1].cancelUploads()
        for _ in 0..<200 where tabs[1].uploadSession.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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
