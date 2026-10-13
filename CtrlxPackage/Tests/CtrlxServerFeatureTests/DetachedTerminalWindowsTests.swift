import AppKit
import CtrlxCommon
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct DetachedTerminalWindowsTests {
    @Test(arguments: [nil, "host"] as [String?])
    func renameMigratesAllOwnersOnceAndKeepsHostAndSessionIsolation(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let sourceTarget = try #require(DetachedTerminalTarget(hostID: host, windowID: "@0"))
        let otherSessionTarget = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let foreignTarget = try #require(DetachedTerminalTarget(hostID: "foreign", windowID: "@0"))
        let source = try #require(manager.detach(sourceTarget, position: nil, session: { _ in "old" }))
        let otherSession = try #require(manager.detach(otherSessionTarget, position: nil, session: { _ in "other" }))
        let foreign = try #require(manager.detach(foreignTarget, position: nil, session: { _ in "old" }))
        let sourceTabs = source.tabs.tabs(hostID: host, session: "old")
        let browser = BrowserTab(url: URL(staticString: "about:blank"), originWindowId: "@0")
        sourceTabs.openBrowserTabs = [browser]
        #expect(manager.transfer(
            .init(workspaceID: source.id, hostID: host, sessionName: "old", tab: .browser(browser.id)),
            to: nil, session: { _ in "old" }
        ))
        let main = manager.mainTabs.tabs(hostID: host, session: "old")
        main.selectedBrowserTabId = browser.id
        let unrelatedSession = otherSession.tabs.tabs(hostID: host, session: "other")
        let unrelatedHost = foreign.tabs.tabs(hostID: "foreign", session: "old")
        let unrelatedMain = manager.mainTabs.tabs(hostID: "foreign", session: "old")
        for _ in 0..<3 {
            manager.renameSession(hostID: host, from: "old", to: "new", windowIDs: ["old:0": "new:0"])
            #expect(manager.mainTabs.existing(hostID: host, session: "new") === main)
            #expect(manager.mainTabs.existing(hostID: host, session: "old") == nil)
            #expect(source.tabs.existing(hostID: host, session: "new") === sourceTabs)
            #expect(source.tabs.existing(hostID: host, session: "old") == nil)
            #expect(source.sessionName == "new")
            #expect(manager.browserOwner(hostID: host, session: "new", id: browser.id, windowID: "@0") == nil)
            #expect(main.selectedBrowserTabId == browser.id)
            #expect(otherSession.sessionName == "other")
            #expect(otherSession.tabs.existing(hostID: host, session: "other") === unrelatedSession)
            #expect(foreign.sessionName == "old")
            #expect(foreign.tabs.existing(hostID: "foreign", session: "old") === unrelatedHost)
            #expect(manager.mainTabs.existing(hostID: "foreign", session: "old") === unrelatedMain)
        }
    }

    @Test
    func multipleTerminalsCanMoveBothWaysOnlyWithinTheirHostAndSession() throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let b = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        let foreign = try #require(DetachedTerminalTarget(hostID: "remote", windowID: "@2"))
        let otherSession = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@3"))
        let session: (DetachedTerminalTarget) -> String? = { $0 == otherSession ? "other" : "work" }
        manager.reserve(a)
        let group = try #require(manager.workspace(containing: a))
        #expect(manager.merge(b, into: group.id, session: session))
        #expect(group.members == [a, b])
        #expect(!manager.merge(foreign, into: group.id, session: session))
        #expect(!manager.merge(otherSession, into: group.id, session: session))
        #expect(manager.focus(hostID: nil, windowID: "@1"))
        #expect(group.selection == .window("@1"))
        let drag = WorkbenchTabDrag(workspaceID: group.id, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(manager.transfer(drag, to: nil, session: session))
        #expect(group.members == [b])
        #expect(manager.owner(hostID: nil, windowID: "@1") == nil)
        // The scene's original terminal can detach again without aliasing the old scene.
        #expect(manager.reserve(a))
        #expect(manager.workspace(containing: a)?.id != group.id)
    }

    @Test
    func directoryAndBrowserStateMoveWithoutRecreationAndReturnOnNativeClose() throws {
        _ = NSApplication.shared
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        manager.reserve(target)
        let group = try #require(manager.workspace(containing: target))
        let main = manager.mainTabs.tabs(hostID: nil, session: "work")
        let files = FileBrowserTab(path: "/tmp", sourcePaneID: "%1")
        files.query = "report"
        main.openFileTabs = [.init(id: files.id, path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        main.directoryTabs[files.id] = files
        main.selectedFileTabId = files.id
        main.rightSide = [.file(files.id)]
        main.selectedRight = .file(files.id)
        let browser = try BrowserTab(url: #require(URL(string: "about:blank")))
        let browserState = BrowserTabState(initialURL: browser.url)
        main.openBrowserTabs = [browser]
        main.browserStates[browser.id] = browserState
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .file(files.id))
        #expect(manager.transfer(drag, to: group.id, session: { _ in "work" }))
        let detached = group.tabs.tabs(hostID: nil, session: "work")
        #expect(detached.directoryTabs[files.id] === files)
        #expect(detached.directoryTabs[files.id]?.query == "report")
        #expect(main.directoryTabs.isEmpty && main.selectedFileTabId == nil && main.selectedRight == nil)
        #expect(manager.transfer(
            WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .browser(browser.id)),
            to: group.id,
            session: { _ in "work" }
        ))
        #expect(detached.browserStates[browser.id] === browserState)
        #expect(main.browserStates.isEmpty)
        let native = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        native.isReleasedWhenClosed = false
        manager.attach(native, to: target)
        manager.didClose(target, window: native)
        #expect(manager.targets.isEmpty)
        #expect(main.directoryTabs[files.id] === files)
        #expect(main.openFileTabs.map(\.id) == [files.id])
        #expect(main.browserStates[browser.id] === browserState)
        #expect(main.openBrowserTabs.map(\.id) == [browser.id])
    }

    @Test
    func filesOnlyWorkspaceCanAdoptANewTerminal() throws {
        let manager = DetachedTerminalWindows()
        let first = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let created = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        manager.reserve(first)
        let group = try #require(manager.workspace(containing: first))
        let tabs = group.tabs.tabs(hostID: nil, session: "work")
        tabs.openFileTabs = [.init(path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        manager.returnToMain(first)
        #expect(group.members.isEmpty)
        #expect(manager.merge(created, into: group.id, session: { _ in "work" }))
        #expect(group.members == [created])
        #expect(group.selection == .window("@2"))
    }

    @Test
    func crossSceneDropRejectsStaleSourcesAndForeignDestinations() throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: "A", windowID: "@1"))
        let b = try #require(DetachedTerminalTarget(hostID: "B", windowID: "@1"))
        manager.reserve(a)
        manager.reserve(b)
        let one = try #require(manager.workspace(containing: a))
        let two = try #require(manager.workspace(containing: b))
        let drag = WorkbenchTabDrag(workspaceID: one.id, hostID: "A", sessionName: "work", tab: .window("@1"))
        #expect(!manager.transfer(drag, to: two.id, session: { _ in "work" }))
        let forged = WorkbenchTabDrag(workspaceID: nil, hostID: "A", sessionName: "work", tab: .window("@1"))
        #expect(!manager.transfer(forged, to: one.id, session: { _ in "work" }))
        #expect(manager.targets == [a, b])
    }

    @Test
    func reorderSubsetPreservesOtherNativeWindows() {
        #expect(TabDragPayload.mergingWindowOrder(["@3", "@1"], into: ["@1", "@2", "@3", "@4"]) == ["@3", "@2", "@1", "@4"])
        #expect(TabDragPayload.mergingWindowOrder(["@1", "@1"], into: ["@1", "@2"]) == nil)
        #expect(TabDragPayload.mergingWindowOrder(["@8"], into: ["@1", "@2"]) == nil)
    }

    @Test
    func detachUsesTheSameTransferAndClearsTheSourceSplit() throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let main = manager.mainTabs.tabs(hostID: nil, session: "work")
        main.tabOrder = [.window("@1"), .window("@2")]
        main.rightSide = [.window("@1"), .window("@2")]
        main.selectedRight = .window("@1")
        let first = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        #expect(main.rightSide == [.window("@2")])
        #expect(main.selectedRight == .window("@2"))
        #expect(first.members == [target])
        let second = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        #expect(first.id != second.id)
        #expect(manager.workspaces[first.id] == nil)
        #expect(manager.owner(hostID: nil, windowID: "@1") == second.id)
        #expect(manager.presentationRevision == 2)
    }

    @Test
    func stableIdentityIncludesHost() throws {
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        let another = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@12"))
        #expect(Set([local, remote, another]).count == 3)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "session:1") == nil)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "%12") == nil)
        #expect(try JSONDecoder().decode(DetachedTerminalTarget.self, from: JSONEncoder().encode(remote)) == remote)
    }

    @Test
    func reservationIsUniqueAndCloseOnlyReleasesItsOwnPresentation() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
        #expect(!state.reserve(local))
        #expect(state.reserve(remote))
        let old = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let current = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        state.attach(old, to: local)
        state.attach(current, to: local)
        state.didClose(local, window: old)
        #expect(state.contains(hostID: nil, windowID: "@12"))
        state.didClose(local, window: current)
        #expect(!state.contains(hostID: nil, windowID: "@12"))
        #expect(state.contains(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
    }

    @Test
    func requestsCaptureSourceAndDoNotRevokeOwnership() throws {
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@8"))
        state.reserve(target)
        state.request(.files(paneID: "%9"), from: target)
        let first = try #require(state.mainRequest)
        state.request(.fork(paneID: "%9", worktree: true), from: target)
        #expect(state.mainRequest?.target == target)
        #expect(state.mainRequest?.id != first.id)
        #expect(state.mainRequest?.action == .fork(paneID: "%9", worktree: true))
        state.request(.url("https://example.com", paneID: "%9"), from: target)
        #expect(state.mainRequest?.target == target)
        #expect(state.mainRequest?.action == .url("https://example.com", paneID: "%9"))
        #expect(state.targets == [target])
    }

    @Test
    func nativeCloseReleasesOwnershipEvenAfterContentReparenting() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@19"))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        state.reserve(target)
        window.contentView = NSHostingView(rootView: DetachedTerminalRegistration(target: target, windows: state))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView = NSView()
        #expect(state.targets.contains(target))
        state.close(target)
        #expect(!state.targets.contains(target))
    }

    @Test
    func rightSideReturnNeverDuplicatesTheLeftRenderer() {
        let windows = [(stableID: "@1", id: "renamed:3"), (stableID: "@2", id: "renamed:7")]
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@2"]) == "renamed:3")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: []) == "renamed:7")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@1", "@2"]) == nil)
    }

    @Test
    func dragOriginStaysInsideItsTabEvenWhenHostingVisibleRectIsLarger() {
        let bounds = CGRect(x: 0, y: 0, width: 109, height: 25)
        let hostVisibleRect = CGRect(x: -242.5, y: -1, width: 900, height: 79)
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 150, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: -85, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 40), bounds: bounds, visibleRect: hostVisibleRect))

        let clipped = CGRect(x: 40, y: 0, width: 69, height: 25)
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 20, y: 12), bounds: bounds, visibleRect: clipped))
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: clipped))
    }

    @Test
    func onlyUnclaimedMouseReleaseAwayFromTabStripDetaches() {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        let belowStrip = CGPoint(x: 500, y: 500)
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: .move, cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: .copy, cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: true, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: false, point: belowStrip, tabStripFrame: frame))
    }

    @Test
    func maximizedWindowCanDetachIntoItsOwnContent() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = WindowTabDragSource.tabStripFrame(
            tabFrame: CGRect(x: 240, y: 820, width: 100, height: 26), windowFrame: windowFrame
        )
        #expect(frame == CGRect(x: 0, y: 820, width: 1_440, height: 26))
        let point = CGPoint(x: 300, y: 740)
        #expect(windowFrame.contains(point))
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test(arguments: [CGPoint(x: 500, y: 663), CGPoint(x: 890, y: 663), CGPoint(x: 500, y: 630), CGPoint(x: 500, y: 696)])
    func reorderingAndSmallVerticalMovementDoNotDetach(point: CGPoint) {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test(arguments: [CGPoint(x: 500, y: 620), CGPoint(x: 500, y: 706), CGPoint(x: 70, y: 663), CGPoint(x: 930, y: 663)])
    func movingBeyondStripMarginDetaches(point: CGPoint) {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test
    func tabStripCoordinatesSupportAnotherDisplay() {
        let frame = WindowTabDragSource.tabStripFrame(
            tabFrame: CGRect(x: -1_300, y: -100, width: 110, height: 26),
            windowFrame: CGRect(x: -1_600, y: -900, width: 1_600, height: 900)
        )
        #expect(frame == CGRect(x: -1_600, y: -100, width: 1_600, height: 26))
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: CGPoint(x: -1_200, y: -200), tabStripFrame: frame))
    }

    @Test
    func draggingPayloadMatchesExistingTabDropProtocol() throws {
        let original = TabDragPayload.window("@23")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TabDragPayload.self, from: data) == original)
    }

    @Test(arguments: [true, false])
    func releasePointStaysTiedToMouseUpEvent(releasedInsideStrip: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let inside = CGPoint(x: 400, y: 563)
        let outside = CGPoint(x: 400, y: 400)
        let releaseLocation = releasedInsideStrip ? inside : outside
        let laterLocation = releasedInsideStrip ? outside : inside
        let release = try mouseEvent(.leftMouseUp, location: releaseLocation, window: window, timestamp: 1)
        let laterMove = try mouseEvent(.mouseMoved, location: laterLocation, window: window, timestamp: 2)
        #expect(release.window === window)
        let laterPoint = WindowTabDragSource.screenPoint(for: laterMove)
        let releasePoint = WindowTabDragSource.screenPoint(for: release)
        #expect(releasePoint == window.convertPoint(toScreen: releaseLocation))
        #expect(laterPoint == window.convertPoint(toScreen: laterLocation))
        #expect(releasePoint != laterPoint)
        let strip = window.convertToScreen(CGRect(x: 0, y: 550, width: 800, height: 26))
        #expect(WindowTabDragSource.shouldDetach(
            operation: [], cancelled: false, mouseReleased: true,
            point: releasePoint, tabStripFrame: strip
        ) == !releasedInsideStrip)
    }

    @Test
    func windowlessReleaseAlreadyUsesScreenCoordinates() throws {
        let point = CGPoint(x: -1_200, y: 500)
        let event = try mouseEvent(.leftMouseUp, location: point, window: nil, timestamp: 1)
        #expect(event.window == nil)
        #expect(WindowTabDragSource.screenPoint(for: event) == point)
    }

    private func mouseEvent(_ type: NSEvent.EventType, location: CGPoint, window: NSWindow?, timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    @Test
    func placementSupportsNegativeScreenOrigins() {
        let display = CGRect(x: -1_600, y: 0, width: 1_600, height: 1_000)
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -1_650, y: -200), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_600, y: 0))
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -50, y: 900), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_000, y: 300))
    }
}
