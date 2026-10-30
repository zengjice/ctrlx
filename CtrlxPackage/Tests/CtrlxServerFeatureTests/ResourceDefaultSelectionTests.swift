import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct ResourceDefaultSelectionTests {
    @Test("Mac Host and Viewer catalogs do not select Files over an available terminal", arguments: [nil, "viewer-host"] as [String?], [false, true])
    func catalogPreservesTerminal(hostID: String?, independent: Bool) {
        let manager = DetachedTerminalWindows()
        let file = HostFileTab(
            sessionName: "work", windowID: independent ? nil : "@1", sourcePaneID: independent ? nil : "%1",
            initialDirectory: "/host", resourceSessionID: independent ? UUID() : nil
        )
        manager.syncFileTabs(hostID: hostID, descriptors: [file], sessionWindows: ["work": ["@1"]])
        let tabs = manager.mainTabs.tabs(hostID: hostID, session: "work")
        #expect(tabs.selectedFileTabId == nil)
        tabs.selectedFileTabId = file.id
        manager.syncFileTabs(hostID: hostID, descriptors: [file], sessionWindows: ["work": ["@1"]])
        #expect(tabs.selectedFileTabId == file.id)
    }
}
