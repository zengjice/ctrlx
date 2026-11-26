import AppKit
import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct WorkspaceRecoveryPresentationTests {
    enum SplitEdit: CaseIterable {
        case resize
        case selection
        case membership
    }

    @Test("Editing a split keeps pending right terminals", arguments: [false, true], SplitEdit.allCases)
    func addsLateWindowAfterSplitEdit(checkpoint: Bool, edit: SplitEdit) throws {
        var session = sessions()[0]
        for index in 1...4 {
            var window = session.windows[0]
            window.id = UUID()
            window.runtimeID = "@\(index + 1)"
            window.index = index
            session.windows.append(window)
        }
        var partial = session
        let late = partial.windows.removeLast()
        let owner = DetachedTerminalWindows()
        let old = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@3", "@4", "@5"], selectedRightWindowId: "@3", splitRatio: 0.70, revision: 1)
        let left = edit == .selection ? "@2" : "@1"
        let right = edit == .membership ? ["@2", "@4"] : ["@3", "@4"]
        let edited = SharedTerminalLayout(
            leftWindowId: left, rightWindowIds: right, selectedRightWindowId: edit == .selection ? "@4" : right.first, splitRatio: 0.58, revision: 2
        )
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        snapshot.sessions = [session]
        snapshot.scenes = WorkspaceRecoveryPresentationMapper.captureLocal(
            windows: owner, sessions: [session], mainID: owner.mainSceneID, sharedLayouts: [session.name: old]
        )
        snapshot.recovery = .init(bootID: "boot", pendingAgentPaneIDs: [])
        var scenes = snapshot.scenes
        if checkpoint {
            let captured = WorkspaceRecoveryPresentationMapper.captureLocal(
                windows: owner, sessions: [partial], mainID: owner.mainSceneID, sharedLayouts: [session.name: edited]
            )
            let saved = WorkspaceRecoveryPresentationMapper.preservingUnavailable(
                captured: captured, source: snapshot, live: .init(serverID: "server", sessions: [partial]), windows: owner
            )
            scenes = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: JSONEncoder().encode(saved))
            #expect(scenes.first?.sessions.first?.sharedTerminalLayout?.rightWindowIDs.contains(late.id) == true)
            #expect(scenes.first?.sessions.first?.sharedTerminalLayout?.leftWindowID == session.windows.first { $0.runtimeID == left }?.id)
            #expect(scenes.first?.sessions.first?.sharedTerminalLayout?.splitRatio == 0.58)
        }
        let request = WorkspaceRecoveryPresentationMapper.restoredSharedTerminalRequest(
            from: scenes.first?.sessions.first, session: session, tabs: SessionFileTabsState(), current: edited,
            previouslyPresented: Set(partial.windows.map(\.id)), preferredLeft: nil
        )
        #expect(request?.leftWindowId == edited.leftWindowId)
        #expect(request?.rightWindowIds == right + ["@5"])
        #expect(request?.selectedRightWindowId == edited.selectedRightWindowId)
        #expect(request?.splitRatio == 0.58)
    }

    @Test("Moving a terminal left preserves the saved right slot of the temporary left terminal", arguments: [false, true])
    func restoresTemporaryLeftToRight(checkpoint: Bool) throws {
        var session = sessions()[0]
        for index in 1...3 {
            var window = session.windows[0]
            window.id = UUID()
            window.runtimeID = "@\(index + 1)"
            window.index = index
            session.windows.append(window)
        }
        let owner = DetachedTerminalWindows()
        let original = SharedTerminalLayout(leftWindowId: "@4", rightWindowIds: ["@1", "@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        snapshot.sessions = [session]
        snapshot.scenes = WorkspaceRecoveryPresentationMapper.captureLocal(
            windows: owner, sessions: [session], mainID: owner.mainSceneID, sharedLayouts: [session.name: original]
        )
        snapshot.recovery = .init(bootID: "boot", pendingAgentPaneIDs: [])
        var partial = session
        partial.windows.removeLast()
        let edited = SharedTerminalLayout(leftWindowId: "@3", rightWindowIds: ["@2"], selectedRightWindowId: "@2", revision: 2)
        var scenes = snapshot.scenes
        if checkpoint {
            let captured = WorkspaceRecoveryPresentationMapper.captureLocal(
                windows: owner, sessions: [partial], mainID: owner.mainSceneID, sharedLayouts: [session.name: edited]
            )
            let live = WorkspaceTmuxState(serverID: "server", sessions: [partial])
            for _ in 0..<2 {
                let saved = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: snapshot, live: live, windows: owner)
                snapshot.scenes = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: JSONEncoder().encode(saved))
                #expect(snapshot.scenes.first?.sessions.first?.sharedTerminalLayout?.rightWindowIDs == session.windows.prefix(2).map(\.id))
            }
            scenes = snapshot.scenes
            let reopened = WorkspaceRecoveryPresentationMapper.restoredSharedTerminalRequest(
                from: scenes.first?.sessions.first, session: session, tabs: SessionFileTabsState(), current: nil,
                previouslyPresented: [], preferredLeft: nil
            )
            #expect(reopened?.rightWindowIds == ["@1", "@2"])
        }
        let request = WorkspaceRecoveryPresentationMapper.restoredSharedTerminalRequest(
            from: scenes.first?.sessions.first, session: session, tabs: SessionFileTabsState(), current: edited,
            previouslyPresented: Set(partial.windows.map(\.id)), preferredLeft: nil
        )
        #expect(request?.leftWindowId == "@3")
        #expect(request?.rightWindowIds == ["@1", "@2"])
        #expect(request?.selectedRightWindowId == "@2")
    }

    @Test("A checkpoint remaps a missing Host-only right terminal if its index was reused")
    func checkpointRemapsMissingLocalRightTerminal() throws {
        var session = sessions()[0]
        var liveWindow = session.windows[0]
        liveWindow.id = UUID()
        liveWindow.index = 1
        liveWindow.runtimeID = "@2"
        session.windows.append(liveWindow)
        let late = session.windows[0]
        let owner = DetachedTerminalWindows()
        let tabs = owner.mainTabs.tabs(hostID: nil, session: session.name)
        let editor = OpenFileTab(path: "/tmp/note.md", directoryPath: "/tmp")
        tabs.openFileTabs = [editor]
        tabs.selectedFileTabId = editor.id
        tabs.rightSide = [.window(late.runtimeID)]
        tabs.locallySplitTerminalID = late.runtimeID

        var source = WorkspaceRecoveryStoreTests.snapshot()
        source.sessions = [session]
        source.scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: [session], mainID: owner.mainSceneID)
        source.recovery = .init(bootID: "boot", pendingAgentPaneIDs: [])

        var partial = session
        liveWindow.index = late.index
        partial.windows = [liveWindow]
        tabs.rightSide = []
        tabs.locallySplitTerminalID = nil
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: [partial], mainID: owner.mainSceneID)
        let live = WorkspaceTmuxState(serverID: "new", sessions: [partial])
        let checkpoint = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live, windows: owner)
        let decoded = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: JSONEncoder().encode(checkpoint))
        let saved = try #require(decoded.first?.sessions.first)
        let remappedIndex = try #require(saved.layout.localRightTerminalIndex)
        #expect(remappedIndex != late.index)
        #expect(saved.windowIDs[remappedIndex] == late.id)
        #expect(saved.layout.rightSide == [.window(index: remappedIndex)])

        let reopened = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(decoded, live: live, windows: reopened, files: [])
        WorkspaceRecoveryPresentationMapper.restoreLocal(decoded, live: .init(serverID: "new", sessions: [session]), windows: reopened, files: [])
        let restored = try #require(reopened.mainTabs.local[session.name])
        restored.applySharedTerminalLayout(.init(leftWindowId: late.runtimeID, revision: 1), liveWindowIds: [late.runtimeID, liveWindow.runtimeID])
        #expect(restored.selectedFileTabId == editor.id)
        #expect(restored.locallySplitTerminalID == late.runtimeID)
        #expect(restored.rightSideWindowIds == [late.runtimeID])
    }

    @Test("A window restored in B still needs its placement restored in A")
    func restoresLinkedWindowPlacementPerSession() throws {
        let initial = sessions()
        var a = initial[0]
        let b = initial[1]
        var linked = b.windows[0]
        linked.index = a.windows[0].index + 1
        let partialA = a
        a.windows.append(linked)
        var saved = presentation(a)
        saved.layout.rightSide = [.window(index: linked.index)]
        let owner = DetachedTerminalWindows()
        let scenes = [WorkspaceRecoveryScene(id: owner.mainSceneID, isMain: true, sessions: [saved, presentation(b)])]
        WorkspaceRecoveryPresentationMapper.restoreLocal(
            scenes, live: .init(serverID: "server", sessions: [partialA, b]), windows: owner, files: []
        )
        #expect(owner.mainTabs.restoredRecoveryWindowIDs[a.id]?.contains(linked.id) == false)
        #expect(owner.mainTabs.restoredRecoveryWindowIDs[b.id]?.contains(linked.id) == true)
        WorkspaceRecoveryPresentationMapper.restoreLocal(
            scenes, live: .init(serverID: "server", sessions: [a, b]), windows: owner, files: []
        )
        let tabs = try #require(owner.mainTabs.local[a.name])
        #expect(tabs.rightSide.contains(.window(linked.runtimeID)))
        #expect(owner.mainTabs.restoredRecoveryWindowIDs[a.id]?.contains(linked.id) == true)
    }

    @Test("A recovered workspace retains the folders of its private tabs", arguments: [false, true])
    func recoveredPrivateTabFolders(legacy: Bool) throws {
        var session = sessions()[0]
        session.windows[0].panes[0].agent = nil
        session.windows[0].panes[0].directory = "/a"
        let original = DetachedTerminalWindows()
        let tabs = original.mainTabs.tabs(hostID: nil, session: session.name)
        let file = OpenFileTab(path: "/a/notes.md", directoryPath: "/a")
        let browser = BrowserTab(url: URL(fileURLWithPath: "/page"))
        tabs.openFileTabs = [file]
        tabs.openBrowserTabs = [browser]
        tabs.tabFolders[.browser(browser.id)] = ["/a", "/other"]
        var scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: original, sessions: [session], mainID: original.mainSceneID)
        if legacy {
            scenes[0].sessions[0].privateTabFolders = nil
        }
        var current = session
        current.windows[0].panes[0].directory = "/b"
        let recovered = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(
            scenes, live: .init(serverID: "new", sessions: [current]), savedSessions: [session], windows: recovered, files: []
        )
        let restored = try #require(recovered.mainTabs.local[session.name])

        #expect(restored.tabFolders[.file(file.id)] == ["/a"])
        #expect(restored.tabFolders[.browser(browser.id)] == (legacy ? ["/a"] : ["/a", "/other"]))
        let otherFolder = LayoutSnapshotMapper.snapshot(
            from: restored, fileBrowser: nil, excluding: restored.tabsOutsideFolder("/b"), windowIndexForId: { _ in nil }
        )
        #expect(otherFolder.fileTabs.isEmpty && otherFolder.browserTabs.isEmpty)
    }

    @Test("Workspace checkpoints restore the shared split independently of the Host's visible tabs", arguments: [false, true])
    func restoresSharedTerminalLayout(hostShowsBrowser: Bool) throws {
        var session = sessions()[0]
        for index in 1...2 {
            var window = session.windows[0]
            window.id = UUID()
            window.index = index
            window.runtimeID = "@\(index + 1)"
            session.windows.append(window)
        }
        let owner = DetachedTerminalWindows()
        let shared = SharedTerminalLayout(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.56, revision: 2)
        if hostShowsBrowser {
            let tabs = owner.mainTabs.tabs(hostID: nil, session: session.name)
            let browser = BrowserTab(url: URL(fileURLWithPath: "/page"))
            tabs.tabOrder = [.browser(browser.id)]
            tabs.openBrowserTabs = [browser]
            tabs.rightSide = [.browser(browser.id)]
            tabs.selectedRight = .browser(browser.id)
            tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2", "@3"])
        }
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(
            windows: owner, sessions: [session], mainID: owner.mainSceneID, sharedLayouts: [session.name: shared]
        )
        let saved = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: JSONEncoder().encode(captured))
        for index in session.windows.indices {
            session.windows[index].runtimeID = "@\(index + 10)"
            session.windows[index].index = index + 6
        }
        let recovered = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(saved, live: .init(serverID: "new", sessions: [session]), windows: recovered, files: [])
        let tabs = try #require(recovered.mainTabs.local[session.name])
        let request = WorkspaceRecoveryPresentationMapper.restoredSharedTerminalRequest(
            from: saved[0].sessions[0], session: session, tabs: tabs, current: nil, previouslyPresented: [], preferredLeft: nil
        )
        #expect(request?.leftWindowId == "@10")
        #expect(request?.rightWindowIds == ["@11", "@12"])
        #expect(request?.selectedRightWindowId == "@12")
        #expect(request?.splitRatio == 0.56)
        if hostShowsBrowser {
            #expect(tabs.selectedRight == tabs.openBrowserTabs.first.map { .browser($0.id) })
            var legacy = saved[0].sessions[0]
            legacy.sharedTerminalLayout = nil
            let legacyRequest = WorkspaceRecoveryPresentationMapper.restoredSharedTerminalRequest(
                from: legacy, session: session, tabs: tabs, current: nil, previouslyPresented: [], preferredLeft: nil
            )
            #expect(legacyRequest?.selectedRightWindowId == "@12")
        }
    }

    @Test("Model shortcuts and creation defaults survive App restart and tmux reconstruction", arguments: [false, true])
    func modelShortcutsRestart(rebuild: Bool) async throws {
        let old = sessions(), owner = DetachedTerminalWindows(), preferences = AgentModelPreferences()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        _ = try #require(owner.detach(target, position: nil, session: { _ in "two" }))
        for session in old {
            let window = session.windows[0]
            let pane = WorkspacePaneIdentity(serverID: "old", sessionID: session.id, windowID: window.id, paneID: window.panes[0].id)
            preferences.initialize(.init(pane: pane, defaults: .init(models: ["provider-default"], efforts: ["low"])), hostID: "local")
            let key = AgentModelPreferences.Key(hostID: "local", windowID: window.id)
            preferences.tabs[key]?.models.insert(session.name)
        }
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        snapshot.sessions = old
        snapshot.scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: old, mainID: owner.mainSceneID, modelPreferences: preferences, serverID: "old")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-model-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await WorkspaceRecoveryStore.diskBacked(directory: directory).save(snapshot)
        let saved = try #require(try await WorkspaceRecoveryStore.diskBacked(directory: directory).load())
        var live = WorkspaceTmuxState(serverID: rebuild ? "new" : "old", sessions: old)
        if rebuild {
            live.sessions[0].windows[0].runtimeID = "@2"
            live.sessions[1].windows[0].runtimeID = "@1"
        }
        let restored = AgentModelPreferences(), windows = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(saved.scenes, live: live, windows: windows, files: [], modelPreferences: restored)
        for session in old {
            let key = AgentModelPreferences.Key(hostID: "local", windowID: session.windows[0].id)
            #expect(restored.tabs[key]?.models == ["provider-default", session.name])
            #expect(restored.tabs[key]?.efforts == ["low"])
            #expect(restored.defaults[key]?.models == ["provider-default"])
            restored.tabs[key]?.models.insert("after-restore")
        }
        WorkspaceRecoveryPresentationMapper.restoreLocal(saved.scenes, live: live, windows: windows, files: [], modelPreferences: restored)
        #expect(restored.tabs.values.allSatisfy { $0.models.contains("after-restore") })
        let next = WorkspaceRecoveryPresentationMapper.captureLocal(windows: windows, sessions: live.sessions, mainID: windows.mainSceneID, modelPreferences: restored, serverID: live.serverID)
        #expect(next.flatMap(\.sessions).compactMap(\.modelShortcuts).flatMap(\.values).allSatisfy { $0.hidden.models.contains("after-restore") })
    }

    @Test("Partial recovery retains missing window shortcuts and ignores recycled runtime IDs")
    func pendingModelShortcuts() {
        var source = WorkspaceRecoveryStoreTests.snapshot()
        var second = WorkspaceRecoveryStoreTests.snapshot().sessions[0].windows[0]
        second.index = 1
        second.runtimeID = "@2"
        source.sessions[0].windows.append(second)
        source.recovery = .init(bootID: "boot", pendingAgentPaneIDs: [])
        var saved = presentation(source.sessions[0])
        let record = AgentModelPreferences.Snapshot(hidden: .init(models: ["hidden"], efforts: ["low"]), defaults: .init(efforts: ["low"]))
        saved.modelShortcuts = [second.id: record]
        let windows = DetachedTerminalWindows(), preferences = AgentModelPreferences()
        source.scenes = [.init(id: windows.mainSceneID, isMain: true, sessions: [saved])]
        var live = WorkspaceTmuxState(serverID: "new", sessions: source.sessions)
        live.sessions[0].windows.removeLast()
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: windows, sessions: live.sessions, mainID: windows.mainSceneID, modelPreferences: preferences, serverID: live.serverID)
        let retained = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live, windows: windows)
        #expect(retained.first?.sessions.first?.modelShortcuts?[second.id] == record)
        WorkspaceRecoveryPresentationMapper.restoreLocal(retained, live: live, windows: windows, files: [], modelPreferences: preferences)
        #expect(preferences.tabs.isEmpty)
        live.sessions = source.sessions
        WorkspaceRecoveryPresentationMapper.restoreLocal(retained, live: live, windows: windows, files: [], modelPreferences: preferences)
        #expect(preferences.tabs[.init(hostID: "local", windowID: second.id)] == record.hidden)

        // A new window can reuse the old tmux number, but not the closed tab's configuration.
        live.sessions[0].windows[1].id = UUID()
        let replacement = AgentModelPreferences()
        WorkspaceRecoveryPresentationMapper.restoreLocal(retained, live: live, windows: DetachedTerminalWindows(), files: [], modelPreferences: replacement)
        #expect(replacement.tabs.isEmpty)
        let afterClose = WorkspaceRecoveryPresentationMapper.captureLocal(windows: windows, sessions: live.sessions, mainID: windows.mainSceneID, modelPreferences: preferences, serverID: live.serverID)
        #expect(afterClose.flatMap(\.sessions).allSatisfy { $0.modelShortcuts?[second.id] == nil })
    }

    @Test("Legacy workspace snapshots omit shortcuts; saved preferences must belong to an owned window")
    func modelShortcutCompatibility() throws {
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        let windows = DetachedTerminalWindows()
        snapshot.scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: windows, sessions: snapshot.sessions, mainID: windows.mainSceneID)
        let data = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: data, as: UTF8.self).contains("modelShortcuts"))
        let legacy = try JSONDecoder().decode(WorkspaceRecoverySnapshot.self, from: data)
        let preferences = AgentModelPreferences()
        WorkspaceRecoveryPresentationMapper.restoreLocal(legacy.scenes, live: .init(serverID: "new", sessions: legacy.sessions), windows: DetachedTerminalWindows(), files: [], modelPreferences: preferences)
        #expect(preferences.tabs.isEmpty && preferences.defaults.isEmpty)
        snapshot.scenes[0].sessions[0].modelShortcuts = [UUID(): .init(hidden: .init(), defaults: nil)]
        #expect(throws: WorkspaceRecoveryError.self) { try snapshot.validate() }
    }

    @Test("A saved frame on an unavailable display is clamped to the current screen", arguments: [false, true])
    func missingDisplay(oversized: Bool) throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let farEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        let saved = CGRect(
            x: farEdge + 1_000, y: -20_000,
            width: oversized ? screen.frame.width * 2 : 800,
            height: oversized ? screen.frame.height * 2 : 500
        )
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        DetachedTerminalWindows.restoreFrame(saved, to: window)

        #expect(screen.visibleFrame.contains(window.frame))
        #expect(window.frame.width == min(saved.width, screen.visibleFrame.width))
        #expect(window.frame.height == min(saved.height, screen.visibleFrame.height))
    }

    @Test("A hidden main window keeps its saved geometry until first display", arguments: [false, true])
    func mainFrameWaitsForDisplay(viewer: Bool) throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let saved = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 800, height: 500)
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, frame: saved, sessions: [])
        let owner = DetachedTerminalWindows()
        let remote = WorkspaceViewerRecovery()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = WorkspaceRecoveryWindowAnchor.Anchor(windows: owner, isMain: true)
        window.contentView = anchor

        if viewer {
            remote.restore([scene], windows: owner)
        } else {
            WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "live", sessions: []), windows: owner, files: [])
        }
        // Model the initial SwiftUI placement occurring after the anchor attaches.
        window.setFrame(screen.visibleFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(!window.isVisible)
        #expect(owner.restoredMainFrame == saved)
        let captured = viewer ? remote.capture(windows: owner) : WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: [], mainID: owner.mainSceneID)
        #expect(captured.first(where: \.isMain)?.frame == saved)

        window.orderFront(nil)
        window.update()
        #expect(window.frame == saved)
        #expect(owner.restoredMainFrame == nil)

        let changed = saved.offsetBy(dx: 20, dy: 20)
        window.setFrame(changed, display: false)
        window.update()
        #expect(window.frame == changed)
        #expect(owner.mainFrame == changed)
    }

    private func sessions() -> [WorkspaceRecoverySession] {
        var first = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
        first.name = "one"
        var second = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
        second.name = "two"
        second.runtimeID = "$2"
        second.windows[0].runtimeID = "@2"
        second.windows[0].panes[0].runtimeID = "%2"
        return [first, second]
    }

    private func presentation(_ session: WorkspaceRecoverySession) -> WorkspaceRecoveryPresentation {
        .init(
            hostID: nil,
            sessionID: session.id,
            sessionName: session.name,
            layout: .init(tabOrder: session.windows.map { .window(index: $0.index) }),
            windowIDs: Dictionary(uniqueKeysWithValues: session.windows.map { ($0.index, $0.id) }),
            ownedWindowIDs: session.windows.map(\.id),
            focusedRight: false
        )
    }

    @Test("Two same-directory sessions and native-window ownership remap by persistent identity", arguments: [false, true])
    func identityAndOwnership(sessionWindow: Bool) throws {
        let old = sessions()
        let owner = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        let detached = try #require(sessionWindow
            ? owner.detachSession(hostID: nil, name: "two", windowIDs: ["@2"], selectedWindowID: "@2", position: nil, session: { _ in "two" })
            : owner.detach(target, position: nil, session: { _ in "two" }))
        owner.mainTabs.recoverySelection = .init(sessionName: "one", windowID: "@1")
        detached.tabs.recoverySelection = .init(sessionName: "two", windowID: "@2")
        let saved = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: old, mainID: owner.mainSceneID)
        var live = old
        // Recycle the old runtime numbers for the opposite session.
        live[0].windows[0].runtimeID = "@2"
        live[1].windows[0].runtimeID = "@1"
        let restored = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(saved, live: .init(serverID: "new", sessions: live), windows: restored, files: [])
        #expect(restored.owner(hostID: nil, windowID: "@1") == detached.id)
        #expect(restored.owner(hostID: nil, windowID: "@2") == nil)
        #expect(restored.mainTabs.restoredSelection?.windowID == "@2")
        #expect(restored.workspaces[detached.id]?.tabs.restoredSelection?.windowID == "@1")
        #expect(restored.workspaces[detached.id]?.isSessionWindow == sessionWindow)
        #expect(restored.restoredWindowIDs == [detached.id])
        WorkspaceRecoveryPresentationMapper.restoreLocal(saved, live: .init(serverID: "new", sessions: live), windows: restored, files: [])
        #expect(restored.restoredWindowIDs == [detached.id])
    }

    @Test("A restored left file keeps the only terminal on the right when the shared layout arrives")
    func restoresLocalOnlySplit() throws {
        let session = sessions()[0]
        let window = try #require(session.windows.first)
        let fileID = UUID()
        var saved = presentation(session)
        saved.layout.fileTabs = [.init(id: fileID, path: "/tmp/note.md", directoryPath: "/tmp")]
        saved.layout.tabOrder.insert(.file(id: fileID), at: 0)
        saved.layout.selectedLeft = .file(id: fileID)
        saved.layout.rightSide = [.window(index: window.index)]
        saved.layout.selectedRight = .window(index: window.index)
        saved.layout.splitRatio = 0.7
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        let owner = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [session]), windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])

        tabs.applySharedTerminalLayout(.init(leftWindowId: window.runtimeID, revision: 1), liveWindowIds: [window.runtimeID])
        #expect(tabs.selectedFileTabId == fileID)
        #expect(tabs.rightSideWindowIds == [window.runtimeID])
        #expect(tabs.selectedRight == .window(window.runtimeID))
        #expect(tabs.splitRatio == 0.7)
    }

    @Test("A late terminal stays on the right when the shared left terminal changes")
    func partiallyRestoredLocalOnlySplit() throws {
        var session = sessions()[0]
        let first = try #require(session.windows.first)
        var second = WorkspaceRecoveryStoreTests.snapshot().sessions[0].windows[0]
        second.index = first.index + 1
        second.runtimeID = "@9"
        session.windows.append(second)
        let file = SavedFileTab(id: UUID(), path: "/tmp/note.md", directoryPath: "/tmp")
        var saved = presentation(session)
        saved.layout.fileTabs = [file]
        saved.layout.tabOrder.insert(.file(id: file.id), at: 0)
        saved.layout.selectedLeft = .file(id: file.id)
        saved.layout.rightSide = [.window(index: first.index), .window(index: second.index)]
        saved.layout.selectedRight = .window(index: first.index)
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        let owner = DetachedTerminalWindows()
        var partial = session
        partial.windows = [first]
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [partial]), windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])
        tabs.applySharedTerminalLayout(.init(leftWindowId: first.runtimeID, revision: 1), liveWindowIds: [first.runtimeID])

        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [session]), windows: owner, files: [])
        tabs.applySharedTerminalLayout(
            .init(leftWindowId: second.runtimeID, rightWindowIds: [first.runtimeID], selectedRightWindowId: first.runtimeID, revision: 2),
            liveWindowIds: [first.runtimeID, second.runtimeID]
        )

        #expect(tabs.selectedFileTabId == file.id)
        #expect(tabs.rightSideWindowIds == [first.runtimeID, second.runtimeID])
        #expect(tabs.selectedRight == .window(first.runtimeID))
    }

    @Test("Late Host Files restores the saved left content and terminal split unless the user chose another tab", arguments: [false, true])
    func lateHostFilesRestoresLocalOnlySplit(userChoseAnotherTab: Bool) throws {
        let session = sessions()[0]
        let terminal = try #require(session.windows.first)
        let host = HostFileTab(sessionName: session.name, windowID: terminal.runtimeID, sourcePaneID: "%1", initialDirectory: "/tmp")
        let files = FileBrowserTab(hostTab: host)
        var saved = presentation(session)
        saved.layout.fileTabs = [.init(id: host.id, path: "Files", directoryPath: "", browser: files.snapshot)]
        saved.layout.tabOrder.insert(.file(id: host.id), at: 0)
        saved.layout.selectedLeft = .file(id: host.id)
        saved.layout.rightSide = [.window(index: terminal.index)]
        saved.layout.selectedRight = .window(index: terminal.index)
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        let owner = DetachedTerminalWindows()
        let live = WorkspaceTmuxState(serverID: "new", sessions: [session])
        let shared = SharedTerminalLayout(leftWindowId: terminal.runtimeID, revision: 1)
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: live, windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])
        tabs.applySharedTerminalLayout(shared, liveWindowIds: [terminal.runtimeID])
        #expect(tabs.selectedFileTabId == nil && tabs.rightSide.isEmpty)
        if userChoseAnotherTab {
            tabs.recordTabSelection(onRight: false)
            tabs.selectLeftGit()
        }

        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: live, windows: owner, files: [host])
        #expect(tabs.openFileTabs.map(\.id) == [host.id])
        if userChoseAnotherTab {
            #expect(tabs.isGitSelected && tabs.selectedFileTabId == nil && tabs.rightSide.isEmpty)
        } else {
            #expect(tabs.selectedFileTabId == host.id && tabs.selectedRight == .window(terminal.runtimeID))
            tabs.applySharedTerminalLayout(shared, liveWindowIds: [terminal.runtimeID])
            #expect(tabs.rightSideWindowIds == [terminal.runtimeID])
        }
    }

    @Test("Checkpointing while Host Files is missing preserves the intended split unless the user chose another tab", arguments: [false, true])
    func checkpointWhileLeftFilesIsMissing(userChoseAnotherTab: Bool) throws {
        let session = sessions()[0]
        let terminal = session.windows[0]
        let host = HostFileTab(
            sessionName: session.name, windowID: terminal.runtimeID,
            sourcePaneID: terminal.panes[0].runtimeID, initialDirectory: "/tmp"
        )
        let file = SavedTabRef.file(id: host.id)
        var saved = presentation(session)
        saved.layout.fileTabs = [.init(id: host.id, path: "Files", directoryPath: "", browser: FileBrowserTab(hostTab: host).snapshot)]
        saved.layout.tabOrder.insert(file, at: 0)
        saved.layout.selectedLeft = file
        saved.layout.rightSide = [.window(index: terminal.index)]
        saved.layout.selectedRight = .window(index: terminal.index)
        saved.layout.splitRatio = 0.70
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        var source = WorkspaceRecoveryStoreTests.snapshot()
        source.sessions = [session]
        source.scenes = [scene]
        source.fileTabs = WorkspaceRecoveryPresentationMapper.captureFiles([host], sessions: [session])
        source.recovery = .init(bootID: "new", pendingAgentPaneIDs: [])

        var partial = session
        partial.windows[0].index += 1
        partial.windows[0].panes = []
        let live = WorkspaceTmuxState(serverID: "new", sessions: [partial])
        let owner = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: live, windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])
        let shared = SharedTerminalLayout(leftWindowId: terminal.runtimeID, revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: [terminal.runtimeID])
        #expect(tabs.rightSide.isEmpty)
        if userChoseAnotherTab {
            tabs.recordTabSelection(onRight: false)
            #expect(tabs.selectLeftTerminalWindow(terminal.runtimeID))
        }
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: live.sessions, mainID: owner.mainSceneID)
        let checkpoint = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live, windows: owner)
        let data = try JSONEncoder().encode(checkpoint)
        let readBack = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: data)
        let layout = try #require(readBack.first?.sessions.first?.layout)
        let right = SavedTabRef.window(index: partial.windows[0].index)
        #expect(layout.fileTabs.map(\.id) == [host.id])
        #expect(layout.selectedLeft == (userChoseAnotherTab ? right : file))
        #expect(layout.selectedRight == (userChoseAnotherTab ? nil : right))
        #expect(layout.rightSide == (userChoseAnotherTab ? [] : [right]))

        partial.windows[0].panes = terminal.panes
        let reopened = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(readBack, live: .init(serverID: live.serverID, sessions: [partial]), windows: reopened, files: [host])
        let restored = try #require(reopened.mainTabs.local[session.name])
        #expect(restored.selectedFileTabId == (userChoseAnotherTab ? nil : host.id))
        #expect(restored.rightSideWindowIds == (userChoseAnotherTab ? [] : [terminal.runtimeID]))
        if !userChoseAnotherTab {
            #expect(restored.splitRatio == 0.70)
        }
    }

    @Test(
        "Late right-pane Host Files respects explicit selection after a rename and checkpoint",
        arguments: [false, true], [false, true]
    )
    func lateHostFilesRestoresRightSelection(fallbackIsFile: Bool, userChoseFallback: Bool) throws {
        var old = sessions()
        old[1].windows[0].index = 1
        var session = old[0]
        let left = session.windows[0]
        let right = old[1].windows[0]
        session.windows.append(right)
        let host = HostFileTab(
            sessionName: session.name, windowID: left.runtimeID,
            sourcePaneID: left.panes[0].runtimeID, initialDirectory: "/tmp"
        )
        let fallbackFiles = HostFileTab(
            sessionName: session.name, windowID: right.runtimeID,
            sourcePaneID: right.panes[0].runtimeID, initialDirectory: "/tmp/other"
        )
        let availableFiles = fallbackIsFile ? [fallbackFiles] : []
        let file = SavedTabRef.file(id: host.id)
        let fallback: SavedTabRef = fallbackIsFile ? .file(id: fallbackFiles.id) : .window(index: right.index)
        let fallbackPayload: TabDragPayload = fallbackIsFile ? .file(fallbackFiles.id) : .window(right.runtimeID)
        var saved = presentation(session)
        saved.layout.fileTabs = [.init(id: host.id, path: "Files", directoryPath: "", browser: FileBrowserTab(hostTab: host).snapshot)]
        if fallbackIsFile {
            saved.layout.fileTabs.append(.init(id: fallbackFiles.id, path: "Files", directoryPath: "", browser: FileBrowserTab(hostTab: fallbackFiles).snapshot))
            saved.layout.tabOrder.append(fallback)
        }
        saved.layout.tabOrder.append(file)
        saved.layout.rightSide = [fallback, file]
        saved.layout.selectedRight = file
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        var source = WorkspaceRecoveryStoreTests.snapshot()
        source.sessions = [session]
        source.scenes = [scene]
        source.fileTabs = WorkspaceRecoveryPresentationMapper.captureFiles(availableFiles + [host], sessions: [session])
        source.recovery = .init(bootID: "new", pendingAgentPaneIDs: [])

        var partial = session
        partial.windows[0].panes = []
        var live = WorkspaceTmuxState(serverID: "new", sessions: [partial])
        let owner = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: live, windows: owner, files: availableFiles)
        let tabs = try #require(owner.mainTabs.local[session.name])
        let shared = SharedTerminalLayout(
            leftWindowId: left.runtimeID, rightWindowIds: fallbackIsFile ? [] : [right.runtimeID],
            selectedRightWindowId: fallbackIsFile ? nil : right.runtimeID, revision: 1
        )
        tabs.applySharedTerminalLayout(shared, liveWindowIds: [left.runtimeID, right.runtimeID])
        #expect(tabs.selectedRight == fallbackPayload)
        if userChoseFallback {
            tabs.recordTabSelection(onRight: true)
            let oldName = session.name
            session.name = "renamed"
            live.sessions[0].name = session.name
            owner.renameSession(hostID: nil, from: oldName, to: session.name, windowIDs: [:])
        }
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: live.sessions, mainID: owner.mainSceneID)
        let checkpoint = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live, windows: owner)
        let data = try JSONEncoder().encode(checkpoint)
        let readBack = try JSONDecoder().decode([WorkspaceRecoveryScene].self, from: data)
        #expect(readBack[0].sessions[0].layout.selectedRight == (userChoseFallback ? fallback : file))

        let full = WorkspaceTmuxState(serverID: "new", sessions: [session])
        let expected: TabDragPayload = userChoseFallback ? fallbackPayload : .file(host.id)
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: full, windows: owner, files: availableFiles + [host])
        #expect(tabs.rightSide.contains(.file(host.id)))
        #expect(tabs.selectedRight == expected)
        let reopened = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal(readBack, live: full, windows: reopened, files: availableFiles + [host])
        #expect(reopened.mainTabs.local[session.name]?.selectedRight == expected)
    }

    @Test("Host Files preserve navigation, identity, split selection and preview offset")
    func files() throws {
        let old = sessions()
        let owner = DetachedTerminalWindows()
        let host = HostFileTab(sessionName: "one", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/tmp")
        let tabs = owner.mainTabs.tabs(hostID: nil, session: "one")
        let directory = FileBrowserTab(id: host.id, path: "/tmp/nested", sourcePaneID: "%1")
        directory.updateHostTab(host)
        tabs.directoryTabs[host.id] = directory
        tabs.openFileTabs = [.init(id: host.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.tabOrder = [.window("@1"), .file(host.id)]
        tabs.rightSide = [.file(host.id)]
        tabs.selectedRight = .file(host.id)
        tabs.isRightPaneFocused = true
        tabs.splitRatio = 0.7
        tabs.scrollOffsets[host.id] = 42
        let scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: old, mainID: owner.mainSceneID)
        let records = WorkspaceRecoveryPresentationMapper.captureFiles([host], sessions: old)
        var live = old
        live[0].windows[0].runtimeID = "@70"
        live[0].windows[0].panes[0].runtimeID = "%80"
        let service = HostFileTabService()
        service.restore(records, sessions: live, serverID: "new")
        let newOwner = DetachedTerminalWindows()
        // Catalog synchronization may happen before presentation restoration.
        newOwner.syncFileTabs(hostID: nil, descriptors: service.tabs, sessionWindows: ["one": ["@70"]])
        WorkspaceRecoveryPresentationMapper.restoreLocal(scenes, live: .init(serverID: "new", sessions: live), windows: newOwner, files: service.tabs)
        let result = try #require(newOwner.mainTabs.local["one"])
        #expect(result.directoryTabs[host.id]?.path == "/tmp/nested")
        #expect(result.directoryTabs[host.id]?.hostTab?.sourcePaneID == "%80")
        #expect(result.selectedRight == .file(host.id))
        #expect(result.isRightPaneFocused && result.splitRatio == 0.7)
        #expect(result.scrollOffsets[host.id] == 42)
        #expect(result.openFileTabs.count == 1)
    }

    @Test("A partial retry adds the missing terminal without replaying selection or closed files")
    func partialRetry() throws {
        var session = sessions()[0]
        var extra = WorkspaceRecoveryStoreTests.snapshot().sessions[0].windows[0]
        extra.index = 1
        extra.runtimeID = "@9"
        session.windows.append(extra)
        var saved = presentation(session)
        let fileID = UUID()
        saved.layout.fileTabs = [.init(id: fileID, path: "/tmp/note", directoryPath: "/tmp")]
        saved.layout.tabOrder.append(.file(id: fileID))
        saved.layout.rightSide = [.window(index: 1)]
        saved.layout.selectedRight = .window(index: 1)
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        let owner = DetachedTerminalWindows()
        var partial = session
        partial.windows.removeLast()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [partial]), windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])
        tabs.removeFileTab(fileID)
        tabs.splitRatio = 0.6
        tabs.isGitSelected = true
        owner.mainTabs.restoredSelection = nil
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [session]), windows: owner, files: [])
        #expect(tabs.openFileTabs.isEmpty)
        #expect(tabs.splitRatio == 0.6 && tabs.isGitSelected)
        #expect(tabs.rightSide.contains(.window("@9")))
        #expect(tabs.selectedRight == .window("@9"))
        #expect(owner.mainTabs.restoredSelection == nil)
    }

    @Test("A detached workbench with only Files retains its own native window")
    func filesOnlyDetached() throws {
        let session = sessions()[0]
        var saved = presentation(session)
        saved.ownedWindowIDs = []
        let fileID = UUID()
        saved.layout = .init(fileTabs: [.init(id: fileID, path: "/tmp/note", directoryPath: "/tmp")], tabOrder: [.file(id: fileID)], selectedLeft: .file(id: fileID))
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: false, sessions: [saved], selectedSessionID: session.id)
        let owner = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: .init(serverID: "new", sessions: [session]), windows: owner, files: [])
        let workspace = try #require(owner.workspaces[scene.id])
        #expect(workspace.members.isEmpty)
        #expect(workspace.tabs.local[session.name]?.selectedFileTabId == fileID)
        #expect(owner.targets.isEmpty)
    }

    @Test("An unavailable Host Files source is retained without routing through another pane")
    func missingFilesSource() throws {
        var session = sessions()[0]
        var extra = WorkspaceRecoveryStoreTests.snapshot().sessions[0].windows[0]
        extra.index = 1
        extra.runtimeID = "@9"
        extra.panes[0].runtimeID = "%9"
        session.windows.append(extra)
        let host = HostFileTab(sessionName: session.name, windowID: "@9", sourcePaneID: "%9", initialDirectory: "/missing/project")
        let browser = FileBrowserTab(hostTab: host)
        var saved = presentation(session)
        saved.layout.fileTabs = [.init(id: host.id, path: "Files", directoryPath: "", browser: browser.snapshot)]
        saved.layout.tabOrder.append(.file(id: host.id))
        saved.layout.rightSide = [.file(id: host.id)]
        let scene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [saved], selectedSessionID: session.id)
        var source = WorkspaceRecoveryStoreTests.snapshot()
        source.sessions = [session]
        source.scenes = [scene]
        source.fileTabs = WorkspaceRecoveryPresentationMapper.captureFiles([host], sessions: [session])
        source.recovery = .init(bootID: "new", pendingAgentPaneIDs: [])
        var partial = session
        partial.windows.removeLast()
        let live = WorkspaceTmuxState(serverID: "new", sessions: [partial], incompleteSessionIDs: [session.id])
        let owner = DetachedTerminalWindows()
        WorkspaceRecoveryPresentationMapper.restoreLocal([scene], live: live, windows: owner, files: [])
        let tabs = try #require(owner.mainTabs.local[session.name])
        #expect(tabs.directoryTabs[host.id] == nil)
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: owner, sessions: live.sessions, mainID: owner.mainSceneID)
        let retained = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live, windows: owner)
        #expect(retained[0].sessions[0].layout.fileTabs.first?.browser?.path == "/missing/project")
        let service = HostFileTabService()
        service.restore(source.fileTabs, sessions: [session], serverID: "new")
        WorkspaceRecoveryPresentationMapper.restoreLocal(retained, live: .init(serverID: "new", sessions: [session]), windows: owner, files: service.tabs)
        #expect(tabs.directoryTabs[host.id]?.hostTab?.sourcePaneID == "%9")
        #expect(tabs.directoryTabs[host.id]?.path == "/missing/project")
        #expect(tabs.rightSide.contains(.file(host.id)))
    }
}
