import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct IOSPaneLinkedTabsTests {
    @Test("Reordering visible children preserves missing IDs and other pane groups")
    func moveWithPartialCatalog() throws {
        let a = FileBrowserTab(path: "/A", sourcePaneID: "%1")
        let b = FileBrowserTab(path: "/B", sourcePaneID: "%1")
        let other = FileBrowserTab(path: "/Other", sourcePaneID: "%2")
        let newFile = FileBrowserTab(path: "/New", sourcePaneID: "%2")
        let web = UUID(), simulator = UUID(), missingFile = UUID()
        let saved: [PaneLinkedTabID] = [.file(a.id), .browser(web), .file(other.id), .file(b.id), .simulator(simulator), .file(missingFile)]
        let layout = IOSPaneLinkedTabs(files: [a, b, other, newFile], browsers: [], simulators: [], windows: [], storedOrder: saved)
        let group = try #require(layout.groups.first { $0.id == "%1" })

        #expect(layout.moving(IndexSet(integer: 0), to: 2, in: group) == [
            .file(b.id), .browser(web), .file(other.id), .file(a.id), .simulator(simulator), .file(missingFile), .file(newFile.id),
        ])
    }

    @Test("A move crosses types only within its source pane; names distinguish split panes")
    func mixedMove() throws {
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let web = RemoteBrowserTab(id: UUID(), sessionName: "work", title: "Web", url: "about:blank", isLoading: false, isAgentOwned: false, sourcePaneID: "%1")
        let sim = RemoteSimulatorTab(id: UUID(), sessionName: "work", windowID: "@1", sourcePaneID: "%2", title: "Phone", runtime: "iOS", isPrimary: true)
        let windows = TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", paneIndex: 0, windowName: "dev"),
            PaneState(paneId: "%2", sessionName: "work", tmuxWindowId: "@1", paneIndex: 1, windowName: "dev"),
        ])
        let layout = IOSPaneLinkedTabs(files: [file], browsers: [web], simulators: [sim], windows: windows, storedOrder: [])
        #expect(layout.groups.map(\.id) == ["%1", "%2"])
        #expect(layout.title(for: "%1") == "dev · 1")
        #expect(layout.title(for: "%2") == "dev · 2")
        let group = try #require(layout.groups.first)
        #expect(layout.moving(IndexSet(integer: 0), to: 2, in: group) == [.browser(web.id), .file(file.id), .simulator(sim.id)])
        #expect(layout.sourcePaneID(.simulator(sim.id)) == "%2")
        #expect(layout.sourceWindow(for: .simulator(sim.id))?.id == windows.first?.id)
        #expect(layout.sourceWindow(for: .file(UUID())) == nil)
    }
}
