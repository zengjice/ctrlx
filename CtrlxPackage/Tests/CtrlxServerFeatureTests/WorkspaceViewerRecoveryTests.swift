import AppKit
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceViewerRecoveryTests {
    private let root = UUID()
    private let sessionID = UUID()
    private let windowIDs = [UUID(), UUID()]
    private let paneIDs = [UUID(), UUID()]
    private let fileID = UUID()

    private func state(server: String = "100:1", name: String = "project", offset: Int = 0, host: UUID? = nil, files: Bool = true, shared: SharedTerminalLayout? = nil, indices: [Int] = [0, 1]) -> SessionStateMessage {
        let panes = indices.map { index in
            PaneState(
                paneId: "%\(index + offset)",
                sessionName: name,
                windowIndex: index,
                tmuxWindowId: "@\(index + offset)",
                currentPath: "/Host/project",
                isActive: true,
                workspaceIdentity: .init(serverID: server, sessionID: sessionID, windowID: windowIDs[index], paneID: paneIDs[index])
            )
        }
        return .init(
            pairId: "pair",
            paneStates: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) }),
            sharedTerminalLayouts: shared.map { [name: $0] },
            fileTabs: files ? [.init(id: fileID, sessionName: name, windowID: "@\(offset)", sourcePaneID: "%\(offset)", initialDirectory: "/Host/project")] : [],
            workspaceIdentity: .init(hostID: host ?? root, serverID: server)
        )
    }

    private func selectionScene(isMain: Bool = false) throws -> WorkspaceRecoveryScene {
        let catalog = try #require(ViewerWorkspaceCatalog(state: state()))
        let descriptor = try #require(state().fileTabs?.first)
        let file = FileBrowserTab(hostTab: descriptor)
        return .init(id: UUID(), isMain: isMain, sessions: [.init(
            hostID: "pair", sessionID: sessionID, sessionName: "project",
            layout: .init(
                fileTabs: [.init(id: fileID, path: "Files", directoryPath: "", browser: file.snapshot)],
                tabOrder: [.window(index: 0), .file(id: fileID), .window(index: 1)]
            ), windowIDs: [0: windowIDs[0], 1: windowIDs[1]], ownedWindowIDs: windowIDs,
            focusedRight: false, selectedWindowID: windowIDs[1],
            remoteReference: catalog.reference(sessionName: "project")
        )], selectedSessionID: sessionID, selectedHostID: "pair")
    }

    @Test("A detached terminal selected before restart becomes selected when its identity arrives later")
    func lateSelectedTerminal() throws {
        var scene = try selectionScene()
        scene.sessions[0].layout.rightSide = [.file(id: fileID)]
        scene.sessions[0].layout.selectedRight = .file(id: fileID)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, indices: [0]), windows: windows)
        let store = try #require(windows.workspaces[scene.id]?.tabs)
        let tabs = try #require(store.existing(hostID: "pair", session: "project"))
        tabs.isRightPaneFocused = true
        store.restoredSelection = nil
        store.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@20")
        let pending = try #require(recovery.capture(windows: windows).first { $0.id == scene.id }?.sessions.first)
        #expect(pending.selectedWindowID == windowIDs[1])
        #expect(!pending.focusedRight)
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(store.restoredSelection == .init(hostID: "pair", sessionName: "project", windowID: "@21"))
        #expect(!tabs.isRightPaneFocused)
        store.restoredSelection = nil
        store.recoverySelection?.windowID = "@21"
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(store.restoredSelection == nil, "Later snapshots must not repeat a completed selection")
    }

    @Test("A late Files selection survives an automatic right-pane terminal fallback")
    func lateSelectedFile() throws {
        var scene = try selectionScene()
        scene.sessions[0].focusedRight = true
        scene.sessions[0].layout.rightSide = [.file(id: fileID), .window(index: 0)]
        scene.sessions[0].layout.selectedRight = .file(id: fileID)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, files: false), windows: windows)
        let tabs = try #require(windows.workspaces[scene.id]?.tabs.existing(hostID: "pair", session: "project"))
        tabs.selectedRight = .window("@20")
        tabs.isRightPaneFocused = false
        let pending = try #require(recovery.capture(windows: windows).first { $0.id == scene.id }?.sessions.first)
        #expect(pending.layout.selectedRight == .file(id: fileID))
        #expect(pending.focusedRight)
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(tabs.selectedRight == .file(fileID))
        #expect(tabs.isRightPaneFocused)
    }

    @Test("A late left Files selection replaces only an automatic fallback", arguments: [false, true])
    func lateLeftFile(userInteracted: Bool) throws {
        var scene = try selectionScene(isMain: true)
        scene.sessions[0].layout.selectedLeft = .file(id: fileID)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, files: false), windows: windows)
        let store = windows.mainTabs
        let tabs = try #require(store.existing(hostID: "pair", session: "project"))
        let browser = BrowserTab(url: URL(staticString: "https://example.com"))
        tabs.openBrowserTabs = [browser]
        tabs.selectedBrowserTabId = browser.id
        if userInteracted {
            store.userDidSelectTab(hostID: "pair", session: "project")
        }
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(tabs.selectedFileTabId == (userInteracted ? nil : fileID))
        #expect(tabs.selectedBrowserTabId == (userInteracted ? browser.id : nil))
        #expect(tabs.directoryTabs[fileID] != nil)
    }

    @Test("Choosing the fallback terminal cancels a late selection, including across a session rename", arguments: [false, true])
    func userSelectedTerminal(rename: Bool) throws {
        let scene = try selectionScene()
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, files: false, indices: [0]), windows: windows)
        let store = try #require(windows.workspaces[scene.id]?.tabs)
        store.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@20")
        store.userDidSelectTab(hostID: "pair", session: "project")
        let name = rename ? "renamed" : "project"
        recovery.update(state(server: "200:2", name: name, offset: 20), windows: windows)
        #expect(store.restoredSelection?.windowID != "@21")
        #expect(store.recoverySelection?.windowID == "@20")
        #expect(store.tabSelectionRevision(hostID: "pair", session: name) == 1)
        #expect(windows.owner(hostID: "pair", windowID: "@21") == scene.id)
        let saved = try #require(recovery.capture(windows: windows).first { $0.id == scene.id }?.sessions.first)
        #expect(saved.selectedWindowID == windowIDs[0])
    }

    @Test("A new Host incarnation remaps the user's latest choice rather than the original pending selection")
    func userSelectionAcrossHostRestart() throws {
        let scene = try selectionScene()
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, files: false, indices: [0]), windows: windows)
        let store = try #require(windows.workspaces[scene.id]?.tabs)
        store.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@20")
        store.userDidSelectTab(hostID: "pair", session: "project")
        recovery.update(state(server: "300:3", offset: 40), windows: windows)
        #expect(store.restoredSelection == .init(hostID: "pair", sessionName: "project", windowID: "@40"))
        #expect(windows.owner(hostID: "pair", windowID: "@41") == scene.id)
        #expect(windows.owner(hostID: "pair", windowID: "@40") == scene.id)
        #expect(store.existing(hostID: "pair", session: "project")?.directoryTabs[fileID] != nil)
    }

    @Test("Explicit right-pane choices remain selected when the saved Files tab arrives", arguments: ["terminal", "file", "browser"])
    func userSelectedRightTab(kind: String) throws {
        var scene = try selectionScene()
        scene.sessions[0].layout.rightSide = [.file(id: fileID), .window(index: 0)]
        scene.sessions[0].layout.selectedRight = .file(id: fileID)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, files: false), windows: windows)
        let store = try #require(windows.workspaces[scene.id]?.tabs)
        let tabs = try #require(store.existing(hostID: "pair", session: "project"))
        let choice: TabDragPayload
        if kind == "file" {
            let file = FileBrowserTab(path: "/Host/new-choice", sourcePaneID: "%20")
            tabs.directoryTabs[file.id] = file
            tabs.openFileTabs.append(.init(id: file.id, path: "Files", directoryPath: "", isDirectory: true))
            choice = .file(file.id)
        } else if kind == "browser" {
            let browser = BrowserTab(url: URL(staticString: "https://example.com"))
            tabs.openBrowserTabs.append(browser)
            choice = .browser(browser.id)
        } else {
            choice = .window("@20")
        }
        tabs.rightSide.insert(choice)
        tabs.selectedRight = choice
        store.userDidSelectTab(hostID: "pair", session: "project")
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(tabs.selectedRight == choice)
        #expect(tabs.directoryTabs[fileID] != nil, "Cancelling selection must not discard the late Files tab")
        #expect(Array(tabs.tabOrder.prefix(3)) == [.window("@20"), .file(fileID), .window("@21")])
    }

    @Test("Navigating away before the Host connects cancels the saved native-window selection", arguments: [nil, "pair", "another-pair"] as [String?])
    func userSelectedAnotherSession(hostID: String?) throws {
        let scene = try selectionScene(isMain: true)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        let store = windows.mainTabs
        store.userDidSelectSession()
        let choice = WorkbenchTabStore.Selection(hostID: hostID, sessionName: "other", windowID: "@80")
        store.recoverySelection = choice
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(store.restoredSelection == nil)
        #expect(store.recoverySelection == choice)
        #expect(store.existing(hostID: "pair", session: "project")?.directoryTabs[fileID] != nil)
    }

    @Test("Private tabs chosen before the first catalog survive initial restoration")
    func userSelectedBeforeCatalog() throws {
        var scene = try selectionScene(isMain: true)
        scene.sessions[0].layout.selectedLeft = .file(id: fileID)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        let store = windows.mainTabs, tabs = store.tabs(hostID: "pair", session: "project")
        let file = FileBrowserTab(path: "/Host/user-choice", sourcePaneID: "%20")
        tabs.openFileTabs = [.init(id: file.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.directoryTabs[file.id] = file
        tabs.selectedFileTabId = file.id
        store.userDidSelectTab(hostID: "pair", session: "project")
        recovery.update(state(server: "200:2", offset: 20), windows: windows)
        #expect(tabs.directoryTabs[file.id] === file)
        #expect(tabs.selectedFileTabId == file.id)
        #expect(tabs.directoryTabs[fileID] != nil)
        #expect(store.restoredSelection == nil)
    }

    @Test("Main-window restoration uses the live Host terminal selection")
    func sharedSelectionWins() throws {
        let scene = try selectionScene(isMain: true)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        recovery.update(state(server: "200:2", offset: 20, shared: .init(leftWindowId: "@20", rightWindowIds: ["@21"], selectedRightWindowId: "@21", splitRatio: 0.6, revision: 1)), windows: windows)
        #expect(windows.mainTabs.restoredSelection?.windowID == "@20")
        let tabs = try #require(windows.mainTabs.existing(hostID: "pair", session: "project"))
        #expect(tabs.selectedRight == .window("@21"))
    }

    @Test("Remote ownership, selection and Files survive a renamed Host session and recycled runtime IDs")
    func reconstruction() throws {
        let recovery = WorkspaceViewerRecovery(), owner = DetachedTerminalWindows()
        recovery.restore(nil, windows: owner)
        owner.restoredMainFrame = .init(x: 100, y: 150, width: 900, height: 700)
        recovery.update(state(), windows: owner)
        let tabs = owner.mainTabs.tabs(hostID: "pair", session: "project")
        tabs.tabOrder = [.window("@0"), .window("@1")]
        let target = try #require(DetachedTerminalTarget(hostID: "pair", windowID: "@1"))
        let detached = try #require(owner.detach(target, position: nil, session: { _ in "project" }))
        owner.mainTabs.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@0")
        detached.tabs.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@1")
        let descriptor = try #require(state().fileTabs?.first)
        owner.syncFileTabs(hostID: "pair", descriptors: [descriptor], sessionWindows: ["project": ["@0", "@1"]])
        tabs.directoryTabs[fileID]?.navigate("/Host/private")
        tabs.selectedFileTabId = fileID
        tabs.scrollOffsets[fileID] = 84
        let snapshot = recovery.capture(windows: owner)
        #expect(snapshot.flatMap(\.sessions).allSatisfy { $0.remoteReference?.hostID == root })
        var journal = WorkspaceRecoveryStoreTests.snapshot()
        journal.viewerScenes = snapshot
        try journal.validate()
        let decoded = try JSONDecoder().decode(WorkspaceRecoverySnapshot.self, from: JSONEncoder().encode(journal))
        #expect(decoded.viewerScenes == snapshot)

        let restored = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        restored.restore(snapshot, windows: windows)
        #expect(windows.restoredMainFrame == owner.restoredMainFrame)
        #expect(!restored.allowsRendering(hostID: "pair", session: "project", store: windows.mainTabs))
        restored.update(state(server: "200:2", name: "renamed", offset: 20), windows: windows)
        #expect(windows.owner(hostID: "pair", windowID: "@21") == detached.id)
        #expect(windows.mainTabs.restoredSelection?.windowID == "@20")
        let result = try #require(windows.mainTabs.existing(hostID: "pair", session: "renamed"))
        #expect(result.directoryTabs[fileID]?.path == "/Host/private")
        #expect(result.directoryTabs[fileID]?.sourcePaneID == "%20")
        #expect(result.selectedFileTabId == fileID && result.scrollOffsets[fileID] == 84)
        #expect(restored.allowsRendering(hostID: "pair", session: "renamed", store: windows.mainTabs))
        #expect(windows.restoredWindowIDs == [detached.id])
        result.directoryTabs[fileID]?.navigate("/Host/new-edit")
        restored.update(state(server: "200:2", name: "renamed", offset: 20), windows: windows)
        #expect(result.directoryTabs[fileID]?.path == "/Host/new-edit")
        #expect(windows.restoredWindowIDs == [detached.id])
    }

    @Test("Offline snapshots and replacement Host roots preserve records without attaching them to recycled names")
    func replacement() {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        let tabs = windows.mainTabs.tabs(hostID: "pair", session: "project")
        let file = FileBrowserTab(path: "/Host/private", sourcePaneID: "%0")
        tabs.directoryTabs[file.id] = file
        tabs.openFileTabs = [.init(id: file.id, path: "Files", directoryPath: "", isDirectory: true)]
        windows.mainTabs.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@0")
        let saved = recovery.capture(windows: windows)
        recovery.suspend("pair", windows: windows)
        #expect(recovery.capture(windows: windows) == saved)
        recovery.update(state(host: UUID()), windows: windows)
        #expect(!recovery.allowsRendering(hostID: "pair", session: "project", store: windows.mainTabs))
        #expect(windows.mainTabs.existing(hostID: "pair", session: "project") == nil)
        #expect(recovery.scenes.flatMap(\.sessions).contains { $0.remoteReference?.hostID == root })
        recovery.selectSession(hostID: "pair", session: "project", store: windows.mainTabs)
        #expect(recovery.allowsRendering(hostID: "pair", session: "project", store: windows.mainTabs))
        #expect(windows.mainTabs.existing(hostID: "pair", session: "project") == nil, "A deliberate new selection starts without the old Host's private Files")
    }

    @Test("Live session rename follows stable identity without losing private state or selecting another session")
    func liveRename() throws {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        let tabs = windows.mainTabs.tabs(hostID: "pair", session: "project")
        windows.mainTabs.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@1")
        recovery.update(state(name: "renamed"), windows: windows)
        windows.renameSession(hostID: "pair", from: "project", to: "renamed", windowIDs: [:])
        #expect(windows.mainTabs.existing(hostID: "pair", session: "renamed") === tabs)
        #expect(windows.mainTabs.existing(hostID: "pair", session: "project") == nil)
        #expect(windows.mainTabs.restoredSelection == .init(hostID: "pair", sessionName: "renamed", windowID: "@1"))
        #expect(windows.mainTabs.restorationRevision > 0)
        #expect(windows.mainTabs.remoteRecoveryReferences[.init(hostId: "pair", sessionName: "renamed")]?.sessionID == sessionID)
        let saved = try #require(recovery.capture(windows: windows).first { $0.isMain }?.sessions.first)
        #expect(saved.sessionName == "renamed" && saved.sessionID == sessionID)
    }

    @Test("Closing an offline detached window saves returned private tabs under the main window")
    func closeOfflineWindow() throws {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(files: false), windows: windows)
        let target = try #require(DetachedTerminalTarget(hostID: "pair", windowID: "@1"))
        let detached = try #require(windows.detach(target, position: nil, session: { _ in "project" }))
        let tabs = detached.tabs.tabs(hostID: "pair", session: "project")
        let file = FileBrowserTab(path: "/Host/private", sourcePaneID: "%1")
        tabs.openFileTabs = [.init(id: file.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.directoryTabs[file.id] = file
        tabs.tabOrder = [.window("@1"), .file(file.id)]
        recovery.suspend("pair", windows: windows)
        let native = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        windows.attach(native, to: target)
        windows.didClose(target, window: native)
        let saved = recovery.capture(windows: windows)
        #expect(!saved.contains { $0.id == detached.id })
        let main = try #require(saved.first { $0.isMain }?.sessions.first)
        #expect(main.layout.fileTabs.first?.browser?.path == "/Host/private")
        #expect(main.fileSources?[file.id]?.paneID == paneIDs[1])
        #expect(Set(main.ownedWindowIDs) == Set(windowIDs))
        let restored = WorkspaceViewerRecovery(), restoredWindows = DetachedTerminalWindows()
        restored.restore(saved, windows: restoredWindows)
        restored.update(state(server: "200:2", offset: 30, files: false), windows: restoredWindows)
        #expect(restoredWindows.workspaces.isEmpty)
        #expect(restoredWindows.mainTabs.existing(hostID: "pair", session: "project")?.directoryTabs[file.id]?.sourcePaneID == "%31")
    }

    @Test("Host shared terminal placement overrides the saved Viewer split")
    func sharedLayoutWins() throws {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        let tabs = windows.mainTabs.tabs(hostID: "pair", session: "project")
        tabs.tabOrder = [.window("@0"), .window("@1")]
        tabs.rightSide = [.window("@1")]
        tabs.selectedRight = .window("@1")
        tabs.splitRatio = 0.3
        let latest = state(server: "200:2", offset: 20, shared: .init(leftWindowId: "@21", rightWindowIds: ["@20"], selectedRightWindowId: "@20", splitRatio: 0.7, revision: 1))
        let restored = WorkspaceViewerRecovery(), restoredWindows = DetachedTerminalWindows()
        restored.restore(recovery.capture(windows: windows), windows: restoredWindows)
        restored.update(latest, windows: restoredWindows)
        let result = try #require(restoredWindows.mainTabs.existing(hostID: "pair", session: "project"))
        #expect(result.rightSide == [.window("@20")])
        #expect(result.selectedRight == .window("@20"))
        #expect(result.splitRatio == 0.7)
    }

    @Test("Main Viewer retains terminal positions around private Files while Host owns the split", arguments: [false, true])
    func mainTabOrder(partialDiscovery: Bool) throws {
        var scene = try selectionScene(isMain: true)
        scene.sessions[0].layout.rightSide = [.window(index: 1)]
        scene.sessions[0].layout.selectedRight = .window(index: 1)
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore([scene], windows: windows)
        if partialDiscovery {
            recovery.update(state(server: "200:2", offset: 20, files: false, indices: [1]), windows: windows)
            _ = recovery.capture(windows: windows)
        }
        recovery.update(state(server: "200:2", offset: 20, shared: .init(leftWindowId: "@21", rightWindowIds: ["@20"], selectedRightWindowId: "@20", splitRatio: 0.7, revision: 1)), windows: windows)
        let tabs = try #require(windows.mainTabs.existing(hostID: "pair", session: "project"))
        #expect(tabs.tabOrder == [.window("@20"), .file(fileID), .window("@21")])
        #expect(tabs.rightSide == [.window("@20")])
        #expect(tabs.selectedRight == .window("@20"))
        #expect(tabs.splitRatio == 0.7)
        let captured = try #require(recovery.capture(windows: windows).first { $0.isMain }?.sessions.first)
        #expect(captured.layout.tabOrder == scene.sessions[0].layout.tabOrder)
    }

    @Test("Explicit unpair removes saved Viewer presentations and references")
    func unpair() {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        _ = windows.mainTabs.tabs(hostID: "pair", session: "project")
        windows.mainTabs.recoverySelection = .init(hostID: "pair", sessionName: "project", windowID: "@0")
        _ = recovery.capture(windows: windows)
        recovery.retainHosts([], windows: windows)
        #expect(recovery.capture(windows: windows).flatMap(\.sessions).isEmpty)
        #expect(windows.mainTabs.remoteRecoveryReferences.isEmpty)
        #expect(recovery.catalogs.isEmpty)
    }

    @Test("Connection callbacks remap native ownership before Files observers consume recycled runtime IDs", arguments: [false, true])
    func fileCatalogPublication(viaManager: Bool) async throws {
        let (manager, encryption) = try await withDependencies {
            $0[SecretsService.self] = .inMemory()
        } operation: {
            let manager = try await ViewerConnectionManager()
            return try (manager, #require(manager.pairingService))
        }
        let connection = ViewerConnection(
            pairedDevice: .init(id: "pair", hostName: "Host", username: "test", partnerPublicKey: encryption.publicKey.base64EncodedString(), partnerPublicKeyId: encryption.keyId),
            e2eeService: encryption
        )
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        manager.onSessionState = { recovery.update($0, windows: windows) }
        manager.setupConnectionCallbacks(connection)
        recovery.update(state(), windows: windows)
        let target = try #require(DetachedTerminalTarget(hostID: "pair", windowID: "@1"))
        let detached = try #require(windows.detach(target, position: nil, session: { _ in "project" }))
        windows.syncFileTabs(hostID: "pair", descriptors: state().fileTabs ?? [], sessionWindows: ["project": ["@0", "@1"]])
        let original = try #require(windows.mainTabs.existing(hostID: "pair", session: "project")?.directoryTabs[fileID])
        original.navigate("/Host/private")
        _ = recovery.capture(windows: windows)

        let fresh = state(server: "200:2", offset: 1)
        if viaManager {
            connection.relayClient.onSessionState?(fresh)
        } else {
            recovery.update(fresh, windows: windows)
        }
        #expect(recovery.catalogs["pair"]?.scope.serverID == "200:2")
        windows.syncFileTabs(hostID: "pair", descriptors: fresh.fileTabs ?? [], sessionWindows: ["project": ["@1", "@2"]])
        #expect(windows.owner(hostID: "pair", windowID: "@1") == nil)
        #expect(windows.owner(hostID: "pair", windowID: "@2") == detached.id)
        #expect(windows.mainTabs.existing(hostID: "pair", session: "project")?.directoryTabs[fileID]?.path == "/Host/private")
        #expect(detached.tabs.existing(hostID: "pair", session: "project")?.directoryTabs[fileID] == nil)
    }

    @Test("The journal rejects duplicate Viewer sessions and cross-Host Files sources")
    func malformedViewerRecords() throws {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        windows.syncFileTabs(hostID: "pair", descriptors: state().fileTabs ?? [], sessionWindows: ["project": ["@0", "@1"]])
        var journal = WorkspaceRecoveryStoreTests.snapshot()
        journal.viewerScenes = recovery.capture(windows: windows)
        try journal.validate()
        let saved = try #require(journal.viewerScenes?.first?.sessions.first)
        var duplicate = journal
        duplicate.viewerScenes?[0].sessions.append(saved)
        #expect(throws: WorkspaceRecoveryError.self) { try duplicate.validate() }
        var wrongHost = journal
        wrongHost.viewerScenes?[0].sessions[0].fileSources?[fileID]?.hostID = UUID()
        #expect(throws: WorkspaceRecoveryError.self) { try wrongHost.validate() }
    }

    @Test("Late Host Files and terminal discovery retain original order and survive closing the partially restored native window", arguments: [false, true])
    func partialDiscovery(closeWindow: Bool) throws {
        let recovery = WorkspaceViewerRecovery(), windows = DetachedTerminalWindows()
        recovery.restore(nil, windows: windows)
        recovery.update(state(), windows: windows)
        let first = try #require(DetachedTerminalTarget(hostID: "pair", windowID: "@0"))
        let second = try #require(DetachedTerminalTarget(hostID: "pair", windowID: "@1"))
        let group = try #require(windows.detach(first, position: nil, session: { _ in "project" }))
        #expect(windows.merge(second, into: group.id, session: { _ in "project" }))
        windows.syncFileTabs(hostID: "pair", descriptors: state().fileTabs ?? [], sessionWindows: ["project": ["@0", "@1"]])
        let tabs = group.tabs.tabs(hostID: "pair", session: "project")
        tabs.tabOrder = [.window("@0"), .file(fileID), .window("@1")]
        tabs.rightSide = [.file(fileID), .window("@1")]
        tabs.selectedRight = .file(fileID)
        tabs.directoryTabs[fileID]?.navigate("/Host/late-file")
        let restored = WorkspaceViewerRecovery(), owner = DetachedTerminalWindows()
        restored.restore(recovery.capture(windows: windows), windows: owner)
        restored.update(state(server: "200:2", offset: 20, files: false, indices: [0]), windows: owner)
        let partial = try #require(owner.workspaces[group.id])
        #expect(partial.members.map(\.windowID) == ["@20"])
        #expect(partial.tabs.existing(hostID: "pair", session: "project")?.openFileTabs.isEmpty == true)
        let pending = try #require(restored.capture(windows: owner).first { $0.id == group.id }?.sessions.first)
        #expect(pending.layout.tabOrder == [.window(index: 0), .file(id: fileID), .window(index: 1)])
        if closeWindow {
            let native = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
            owner.attach(native, to: partial.anchor)
            owner.didClose(partial.anchor, window: native)
            _ = restored.capture(windows: owner)
        }
        restored.update(state(server: "200:2", offset: 20), windows: owner)
        let store = closeWindow ? owner.mainTabs : partial.tabs
        let result = try #require(store.existing(hostID: "pair", session: "project"))
        #expect(result.directoryTabs[fileID]?.path == "/Host/late-file")
        #expect(result.directoryTabs[fileID]?.sourcePaneID == "%20")
        #expect(owner.owner(hostID: "pair", windowID: "@21") == (closeWindow ? nil : group.id))
        if !closeWindow {
            #expect(result.tabOrder == [.window("@20"), .file(fileID), .window("@21")])
            #expect(result.selectedRight == .file(fileID))
        }
        result.openFileTabs.removeAll { $0.id == fileID }
        result.directoryTabs.removeValue(forKey: fileID)
        result.tabOrder.removeAll { $0 == .file(fileID) }
        restored.update(state(server: "200:2", offset: 20, files: false), windows: owner)
        #expect(result.directoryTabs[fileID] == nil)
        #expect(!restored.capture(windows: owner).flatMap(\.sessions).flatMap { $0.layout.fileTabs }.contains { $0.id == fileID })
    }
}
