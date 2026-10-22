import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor @Suite("iOS Host Files presentation")
struct IOSFileBrowserWorkspaceTests {
    @Test("File tab reorder preserves selection, persists order and rejects stale or duplicate lists")
    func reorderFiles() throws {
        try withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let workspace = IOSFileBrowserWorkspace()
            let context = try context("/host/project")
            workspace.updateContext(context)
            let first = FileBrowserTab(path: "/host/first")
            let second = FileBrowserTab(path: "/host/second")
            workspace.tabs = [first, second]
            workspace.selectedID = first.id
            workspace.reorder([second.id, first.id])
            #expect(workspace.tabs.map(\.id) == [second.id, first.id])
            #expect(workspace.selected === first)
            workspace.reorder([first.id, first.id])
            workspace.reorder([first.id, UUID()])
            #expect(workspace.tabs.map(\.id) == [second.id, first.id])
            let restored = IOSFileBrowserWorkspace()
            restored.updateContext(context)
            #expect(restored.tabs.map(\.path) == ["/host/second", "/host/first"])
        }
    }

    private func descriptor(_ pane: String = "%1") -> HostFileTab {
        .init(sessionName: "work", windowID: "@1", sourcePaneID: pane, initialDirectory: "/host/project")
    }

    @Test("Manual open and links adopt Host identity; catalog updates never navigate clients")
    func adoptsHostIdentity() {
        let workspace = IOSFileBrowserWorkspace(), otherViewer = IOSFileBrowserWorkspace()
        let first = descriptor(), second = descriptor("%2")
        let tab = workspace.adopt(first)
        workspace.adopt(second)
        otherViewer.adopt(first)
        tab.openTerminalFile(.init(directory: "/host/output", file: "/host/output/report.pdf"), paneID: "%1")
        workspace.selectedID = tab.id
        for _ in 0..<3 {
            workspace.syncHostTabs([second, first])
            #expect(workspace.adopt(first) === tab)
            #expect(workspace.tabs.count == 2)
            #expect(workspace.selected === tab)
            #expect(tab.selectedFile == "/host/output/report.pdf")
            #expect(tab.path == "/host/output")
        }
        #expect(otherViewer.tabs.first?.path == first.initialDirectory)
        #expect(otherViewer.selectedID == nil)
        workspace.syncHostTabs([second])
        #expect(workspace.selectedID == nil)
        #expect(workspace.tabs.map(\.id) == [second.id])
    }

    private func context(_ directory: String, hostID: String = "office") throws -> IOSFileBrowserWorkspace.Context {
        try #require(IOSFileBrowserWorkspace.Context(hostID: hostID, windows: TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", currentPath: directory, isWindowActive: true),
        ])))
    }

    @Test("Disk restoration preserves legacy contents but never resurrects dead Host IDs")
    func restoration() throws {
        try withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let context = try context("/host")
            let workspace = IOSFileBrowserWorkspace()
            workspace.updateContext(context)
            let legacy = FileBrowserTab(path: "/host/legacy", sourcePaneID: "%9")
            workspace.tabs = [legacy]
            let descriptor = descriptor()
            workspace.adopt(descriptor)
            workspace.save()
            // Previously written Host snapshots must not resurrect dead catalog IDs.
            @Dependency(PreferencesService.self) var preferences
            let key = try #require(context.storageKey)
            let staleHost = try #require(workspace.tabs.last?.snapshot)
            try preferences.setData(value: JSONEncoder().encode(workspace.snapshots + [staleHost]), forKey: key)
            let restored = IOSFileBrowserWorkspace()
            restored.updateContext(context)
            #expect(restored.tabs.map(\.id) == [legacy.id])
            #expect(restored.tabs.first?.sourcePaneID == nil)
            restored.syncHostTabs([self.descriptor()])
            #expect(restored.tabs.count == 2)
            #expect(!restored.tabs.contains { $0.id == descriptor.id })
        }
    }

    @Test("Context changes cannot replace a live model with saved layout")
    func contextChanges() throws {
        try withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let workspace = IOSFileBrowserWorkspace()
            let tab = workspace.adopt(descriptor())
            tab.navigate("/host/child")
            try workspace.updateContext(context("/host/A"))
            workspace.updateContext(nil)
            try workspace.updateContext(context("/host/B"))
            #expect(workspace.tabs.first === tab)
            #expect(tab.path == "/host/child")
        }
    }

    @Test("Closing an unselected row preserves selection")
    func closeSpecificTab() {
        let workspace = IOSFileBrowserWorkspace()
        let first = workspace.adopt(descriptor()), second = workspace.adopt(descriptor("%2"))
        workspace.selectedID = second.id
        workspace.close(first.id)
        #expect(workspace.selected === second)
        workspace.closeSelected()
        #expect(workspace.tabs.isEmpty && workspace.selectedID == nil)
    }

    @Test("Legacy persistence stays isolated by Host")
    func legacyPersistence() throws {
        try withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let office = IOSFileBrowserWorkspace()
            try office.updateContext(context("/shared"))
            office.tabs = [FileBrowserTab(path: "/shared/office")]
            office.save()
            let home = IOSFileBrowserWorkspace()
            try home.updateContext(context("/shared", hostID: "home"))
            #expect(home.tabs.isEmpty)
            let restored = IOSFileBrowserWorkspace()
            try restored.updateContext(context("/shared"))
            #expect(restored.snapshots == office.snapshots)
        }
    }
}
