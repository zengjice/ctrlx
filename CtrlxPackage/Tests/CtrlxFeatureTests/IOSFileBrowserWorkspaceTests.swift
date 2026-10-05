import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
@Suite("iOS Files workspace persistence")
struct IOSFileBrowserWorkspaceTests {
    private func context(_ directory: String, hostID: String = "office") throws -> IOSFileBrowserWorkspace.Context {
        try #require(IOSFileBrowserWorkspace.Context(hostID: hostID, windows: TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", currentPath: directory, isWindowActive: true),
        ])))
    }

    @Test("Switching A to B and opening Files restores both tabs on session re-entry")
    func restoresAfterWindowSwitch() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            var panes = [
                PaneState(paneId: "%1", sessionName: "work", windowIndex: 1, currentPath: "/host/A", isWindowActive: true),
                PaneState(paneId: "%2", sessionName: "work", windowIndex: 2, currentPath: "/host/B"),
            ]
            let workspace = IOSFileBrowserWorkspace()
            workspace.updateContext(.init(hostID: "office", windows: TmuxWindow.groupPanes(panes)))
            workspace.open(paneID: "%1")
            workspace.selected?.navigate("/host/A")
            workspace.save()

            panes[0].isWindowActive = false
            panes[1].isWindowActive = true
            workspace.updateContext(.init(hostID: "office", windows: TmuxWindow.groupPanes(panes)))
            workspace.open(paneID: "%2")
            workspace.selected?.navigate("/host/B")
            workspace.save()

            let reopened = IOSFileBrowserWorkspace()
            reopened.updateContext(.init(hostID: "office", windows: TmuxWindow.groupPanes(panes)))
            #expect(reopened.snapshots == workspace.snapshots)
            #expect(reopened.tabs.map(\.path) == ["/host/A", "/host/B"])
            #expect(reopened.tabs.allSatisfy { $0.sourcePaneID == nil })

            let originalDirectory = IOSFileBrowserWorkspace()
            originalDirectory.updateContext(try context("/host/A"))
            #expect(originalDirectory.tabs.map(\.path) == ["/host/A"])
        }
    }

    @Test("Changing only the directory saves live tabs without reloading the destination's layout")
    func directoryChangeSavesWithoutTabEdits() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let previous = IOSFileBrowserWorkspace()
            previous.updateContext(try context("/host/B"))
            previous.tabs = [FileBrowserTab(path: "/host/old-B")]
            previous.save()

            let workspace = IOSFileBrowserWorkspace()
            workspace.updateContext(try context("/host/A"))
            let liveTab = FileBrowserTab(path: "/host/A", sourcePaneID: "%1")
            workspace.tabs = [liveTab]
            workspace.selectedID = liveTab.id
            workspace.save()
            // Same window/pane ID; a plain `cd` must change the save context too.
            workspace.updateContext(try context("/host/B"))
            #expect(workspace.selected === liveTab)

            let reopened = IOSFileBrowserWorkspace()
            reopened.updateContext(try context("/host/B"))
            #expect(reopened.snapshots == workspace.snapshots)
            #expect(reopened.tabs.first?.id == liveTab.id)
        }
    }

    @Test("Repeated or temporarily missing context does not overwrite live state")
    func repeatedAndMissingContext() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let workspace = IOSFileBrowserWorkspace()
            workspace.updateContext(nil)
            workspace.save()
            let directory = try context("/host/A")
            workspace.updateContext(directory)
            workspace.open(paneID: "%1")
            workspace.selected?.navigate("/host/A/child")
            let liveTab = try #require(workspace.selected)
            workspace.updateContext(directory)
            workspace.updateContext(nil)
            #expect(workspace.selected === liveTab)
            workspace.save()

            let reopened = IOSFileBrowserWorkspace()
            reopened.updateContext(directory)
            #expect(reopened.snapshots == workspace.snapshots)
        }
    }

    @Test("A late first context seeds an empty workspace but never clobbers user-opened Files", arguments: [false, true])
    func lateContext(userOpenedFiles: Bool) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let directory = try context("/host/A")
            let existing = FileBrowserTab(path: "/host/saved")
            // The v1 key and payload written by the previous implementation remain readable.
            @Dependency(PreferencesService.self) var preferences
            let key = "fileBrowserWorkspace.v1." + (try JSONEncoder().encode(["office", "/host/A"])).base64EncodedString()
            preferences.setData(value: try JSONEncoder().encode([try #require(existing.snapshot)]), forKey: key)

            let workspace = IOSFileBrowserWorkspace()
            workspace.updateContext(nil)
            if userOpenedFiles {
                workspace.open(paneID: "%1")
                workspace.selected?.navigate("/host/new")
            }
            workspace.updateContext(directory)
            #expect(workspace.tabs.first?.path == (userOpenedFiles ? "/host/new" : "/host/saved"))
            let reopened = IOSFileBrowserWorkspace()
            reopened.updateContext(directory)
            #expect(reopened.snapshots == workspace.snapshots)
        }
    }

    @Test("Hosts remain isolated and closing the final tab persists an empty workspace")
    func hostIsolationAndClose() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let office = IOSFileBrowserWorkspace()
            office.updateContext(try context("/shared"))
            office.open(paneID: "%1")
            office.selected?.navigate("/shared/office")
            office.save()
            let home = IOSFileBrowserWorkspace()
            home.updateContext(try context("/shared", hostID: "home"))
            #expect(home.tabs.isEmpty)
            home.tabs = [FileBrowserTab(path: "/shared/home")]
            home.save()
            office.closeSelected()

            let reopenedOffice = IOSFileBrowserWorkspace()
            reopenedOffice.updateContext(try context("/shared"))
            #expect(reopenedOffice.tabs.isEmpty)
            let reopenedHome = IOSFileBrowserWorkspace()
            reopenedHome.updateContext(try context("/shared", hostID: "home"))
            #expect(reopenedHome.snapshots == home.snapshots)
        }
    }

    @Test("Context follows Host active window/pane and agent project, and waits for a real directory")
    func resolvesHostContext() throws {
        var panes = [
            PaneState(paneId: "%1", sessionName: "work", windowIndex: 1, currentPath: "/host/A"),
            PaneState(paneId: "%2", sessionName: "work", windowIndex: 2, currentPath: "/host/B", isWindowActive: true),
            PaneState(paneId: "%3", sessionName: "work", windowIndex: 2, paneIndex: 1, currentPath: "/host/C", isActive: true, isWindowActive: true),
        ]
        func resolved() -> IOSFileBrowserWorkspace.Context? {
            .init(hostID: "office", windows: TmuxWindow.groupPanes(panes))
        }
        #expect(resolved()?.directory == "/host/C")
        panes[2].agentSession = AgentSession(paneId: "%3", pluginID: "codex", detectedProjectPath: "/host/project")
        #expect(resolved()?.directory == "/host/project")
        panes[2].isActive = false
        panes[1].isActive = true
        #expect(resolved()?.directory == "/host/B")
        panes[1].currentPath = nil
        #expect(resolved() == nil)
        #expect(IOSFileBrowserWorkspace.Context(hostID: "office", windows: []) == nil)
    }
}
