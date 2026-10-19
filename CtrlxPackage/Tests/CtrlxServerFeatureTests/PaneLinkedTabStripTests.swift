import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct PaneLinkedTabStripTests {
    @Test("Transient tab order restores without recreating content, including delayed catalogs")
    func restoredOrder() throws {
        let tabs = SessionFileTabsState()
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        var web = BrowserTab(url: URL(fileURLWithPath: "/unused"), sourcePaneID: "%1")
        web.isAgentBrowser = true
        tabs.directoryTabs[file.id] = file
        tabs.openFileTabs = [.init(id: file.id, path: "/project", directoryPath: "/project", isDirectory: true)]
        tabs.openBrowserTabs = [web]
        tabs.tabOrder = [.browser(web.id), .file(file.id)]
        let snapshot = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
        let decoded = try JSONDecoder().decode(SavedFolderLayout.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.browserTabs.isEmpty)
        #expect(decoded.linkedTabOrder == [.browser(web.id), .file(file.id)])
        #expect(!SavedFolderLayout(linkedTabOrder: [.browser(web.id)]).isEmpty)
        #expect(SavedFolderLayout().isEmpty)
        let restored = SessionFileTabsState()
        LayoutSnapshotMapper.apply(decoded, to: restored, fileBrowser: nil, windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })
        #expect(restored.openBrowserTabs.isEmpty)
        restored.recordVisibleTabOrder([.file(file.id)])
        #expect(restored.tabOrder == [.browser(web.id), .file(file.id)])
        restored.openBrowserTabs = [web]
        restored.directoryTabs[file.id]?.restoreSourcePane("%1")
        let order = TabDragPayload.reconciledOrder(windowIds: [], fileTabIds: [file.id], browserTabIds: [web.id], storedOrder: restored.tabOrder, includeFileExplorer: false, includeGit: false)
        #expect(restored.groupedTabOrder(order, paneOrder: ["%1"]) == [.browser(web.id), .file(file.id)])
    }

    @Test("Mac grouping uses actual pane metadata, including mixed Host browser/simulator tabs")
    func groupingAndDrop() {
        let tabs = SessionFileTabsState()
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let web = UUID(), sim = UUID(), other = UUID()
        tabs.directoryTabs[file.id] = file
        tabs.remoteBrowserTabs[web] = .init(id: web, sessionName: "work", windowID: "@1", title: "Web", url: "about:blank", isLoading: false, isAgentOwned: false, sourcePaneID: "%1")
        tabs.remoteSimulatorTabs[sim] = .init(id: sim, sessionName: "work", windowID: "@1", sourcePaneID: "%1", title: "Phone", runtime: "iOS", isPrimary: true)
        tabs.remoteBrowserTabs[other] = .init(id: other, sessionName: "work", windowID: "@1", title: "Other pane", url: "about:blank", isLoading: false, isAgentOwned: false, sourcePaneID: "%2")
        let order: [TabDragPayload] = [.browser(web), .window("@1"), .browser(other), .file(file.id), .browser(sim)]
        #expect(tabs.groupedTabOrder(order, paneOrder: ["%1", "%2"]) == [.window("@1"), .browser(web), .file(file.id), .browser(sim), .browser(other)])
        #expect(tabs.canReorder(.browser(sim), before: .file(file.id)))
        #expect(!tabs.canReorder(.browser(web), before: .browser(other)))
        #expect(!tabs.canReorder(.file(file.id), before: .window("@1")))
        #expect(!tabs.canReorder(.window("@1"), before: .file(file.id)))
        #expect(tabs.canReorder(.window("@1"), before: .window("@2")))
    }
}
