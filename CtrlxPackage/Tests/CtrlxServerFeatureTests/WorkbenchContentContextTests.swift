import CtrlxCommon
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite @MainActor
struct WorkbenchContentContextTests {
    @Test(arguments: [nil, "host-a"] as [String?], [false, true])
    func renamePreservesFilesOnlyWorkspace(host: String?, movedAway: Bool) throws {
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let workspace = DetachedTerminalWorkspace(target: target, sessionName: "old")
        if movedAway {
            workspace.members = []
        }
        let tabs = workspace.tabs.tabs(hostID: host, session: "old")
        let file = OpenFileTab(path: "/project", directoryPath: "/project", origin: .terminalWindow("old:1"), isDirectory: true)
        tabs.openFileTabs = [file]
        tabs.selectedFileTabId = file.id

        // No owned terminal can resolve the name; another workbench keeps the session alive.
        for _ in 0..<2 {
            workspace.renameSession(hostID: host, from: "old", to: "new", windowIDs: ["old:1": "new:1"])
        }
        #expect(workspace.resolvedSession(using: { _ in nil }) == "new")
        #expect(workspace.tabs.existing(hostID: host, session: "old") == nil)
        #expect(workspace.tabs.existing(hostID: host, session: "new") === tabs)
        #expect(tabs.selectedFileTabId == file.id)
        #expect(tabs.openFileTabs.first?.origin == .terminalWindow("new:1"))
        workspace.renameSession(hostID: "other-host", from: "new", to: "foreign", windowIDs: [:])
        workspace.renameSession(hostID: host, from: "other-session", to: "foreign", windowIDs: [:])
        #expect(workspace.sessionName == "new")
    }

    @Test(arguments: [false, true])
    func refreshPreservesGitWithoutLeftTerminal(split: Bool) {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/project", directoryPath: "/project", isDirectory: true)
        tabs.openFileTabs = [file]
        tabs.selectedFileTabId = file.id
        if split {
            tabs.rightSide = [.window("@2")]
            tabs.selectedRight = .window("@2")
        }
        tabs.selectLeftGit()
        for _ in 0..<3 {
            let selected = WorkspaceTerminalSelection.leftWindowID(
                current: nil, orderedIDs: ["@1", "@2"], activeID: "@1", rightSide: tabs.rightSideWindowIds,
                owns: { split && $0 == "@2" }
            )
            tabs.repairLeftContent(hasTerminal: selected != nil)
            #expect(selected == nil)
            #expect(tabs.isGitSelected)
            #expect(tabs.selectedFileTabId == nil)
            #expect(tabs.selectedBrowserTabId == nil)
        }
        #expect(tabs.selectedRight == (split ? .window("@2") : nil))
    }

    @Test
    func gitSelectionIsSessionAndWorkspaceLocal() {
        let main = WorkbenchTabStore(), detached = WorkbenchTabStore()
        let tabs = detached.tabs(hostID: nil, session: "work")
        tabs.selectLeftGit()
        #expect(!main.tabs(hostID: nil, session: "work").isGitSelected)
        #expect(!detached.tabs(hostID: nil, session: "other").isGitSelected)
        detached.renameSession(hostID: nil, from: "work", to: "renamed", windowIDs: [:])
        #expect(detached.existing(hostID: nil, session: "renamed")?.isGitSelected == true)
        #expect(detached.existing(hostID: nil, session: "work") == nil)
    }

    @Test
    func explicitSelectionLeavesGitButRightTerminalDoesNot() {
        let tabs = SessionFileTabsState()
        tabs.selectLeftGit()
        tabs.selectedFileTabId = UUID()
        #expect(!tabs.isGitSelected)
        tabs.selectLeftGit()
        tabs.selectedBrowserTabId = UUID()
        #expect(!tabs.isGitSelected)
        tabs.selectLeftGit()
        tabs.rightSide = [.window("@2")]
        #expect(!tabs.selectLeftTerminalWindow("@2"))
        #expect(tabs.isGitSelected)
        #expect(tabs.selectLeftTerminalWindow("@1"))
        #expect(!tabs.isGitSelected)

        let file = OpenFileTab(path: "/project", directoryPath: "/project", isDirectory: true)
        tabs.openFileTabs = [file]
        tabs.selectLeftGit()
        tabs.rightSide = [.git]
        tabs.selectedRight = .git
        tabs.repairLeftContent(hasTerminal: false)
        #expect(!tabs.isGitSelected)
        #expect(tabs.selectedFileTabId == file.id)
        tabs.selectLeftGit()
        #expect(!tabs.isGitSelected)
        #expect(tabs.selectedRight == .git)
    }

    @Test
    func browserOpeningSnapshotTracksGitWithoutTerminal() {
        let tabs = SessionFileTabsState()
        func snapshot() -> BrowserOpenSelection {
            .init(localWindowID: nil, remoteSession: nil, remoteWindowID: nil, tabs: tabs, fileBrowserActiveWindowIDs: [])
        }
        let initial = snapshot()
        tabs.selectLeftGit()
        #expect(snapshot() != initial)
        let git = snapshot()
        tabs.repairLeftContent(hasTerminal: false)
        #expect(snapshot() == git)
    }

    @Test
    func gitKeepsDirectoryAfterClearingFileSelection() {
        let tabs = SessionFileTabsState()
        let directory = FileBrowserTab(path: "/project/current")
        tabs.directoryTabs[directory.id] = directory
        tabs.openFileTabs = [.init(id: directory.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.selectedFileTabId = directory.id
        func resolve(_ retained: String?, terminal: String? = nil) -> String {
            WorkbenchDirectoryContext.resolve(
                terminalPath: terminal, tabs: tabs, retainedGitPath: retained, homeDirectory: "/home"
            )
        }

        let captured = resolve("/project/old")
        #expect(captured == "/project/current")
        tabs.selectedFileTabId = nil
        #expect(resolve(captured) == captured)
        #expect(resolve(captured, terminal: "/project/terminal") == "/project/terminal")

        tabs.selectedFileTabId = directory.id
        directory.navigate("/project/next")
        #expect(resolve(captured) == "/project/next")
    }

    @Test
    func filePreviewUsesItsDirectoryAndColdWorkspaceUsesHome() {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/project/readme.md", directoryPath: "/project")
        tabs.openFileTabs = [file]
        tabs.selectedFileTabId = file.id
        #expect(WorkbenchDirectoryContext.resolve(
            terminalPath: nil, tabs: tabs, retainedGitPath: "/old", homeDirectory: "/home"
        ) == "/project")
        #expect(WorkbenchDirectoryContext.resolve(
            terminalPath: nil, tabs: nil, retainedGitPath: nil, homeDirectory: "/home"
        ) == "/home")
    }

    @Test(arguments: [nil, "remote-host"] as [String?])
    func filesOnlySearchReusesSelectedTabWithoutCreatingFromTerminal(host: String?) {
        let store = WorkbenchTabStore()
        let tabs = store.tabs(hostID: host, session: "work")
        let directory = FileBrowserTab(path: "/project", sourcePaneID: "%gone")
        tabs.directoryTabs[directory.id] = directory
        tabs.openFileTabs = [.init(id: directory.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.selectedFileTabId = directory.id
        directory.query = "needle"
        var creationRequests = 0
        for _ in 0..<2 {
            tabs.focusContentSearch {
                creationRequests += 1
                return nil
            }
        }
        #expect(creationRequests == 0)
        #expect(directory.searchMode == .content)
        #expect(directory.searchFocusRequest == 2)
        #expect(directory.query == "needle")
        #expect(tabs.selectedFileTabId == directory.id)
    }

    @Test
    func searchCreatesOnlyWhenNoDirectoryTabIsSelected() {
        let tabs = SessionFileTabsState()
        let directory = FileBrowserTab(path: "/project")
        var creationRequests = 0
        tabs.focusContentSearch {
            creationRequests += 1
            return directory
        }
        #expect(creationRequests == 1)
        #expect(directory.searchMode == .content)
        #expect(directory.searchFocusRequest == 1)
        tabs.focusContentSearch { nil }
        #expect(tabs.selectedFileTabId == nil)
        #expect(tabs.selectedBrowserTabId == nil)
    }
}
