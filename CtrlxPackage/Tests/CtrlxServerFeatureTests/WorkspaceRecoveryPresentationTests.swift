import AppKit
import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct WorkspaceRecoveryPresentationTests {
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
        let retained = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live)
        #expect(retained[0].sessions[0].layout.fileTabs.first?.browser?.path == "/missing/project")
        let service = HostFileTabService()
        service.restore(source.fileTabs, sessions: [session], serverID: "new")
        WorkspaceRecoveryPresentationMapper.restoreLocal(retained, live: .init(serverID: "new", sessions: [session]), windows: owner, files: service.tabs)
        #expect(tabs.directoryTabs[host.id]?.hostTab?.sourcePaneID == "%9")
        #expect(tabs.directoryTabs[host.id]?.path == "/missing/project")
        #expect(tabs.rightSide.contains(.file(host.id)))
    }
}
