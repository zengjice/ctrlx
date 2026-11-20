import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct PaneLinkedTabStripTests {
    @Test("Ungrouping or adding a terminal keeps automatic groups behind numbered terminal slots")
    func sharedOrderKeepsAutomaticGroupsBehindTerminals() {
        let tabs = SessionFileTabsState()
        let panes = (1...3).map { index in
            PaneState(paneId: "%\(index)", sessionName: "work", windowIndex: index, tmuxWindowId: "@\(index)", paneIndex: 0)
        }
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID()), cID = SessionTabID.window(UUID())
        let left = FileBrowserTab(path: "/left", sourcePaneID: "%1")
        let right = FileBrowserTab(path: "/right", sourcePaneID: "%2")
        tabs.directoryTabs[left.id] = left
        tabs.directoryTabs[right.id] = right
        let x = TabDragPayload.file(left.id), y = TabDragPayload.file(right.id)
        let xID = SessionTabID.file(left.id), yID = SessionTabID.file(right.id)
        let ids = [a: aID, b: bID, c: cID, x: xID, y: yID]
        let catalog = [aID, bID, xID, yID]
        func displayed(_ layout: SessionTabLayout, _ order: [TabDragPayload]) -> [TabDragPayload] {
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
            tabs.sharedManualTabGroups = snapshot.groups
            return tabs.tabStripEntries(tabs.presentedTabOrder(order, panes: panes, layout: snapshot)).flatMap(\.tabs)
        }

        var layout = SessionTabLayout(order: catalog)
        let grouped = layout.apply(.group(xID, with: [aID]), catalog: catalog)
        #expect(grouped && displayed(layout, [a, b, x, y]) == [a, x, b, y])
        let ungrouped = layout.apply(.ungroup(aID), catalog: catalog)
        #expect(ungrouped && displayed(layout, [a, x, b, y]) == [a, b, x, y])

        layout = .init(order: catalog)
        let moved = layout.apply(.move(bID, before: aID), catalog: catalog)
        #expect(moved && displayed(layout, [a, b, x, y, c]) == [b, a, c, y, x])
        let local = TabDragPayload.browser(UUID())
        #expect(displayed(layout, [a, b, c, local, x, y]) == [b, a, c, local, y, x])
    }

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

    @Test("Keyboard navigation uses displayed groups for local and shared manual grouping", arguments: [false, true])
    func navigationUsesDisplayedGroups(shared: Bool) {
        let tabs = SessionFileTabsState()
        let first = FileBrowserTab(path: "/first", sourcePaneID: "%1")
        let second = FileBrowserTab(path: "/second", sourcePaneID: "%2")
        let automatic = FileBrowserTab(path: "/automatic", sourcePaneID: "%1")
        for file in [first, second, automatic] {
            tabs.directoryTabs[file.id] = file
        }
        let x = TabDragPayload.file(first.id)
        let y = TabDragPayload.file(second.id)
        let sourceChild = TabDragPayload.file(automatic.id)
        let terminal = TabDragPayload.window("@1")
        let group = UUID()
        if shared {
            tabs.sharedManualTabGroups = [x: group, y: group]
        } else {
            tabs.manualTabGroups = [x: group, y: group]
        }
        let entries = tabs.tabStripEntries([terminal, x, sourceChild, y])
        #expect(SessionTabEntry.navigationDestination(from: x, in: entries, direction: 1) == .tab(y))
        #expect(SessionTabEntry.navigationDestination(from: y, in: entries, direction: -1) == .tab(x))
        #expect(SessionTabEntry.navigationDestination(from: y, in: entries, direction: 1) == .tab(terminal))
        #expect(SessionTabEntry.navigationDestination(from: terminal, in: entries, direction: -1) == .tab(y))
        #expect(SessionTabEntry.navigationDestination(from: sourceChild, in: entries, direction: 1) == .sourcePane("%1"))
        #expect(SessionTabEntry.navigationDestination(from: sourceChild, in: entries, direction: -1) == .sourcePane("%1"))
    }
}
