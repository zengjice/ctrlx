import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct PaneLinkedTabStripTests {
    @Test("Dissolving two members does not confuse equal retained slots with an unchanged source group")
    func dissolvedGroupsWithEqualIndex() {
        let tabs = SessionFileTabsState(), b = TabDragPayload.window("@1"), group = UUID()
        func file(_ path: String, pane: String) -> FileBrowserTab {
            FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: pane, initialDirectory: path))
        }
        let x = file("/x", pane: "%1"), y = file("/y", pane: "%2"), s = file("/s", pane: "%1"), t = file("/t", pane: "%2")
        let xp = TabDragPayload.file(x.id), yp = TabDragPayload.file(y.id), sp = TabDragPayload.file(s.id), tp = TabDragPayload.file(t.id)
        let ids: [TabDragPayload: SessionTabID] = [b: .window(UUID()), xp: .file(x.id), yp: .file(y.id), sp: .file(s.id), tp: .file(t.id)]
        tabs.tabOrder = [xp, yp, b, sp, tp]
        tabs.directoryTabs = [x.id: x, y.id: y, s.id: s, t.id: t]
        tabs.sharedOrdersTabGroups = true
        tabs.sharedManualTabGroups = [xp: group, yp: group]
        var layout = SessionTabLayout(order: tabs.tabOrder.compactMap { ids[$0] }, groups: [.file(x.id): group, .file(y.id): group], revision: 3, ordersGroups: true)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, done in
            let applied = layout.apply(edit, catalog: layout.order)
            #expect(applied)
            tabs.recordTabDrop(xp, at: .before(b))
            done()
        }
        let hover = WorkbenchTabHover(tab: xp, placement: .before(b), sourcePaneID: "%1", sharedTabID: .file(x.id))
        let line = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1", "%2"], shared: shared, sessionOrder: tabs.tabOrder)
        let accepted = shared.drop(xp, at: .before(b), order: tabs.tabOrder)
        #expect(accepted)
        let updated = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        tabs.sharedManualTabGroups = updated.groups
        let rows = tabs.tabStripEntries(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated))
        #expect(rows.map(\.tabs) == [[yp, tp], [xp, sp], [b]])
        #expect(line == .init(row: .tab(b), side: .before))
    }

    @Test("A returning member marks the new position of an existing source group")
    func returningMemberMovesExistingSourceGroup() throws {
        let tabs = SessionFileTabsState(), a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let s = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/s")), x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x"))
        let sp = TabDragPayload.file(s.id), xp = TabDragPayload.file(x.id), y = TabDragPayload.file(UUID()), z = TabDragPayload.file(UUID()), group = UUID()
        let ids: [TabDragPayload: SessionTabID] = [a: .window(UUID()), b: .window(UUID()), c: .window(UUID()), sp: .file(s.id), xp: .file(x.id), y: .file(UUID()), z: .file(UUID())]
        tabs.tabOrder = [a, b, c, sp, xp, y, z]
        tabs.directoryTabs = [s.id: s, x.id: x]
        var layout = try SessionTabLayout(order: tabs.tabOrder.compactMap { ids[$0] }, groups: [#require(ids[xp]): group, #require(ids[y]): group, #require(ids[z]): group], revision: 2, ordersGroups: true)
        tabs.sharedManualTabGroups = [xp: group, y: group, z: group]
        tabs.sharedOrdersTabGroups = true
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, done in
            let applied = layout.apply(edit, catalog: layout.order)
            #expect(applied)
            tabs.recordTabDrop(xp, at: .before(b))
            done()
        }
        let hover = WorkbenchTabHover(tab: xp, placement: .before(b), sourcePaneID: "%1", sharedTabID: .file(x.id))
        let line = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1"], shared: shared, sessionOrder: tabs.tabOrder)
        let accepted = shared.drop(xp, at: .before(b), order: tabs.tabOrder)
        #expect(accepted)
        let updated = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        tabs.sharedManualTabGroups = updated.groups
        let rows = tabs.tabStripEntries(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated))
        #expect(rows.map(\.id) == [.tab(a), .group(.pane("%1")), .tab(b), .tab(c), .group(.manual(group))])
        #expect(line == .init(row: .tab(a), side: .after))
    }

    @Test("A restored source group uses the complete interleaved strip for its insertion line")
    func restoredSourceGroupBetweenTerminals() throws {
        let tabs = SessionFileTabsState(), a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let s = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/s")), x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/x"))
        let sp = TabDragPayload.file(s.id), xp = TabDragPayload.file(x.id), y = TabDragPayload.file(UUID()), z = TabDragPayload.file(UUID()), group = UUID()
        let ids: [TabDragPayload: SessionTabID] = [a: .window(UUID()), b: .window(UUID()), c: .window(UUID()), sp: .file(s.id), xp: .file(x.id), y: .file(UUID()), z: .file(UUID())]
        tabs.tabOrder = [a, sp, b, c, xp, y, z]
        tabs.directoryTabs = [s.id: s, x.id: x]
        var layout = try SessionTabLayout(order: tabs.tabOrder.compactMap { ids[$0] }, groups: [#require(ids[xp]): group, #require(ids[y]): group, #require(ids[z]): group], revision: 2, ordersGroups: true)
        tabs.sharedManualTabGroups = [xp: group, y: group, z: group]
        tabs.sharedOrdersTabGroups = true
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, done in
            let applied = layout.apply(edit, catalog: layout.order)
            #expect(applied)
            tabs.recordTabDrop(xp, at: .before(c))
            done()
        }
        let hover = WorkbenchTabHover(tab: xp, placement: .before(c), sourcePaneID: "%2", sharedTabID: .file(x.id))
        let line = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1", "%2"], shared: shared, sessionOrder: tabs.tabOrder)
        let accepted = shared.drop(xp, at: .before(c), order: tabs.tabOrder)
        #expect(accepted)
        let updated = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        tabs.sharedManualTabGroups = updated.groups
        let rows = tabs.tabStripEntries(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated))
        #expect(rows.map(\.id) == [.tab(a), .group(.pane("%1")), .tab(b), .group(.pane("%2")), .tab(c), .group(.manual(group))])
        #expect(line == .init(row: .tab(b), side: .after))
    }

    @Test("Group ordering moves automatic groups before standalone tabs and previews the same slot")
    func movesAutomaticGroup() throws {
        let tabs = SessionFileTabsState()
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let file = FileBrowserTab(path: "/file", sourcePaneID: "%1")
        let x = TabDragPayload.file(file.id)
        tabs.directoryTabs[file.id] = file
        let order = [a, b, x]
        let hover = WorkbenchTabHover(tab: x, placement: .before(a), sourcePaneID: "%1", group: [x])
        #expect(TabStripInsertion.resolve(hover, order: order, tabs: tabs, paneOrder: ["%1"]) == .init(row: .tab(a), side: .before))
        let entries = try #require(SessionTabEntry.movingGroup([x], before: a, in: tabs.tabStripEntries(order)))
        tabs.ordersTabGroups = true
        #expect(tabs.tabStripEntries(entries.flatMap(\.tabs)).map(\.id) == [.group(.pane("%1")), .tab(a), .tab(b)])
        let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, tabOrder: entries.flatMap(\.tabs)) { id in id == "@1" ? 1 : 2 }
        #expect(saved.ordersTabGroups == true)
    }

    @Test("Group drags preserve membership and cannot move between native workspaces")
    func groupDragScope() {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let context = WorkbenchTabContext(workspaceID: nil, hostID: "host", sessionName: "work", onRejected: { }, receive: { _, _, _ in false })
        var drag = context.drag(a)
        drag.group = [a, b]
        #expect(context.hover(drag, at: .end([a, b, .git]))?.group == [a, b])
        #expect(context.hover(drag, at: .group([.git])) == nil)
        #expect(context.hover(drag, at: .before(.git, within: [.git])) == nil)
        let other = WorkbenchTabContext(workspaceID: UUID(), hostID: "host", sessionName: "work", onRejected: { }, receive: { _, _, _ in false })
        #expect(other.hover(drag, at: .end([.git])) == nil)
    }

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
            let displayedOrder = tabs.presentedTabOrder(order, panes: panes, layout: snapshot)
            tabs.sharedManualTabGroups = snapshot.groups
            return tabs.tabStripEntries(displayedOrder).flatMap(\.tabs)
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

    @Test("Leaving a manual group previews the file's restored automatic position")
    func restoredPaneDropPreview() {
        let tabs = SessionFileTabsState()
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let source = TabDragPayload.file(file.id)
        tabs.directoryTabs[file.id] = file
        let group = UUID()
        tabs.manualTabGroups = [source: group, c: group]
        tabs.tabOrder = [a, b, source, c]
        let hover = WorkbenchTabHover(tab: source, placement: .before(b), sourcePaneID: "%1")
        let marker = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1", "%2", "%3"])
        #expect(marker == TabStripInsertion(row: .group(.manual(group)), side: .after))
        #expect(tabs.manualTabGroups == [source: group, c: group])

        tabs.recordTabDrop(source, at: hover.placement)
        #expect(tabs.tabStripEntries(tabs.tabOrder).map(\.id) == [.tab(a), .tab(b), .tab(c), .group(.pane("%1"))])
    }

    @Test("A cross-split drop next to a group member previews the group's new position")
    func retainedManualGroupDropPreview() {
        let tabs = SessionFileTabsState()
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let source = TabDragPayload.file(file.id), terminal = TabDragPayload.window("@2")
        let right: [TabDragPayload] = [.git, terminal]
        let group = UUID()
        tabs.directoryTabs[file.id] = file
        tabs.tabOrder = [source] + right
        tabs.manualTabGroups = [source: group, .git: group]

        let hover = WorkbenchTabHover(tab: source, placement: .before(.git), sourcePaneID: "%1")
        #expect(TabStripInsertion.resolve(hover, order: right, tabs: tabs, paneOrder: ["%1"]) == .init(row: .tab(.git), side: .before))

        tabs.recordTabDrop(source, at: hover.placement)
        let entries = tabs.tabStripEntries(tabs.tabOrder)
        #expect(entries.map(\.id) == [.group(.manual(group)), .tab(terminal)])
        #expect(entries.first?.tabs == [source, .git])
    }

    @Test("A trailing drop skips the last group member when it returns to its source pane", arguments: [false, true], [false, true])
    func trailingDropPreviewsDissolvingGroup(isShared: Bool, hasLeadingTab: Bool) {
        let tabs = SessionFileTabsState()
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let x = TabDragPayload.file(file.id)
        let group = UUID()
        let aID = SessionTabID.window(UUID()), xID = SessionTabID.file(file.id)
        let ids = [a: aID, x: xID]
        let catalog = [xID, aID]
        var layout = SessionTabLayout(order: catalog, groups: [xID: group, aID: group], revision: 1)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, confirm in
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            tabs.sharedManualTabGroups = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout).groups
            confirm()
        }
        if isShared {
            tabs.sharedManualTabGroups = shared.snapshot.groups
        } else {
            tabs.manualTabGroups = [a: group, x: group]
        }
        tabs.directoryTabs[file.id] = file
        let leading: [TabDragPayload] = hasLeadingTab ? [b] : []
        tabs.tabOrder = leading + [x, a]

        let placement = WorkbenchTabDropPlacement.end(tabs.tabStripEntries(tabs.tabOrder).flatMap(\.tabs))
        let hover = WorkbenchTabHover(tab: a, placement: placement, sourcePaneID: nil)
        let marker = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1"], shared: isShared ? shared : nil)
        #expect(marker == (hasLeadingTab ? .init(row: .tab(b), side: .after) : .init(row: .group(.manual(group)), side: .before)))

        if isShared {
            #expect(shared.drop(a, at: placement, order: tabs.tabOrder) { tabs.recordTabDrop(a, at: placement) })
        } else {
            tabs.recordTabDrop(a, at: placement)
        }
        let displayed = tabs.tabStripEntries(tabs.tabOrder)
        #expect(displayed.map(\.id) == leading.map { .tab($0) } + [.tab(a), .group(.pane("%1"))])
    }

    @Test("Restored pane groups preview their position after the surviving top-level tabs", arguments: [false, true], [false, true])
    func restoredPaneInsertionStaysAfterTerminals(isShared: Bool, groupBeforeTerminal: Bool) {
        let tabs = SessionFileTabsState()
        let first = FileBrowserTab(path: "/first", sourcePaneID: "%1")
        let second = FileBrowserTab(path: "/second", sourcePaneID: "%2")
        let x = TabDragPayload.file(first.id), y = TabDragPayload.file(second.id), b = TabDragPayload.window("@2")
        tabs.directoryTabs = [first.id: first, second.id: second]
        tabs.tabOrder = groupBeforeTerminal ? [x, y, b] : [b, x, y]

        let group = UUID()
        let xID = SessionTabID.file(first.id), yID = SessionTabID.file(second.id), bID = SessionTabID.window(UUID())
        let ids = [x: xID, y: yID, b: bID]
        let catalog = tabs.tabOrder.compactMap { ids[$0] }
        var layout = SessionTabLayout(order: catalog, groups: [xID: group, yID: group], revision: 1)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, confirm in
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            tabs.sharedManualTabGroups = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout).groups
            confirm()
        }
        if isShared {
            tabs.sharedManualTabGroups = shared.snapshot.groups
        } else {
            tabs.manualTabGroups = [x: group, y: group]
        }

        let placement = WorkbenchTabDropPlacement.end(tabs.tabStripEntries(tabs.tabOrder).flatMap(\.tabs))
        let hover = WorkbenchTabHover(tab: x, placement: placement, sourcePaneID: "%1")
        let marker = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: ["%1", "%2"], shared: isShared ? shared : nil)
        let expected = groupBeforeTerminal ? TabStripInsertion(row: .tab(b), side: .after) : .init(row: .group(.manual(group)), side: .before)
        #expect(marker == expected)

        if isShared {
            #expect(shared.drop(x, at: placement, order: tabs.tabOrder) { tabs.recordTabDrop(x, at: placement) })
        } else {
            tabs.recordTabDrop(x, at: placement)
        }
        let panes = (1...2).map { index in
            PaneState(paneId: "%\(index)", sessionName: "work", windowIndex: 2, tmuxWindowId: "@2", paneIndex: index - 1)
        }
        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: panes, layout: isShared ? .init(ids: ids, layout: layout) : nil)
        #expect(tabs.tabStripEntries(displayed).map(\.id) == [.tab(b), .group(.pane("%1")), .group(.pane("%2"))])
    }

    @Test("A dissolving manual group uses a surviving pane group as its preview anchor", arguments: [false, true], [false, true])
    func paneInsertionPrefersSurvivingGroup(isShared: Bool, anchorPrecedesSource: Bool) {
        let tabs = SessionFileTabsState()
        let anchorPane = anchorPrecedesSource ? "%1" : "%3"
        let sourcePane = anchorPrecedesSource ? "%3" : "%1"
        let anchor = FileBrowserTab(path: "/anchor", sourcePaneID: anchorPane)
        let peer = FileBrowserTab(path: "/peer", sourcePaneID: "%2")
        let source = FileBrowserTab(path: "/source", sourcePaneID: sourcePane)
        let a = TabDragPayload.file(anchor.id), b = TabDragPayload.file(peer.id), c = TabDragPayload.file(source.id)
        tabs.directoryTabs = [anchor.id: anchor, peer.id: peer, source.id: source]
        tabs.tabOrder = [b, c, a]

        let group = UUID()
        let aID = SessionTabID.file(anchor.id), bID = SessionTabID.file(peer.id), cID = SessionTabID.file(source.id)
        let ids = [a: aID, b: bID, c: cID]
        let catalog = [bID, cID, aID]
        var layout = SessionTabLayout(order: catalog, groups: [bID: group, cID: group], revision: 1)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, confirm in
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            tabs.sharedManualTabGroups = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout).groups
            confirm()
        }
        if isShared {
            tabs.sharedManualTabGroups = shared.snapshot.groups
        } else {
            tabs.manualTabGroups = [b: group, c: group]
        }

        let paneOrder = ["%1", "%2", "%3"]
        let placement = WorkbenchTabDropPlacement.end([b, c])
        let hover = WorkbenchTabHover(tab: c, placement: placement, sourcePaneID: sourcePane)
        let marker = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: paneOrder, shared: isShared ? shared : nil)
        #expect(marker == .init(row: .group(.pane(anchorPane)), side: anchorPrecedesSource ? .after : .before))

        if isShared {
            #expect(shared.drop(c, at: placement, order: tabs.tabOrder) { tabs.recordTabDrop(c, at: placement) })
        } else {
            tabs.recordTabDrop(c, at: placement)
        }
        let panes = paneOrder.enumerated().map { index, id in
            PaneState(paneId: id, sessionName: "work", windowIndex: 1, tmuxWindowId: "@1", paneIndex: index)
        }
        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: panes, layout: isShared ? .init(ids: ids, layout: layout) : nil)
        #expect(tabs.tabStripEntries(displayed).map(\.id) == paneOrder.map { .group(.pane($0)) })
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
