import CtrlxCommon
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite @MainActor
struct WorkspaceTerminalSelectionTests {
    @Test("Closing the selected window chooses the first eligible tab even if tmux changes active window", arguments: [false, true])
    func closedSelection(followsActive: Bool) {
        #expect(WorkspaceTerminalSelection.leftWindowID(
            current: "@closed", orderedIDs: ["@8", "@4", "@2"], activeID: "@2", rightSide: [],
            followsActive: followsActive, owns: { _ in true }
        ) == "@8")
        #expect(WorkspaceTerminalSelection.leftWindowID(
            current: "@closed", orderedIDs: ["@8", "@4", "@2"], activeID: "@2", rightSide: ["@8"],
            followsActive: followsActive, owns: { _ in true }
        ) == "@4")
    }

    @Test("Right-pane close follows visible tab order and preserves background selections")
    func rightCloseOrder() {
        let tabs = SessionFileTabsState()
        tabs.rightSide = [.window("@3"), .window("@2")]
        tabs.tabOrder = [.window("@1"), .window("@3"), .window("@2")]
        tabs.selectedRight = .window("@closed")
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2", "@3"], includeLocalTabs: true)
        #expect(tabs.selectedRight == .window("@3"))
        tabs.selectedRight = .window("@2")
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2", "@3"], includeLocalTabs: true)
        #expect(tabs.selectedRight == .window("@2"))
    }

    @Test("Mixed right tabs prefer the first remaining terminal on Host and Viewer", arguments: [false, true])
    func mixedRightCloseOrder(local: Bool) {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        tabs.openFileTabs = [file]
        let files: TabDragPayload = local ? .fileExplorer : .file(file.id)
        tabs.rightSide = [files, .window("@3"), .window("@2")]
        tabs.tabOrder = [files, .window("@1"), .window("@3"), .window("@2")]
        tabs.selectedRight = .window("@closed")
        func reconcile(_ windows: [String]) {
            if local {
                tabs.reconcileRightPaneSelection(sessionWindowIDs: windows, includeLocalTabs: true)
            } else {
                tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: windows)
            }
        }
        reconcile(["@1", "@2", "@3"])
        #expect(tabs.selectedRight == .window("@3"))
        // A background close must not take focus away from Files.
        tabs.selectedRight = files
        reconcile(["@1", "@2", "@3"])
        #expect(tabs.selectedRight == files)
        tabs.selectedRight = .window("@3")
        tabs.rightSide = [files]
        reconcile(["@1"])
        #expect(tabs.selectedRight == files)
        #expect(tabs.isSplit)
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func draggingLeftTerminalAwaySkipsRightTerminal(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        _ = try #require(manager.detach(a, position: nil, session: { _ in "work" }))
        let selected = WorkspaceTerminalSelection.leftWindowID(
            current: "@1", orderedIDs: ["@1", "@2", "@3"], activeID: "@2", rightSide: ["@2"],
            owns: { manager.owner(hostID: host, windowID: $0) == nil }
        )
        #expect(selected == "@3")
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func splitFallbackNeverSelectsMainWindow(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let b = try #require(DetachedTerminalTarget(hostID: host, windowID: "@3"))
        let group = try #require(manager.detach(a, position: nil, session: { _ in "work" }))
        #expect(manager.merge(b, into: group.id, session: { _ in "work" }))
        let selected = WorkspaceTerminalSelection.leftWindowID(
            current: "@2", orderedIDs: ["@1", "@2", "@3"], activeID: "@1", rightSide: ["@2"],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(selected == "@3")
        let noLeft = WorkspaceTerminalSelection.leftWindowID(
            current: "@1", orderedIDs: ["@1", "@2", "@3"], activeID: "@1", rightSide: ["@2", "@3"],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(noLeft == nil)
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func terminalExitPreservesFilesAndAllowsNewTerminal(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let old = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let new = try #require(DetachedTerminalTarget(hostID: host, windowID: "@3"))
        let group = try #require(manager.detach(old, position: nil, session: { _ in "work" }))
        let tabs = group.tabs.tabs(hostID: host, session: "work")
        let directory = FileBrowserTab(path: "/tmp")
        tabs.openFileTabs = [.init(id: directory.id, path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        tabs.directoryTabs[directory.id] = directory
        let surviving = WorkspaceTerminalSelection.leftWindowID(
            current: old.windowID, orderedIDs: ["@1"], activeID: "@1", rightSide: [],
            owns: { manager.owner(hostID: host, windowID: $0) == group.id }
        )
        #expect(surviving == nil)
        tabs.repairLeftContent(hasTerminal: surviving != nil)
        #expect(tabs.selectedFileTabId == directory.id)
        // The old terminal no longer resolves; a terminal in the main window keeps the session alive.
        let session: (DetachedTerminalTarget) -> String? = { $0 == old ? nil : "work" }
        #expect(group.resolvedSession(using: session) == "work")
        #expect(manager.merge(new, into: group.id, session: session))
        #expect(manager.owner(hostID: host, windowID: new.windowID) == group.id)
        #expect(tabs.directoryTabs[directory.id] === directory)
    }

    @Test
    func filesOnlyWorkspaceStillAcceptsSameSessionDrops() throws {
        let manager = DetachedTerminalWindows()
        let old = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        let group = try #require(manager.detach(old, position: nil, session: { _ in "work" }))
        let session: (DetachedTerminalTarget) -> String? = { $0.windowID == "@1" ? "work" : nil }
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(manager.transfer(drag, to: group.id, session: session))
        #expect(manager.owner(hostID: nil, windowID: "@1") == group.id)
        let foreign = WorkbenchTabDrag(workspaceID: nil, hostID: "other", sessionName: "work", tab: .window("@1"))
        #expect(!manager.transfer(foreign, to: group.id, session: { _ in "work" }))
    }

    @Test
    func privateFallbackUsesLeftTabOrderAndPreservesValidSelection() throws {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        let browser = try BrowserTab(url: #require(URL(string: "about:blank")))
        tabs.openFileTabs = [file]
        tabs.openBrowserTabs = [browser]
        tabs.tabOrder = [.browser(browser.id), .file(file.id)]
        tabs.rightSide = [.browser(browser.id)]
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == file.id)
        tabs.rightSide = []
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == file.id)
        tabs.openFileTabs = []
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.selectedFileTabId == nil)
        #expect(tabs.selectedBrowserTabId == browser.id)
    }

    @Test
    func remainingPrivateRightTabCollapsesWithoutAnyTerminal() {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp", directoryPath: "/tmp", isDirectory: true)
        tabs.openFileTabs = [file]
        tabs.rightSide = [.file(file.id)]
        tabs.selectedRight = .file(file.id)
        #expect(tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: []))
        tabs.repairLeftContent(hasTerminal: false)
        #expect(!tabs.isSplit)
        #expect(tabs.selectedFileTabId == file.id)
    }

    @Test
    func followActiveNeverEscapesOwnershipOrRightSide() {
        for active in ["@1", "@2"] {
            #expect(WorkspaceTerminalSelection.leftWindowID(
                current: "@3", orderedIDs: ["@1", "@2", "@3"], activeID: active,
                rightSide: ["@2"], followsActive: true, owns: { $0 != "@1" }
            ) == "@3")
        }
    }
}
