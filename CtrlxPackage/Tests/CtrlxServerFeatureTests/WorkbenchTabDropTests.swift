import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite
@MainActor
struct WorkbenchTabDropTests {
    @Test("Both edges next to private Files resolve to the following shared row", arguments: [false, true])
    func privateBoundaryUsesNextSharedRow(afterEdge: Bool) {
        let tabs = SessionFileTabsState(), group = UUID()
        let w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
        let privateFile = FileBrowserTab(path: "/private"), p = TabDragPayload.file(privateFile.id)
        let x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x")), yID = SessionTabID.file(UUID())
        let xp = TabDragPayload.file(x.id), xID = SessionTabID.file(x.id), r = TabDragPayload.file(UUID()), n = TabDragPayload.file(UUID())
        let rID = SessionTabID.file(UUID()), nID = SessionTabID.file(UUID()), hidden = SessionTabID.file(UUID())
        let catalog = [wID, rID, hidden, nID, xID, yID], panes = [xID: "%1", yID: "%1"]
        let ids = [w: wID, r: rID, n: nID, xp: xID]
        var layout = SessionTabLayout(order: catalog, groups: [hidden: group, nID: group], revision: 3, ordersGroups: true)
        tabs.tabOrder = [w, p, r, n, xp]
        tabs.directoryTabs = [privateFile.id: privateFile, x.id: x]
        tabs.sharedOrdersTabGroups = true
        let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: panes)
        tabs.sharedManualTabGroups = snapshot.groups
        let before = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: snapshot)
        var sent = false
        let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, _, _, _, done in
            sent = true
            #expect(edit == .moveGroup([xID, yID], before: rID, sourcePaneID: "%1"))
            let applied = layout.apply(edit, catalog: catalog, sourcePanes: panes)
            #expect(applied)
            done()
        }
        let accepted = tabs.moveGroup([xp], at: afterEdge ? .after(w) : .before(p), visible: before, sessionOrder: before, shared: shared)
        #expect(accepted && sent)
        let updated = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: panes)
        #expect(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated) == [w, xp, p, r, n])
        #expect(layout.order == [wID, xID, yID, rID, hidden, nID])
    }

    @Test("A private tail boundary cannot resolve into the other split")
    func privateTailRetainsSectionAnchor() {
        let tabs = SessionFileTabsState(), group = UUID(), a = TabDragPayload.window("@1"), z = TabDragPayload.browser(UUID())
        let file = FileBrowserTab(path: "/private"), p = TabDragPayload.file(file.id), x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID())
        let aID = SessionTabID.window(UUID()), zID = SessionTabID.browser(UUID()), hidden = SessionTabID.browser(UUID()), xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
        let ids = [a: aID, z: zID, x: xID, y: yID]
        let layout = SessionTabLayout(order: [xID, yID, aID, hidden, zID], groups: [xID: group, yID: group], revision: 3, ordersGroups: true)
        tabs.tabOrder = [x, y, a, p, z]
        tabs.directoryTabs[file.id] = file
        tabs.sharedManualTabGroups = [x: group, y: group]
        tabs.sharedOrdersTabGroups = true
        var sent = false
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, _ in
            sent = true
            #expect(edit == .moveGroup([xID, yID], before: hidden, groupID: group))
        }
        let accepted = tabs.moveGroup([x, y], at: .before(p), visible: [x, y, a, p], sessionOrder: tabs.tabOrder, shared: shared)
        #expect(accepted && sent)
    }

    @Test("A section-end group move does not skip a detached row before the next visible section", arguments: [false, true])
    func groupEndKeepsIntermediateDetachedAnchor(afterEdge: Bool) {
        let a = TabDragPayload.window("@1"), z = TabDragPayload.browser(UUID())
        let x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID()), group = UUID()
        let aID = SessionTabID.window(UUID()), zID = SessionTabID.browser(UUID()), hidden = SessionTabID.browser(UUID())
        let xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
        let ids = [a: aID, z: zID, x: xID, y: yID]
        let layout = SessionTabLayout(order: [xID, yID, aID, hidden, zID], groups: [xID: group, yID: group], revision: 3, ordersGroups: true)
        var sent = false
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, _ in
            sent = true
            #expect(edit == .moveGroup([xID, yID], before: hidden, groupID: group))
        }
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [x, y, a, z]
        tabs.sharedManualTabGroups = [x: group, y: group]
        tabs.sharedOrdersTabGroups = true
        let left = [x, y, a]
        let accepted = tabs.moveGroup([x, y], at: afterEdge ? .after(a) : .end(left), visible: left, sessionOrder: tabs.tabOrder, shared: shared)
        #expect(accepted && sent)
    }

    @Test("Both edges of a visible slot take priority over a detached manual-group member", arguments: [false, true])
    func groupMoveRespectsVisibleBoundary(afterEdge: Bool) {
        let tabs = SessionFileTabsState(), group = UUID()
        let x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x")), y = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/y"))
        let w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
        let r = TabDragPayload.file(UUID()), n = TabDragPayload.file(UUID()), xp = TabDragPayload.file(x.id)
        let rID = SessionTabID.file(UUID()), mID = SessionTabID.file(UUID()), nID = SessionTabID.file(UUID()), xID = SessionTabID.file(x.id), yID = SessionTabID.file(y.id)
        let catalog = [wID, rID, mID, nID, xID, yID], panes = [xID: "%1", yID: "%1"]
        let ids = [w: wID, r: rID, n: nID, xp: xID]
        var layout = SessionTabLayout(order: catalog, groups: [mID: group, nID: group], revision: 3, ordersGroups: true)
        tabs.tabOrder = [w, r, n, xp]
        tabs.directoryTabs = [x.id: x]
        tabs.sharedOrdersTabGroups = true
        let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: panes)
        tabs.sharedManualTabGroups = snapshot.groups
        let before = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: snapshot)
        var sent = false
        let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, _, _, _, done in
            sent = true
            #expect(edit == .moveGroup([xID, yID], before: rID, sourcePaneID: "%1"))
            let applied = layout.apply(edit, catalog: catalog, sourcePanes: panes)
            #expect(applied)
            done()
        }
        let accepted = tabs.moveGroup([xp], at: afterEdge ? .after(w) : .before(r), visible: before, sessionOrder: before, shared: shared)
        #expect(accepted && sent)
        #expect(layout.order == [wID, xID, yID, rID, mID, nID])
        let rows = SessionTabEntry.grouped(layout.order, preserveGroupPositions: true) { tab in
            layout.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
        }
        #expect(rows.map(\.tabs) == [[wID], [xID, yID], [rID], [mID, nID]])
    }

    @Test("A Host broadcast cannot cancel a group's private anchor", arguments: [false, true])
    func passiveRefreshBeforeGroupConfirmation(broadcastFirst: Bool) throws {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID()), p = TabDragPayload.file(UUID()), group = UUID()
        let ids: [TabDragPayload: SessionTabID] = [a: .window(UUID()), b: .window(UUID()), x: .file(UUID()), y: .file(UUID())]
        let catalog = [a, b, x, y].compactMap { ids[$0] }
        var layout = try SessionTabLayout(order: catalog, groups: [#require(ids[x]): group, #require(ids[y]): group], revision: 2, ordersGroups: true)
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [a, p, b, x, y]
        tabs.sharedManualTabGroups = [x: group, y: group]
        tabs.sharedOrdersTabGroups = true
        var confirm: (@MainActor () -> Void)?
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, done in
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            confirm = done
        }
        let accepted = tabs.moveGroup([x, y], at: .before(p), visible: tabs.tabOrder, sessionOrder: tabs.tabOrder, shared: shared)
        #expect(accepted)
        let updated = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        if broadcastFirst {
            tabs.recordVisibleTabOrder(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated))
        }
        confirm?()
        #expect(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: updated) == [a, x, y, p, b])
    }

    @Test("Automatic groups include members in another split or native window", arguments: [false, true])
    func completeAutomaticGroup(hidden: Bool) {
        let tabs = SessionFileTabsState(), a = TabDragPayload.window("@1")
        let x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x")), y = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/y"))
        let xp = TabDragPayload.file(x.id), yp = TabDragPayload.file(y.id), aID = SessionTabID.window(UUID()), xID = SessionTabID.file(x.id), yID = SessionTabID.file(y.id)
        let ids: [TabDragPayload: SessionTabID] = hidden ? [a: aID, xp: xID] : [a: aID, xp: xID, yp: yID]
        let panes = [xID: "%1", yID: "%1"]
        var layout = SessionTabLayout(order: [aID, xID, yID], revision: 2, ordersGroups: true)
        tabs.directoryTabs = hidden ? [x.id: x] : [x.id: x, y.id: y]
        tabs.tabOrder = hidden ? [a, xp] : [a, xp, yp]
        tabs.rightSide = hidden ? [] : [yp]
        tabs.sharedOrdersTabGroups = true
        var sends = 0
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout, sourcePanes: panes)) { edit, _, _, _, done in
            sends += 1
            #expect(edit == .moveGroup([xID, yID], before: aID, sourcePaneID: "%1"))
            let applied = layout.apply(edit, catalog: layout.order, sourcePanes: panes)
            #expect(applied)
            done()
        }
        let accepted = tabs.moveGroup([xp], at: .before(a), visible: [a, xp], sessionOrder: tabs.tabOrder, shared: shared)
        #expect(accepted && sends == 1 && layout.order == [xID, yID, aID])
        #expect(tabs.rightSide == (hidden ? [] : [yp]))
        #expect((tabs.directoryTabs[y.id] == nil) == hidden)
    }

    @Test("A local group containing a terminal cannot submit a Host reorder", arguments: [false, true])
    func localGroupDoesNotReorderHost(ordersGroups: Bool) {
        let tabs = SessionFileTabsState(), a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let file = FileBrowserTab(path: "/private"), p = TabDragPayload.file(file.id)
        tabs.directoryTabs[file.id] = file
        tabs.tabOrder = [a, b, p]
        let merged = tabs.mergeTab(p, into: [b], visible: tabs.tabOrder)
        #expect(merged)
        tabs.recordTabDrop(p, at: .group([b]))
        let ids: [TabDragPayload: SessionTabID] = [a: .window(UUID()), b: .window(UUID())]
        let layout = SessionTabLayout(order: [a, b].compactMap { ids[$0] }, revision: 2, ordersGroups: ordersGroups ? true : nil)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { _, _, _, _, _ in Issue.record("Sent a local group to the Host") }
        let accepted = tabs.moveGroup([b, p], at: .before(a), visible: tabs.tabOrder, sessionOrder: tabs.tabOrder, shared: shared)
        #expect(accepted)
        #expect(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: shared.snapshot) == [b, p, a])
        #expect(!tabs.isWindowReorderPending)
        #expect(shared.snapshot.layout == layout)
    }

    @Test("A target source group spanning native windows is one insertion slot", arguments: [false, true], [false, true])
    func targetSourceGroupAcrossWindows(hiddenFirst: Bool, moveAfter: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID()
            let m = TabDragPayload.file(UUID()), n = TabDragPayload.file(UUID()), x = TabDragPayload.file(UUID())
            let mID = SessionTabID.file(UUID()), nID = SessionTabID.file(UUID()), xID = SessionTabID.file(UUID()), hidden = SessionTabID.file(UUID())
            let ids = [m: mID, n: nID, x: xID], panes = [xID: "%1", hidden: "%1"]
            let target = hiddenFirst ? [hidden, xID] : [xID, hidden]
            let catalog = moveAfter ? [mID, nID] + target : target + [mID, nID]
            let layout = SessionTabLayout(order: catalog, groups: [mID: group, nID: group], revision: 3, ordersGroups: true)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout, sourcePanes: panes)) { edit, initial, visible, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: visible, initialOrderRevision: layout.revision)
            }
            let accepted = shared.moveGroup([m, n], order: moveAfter ? [x, m, n] : [m, n, x], initialOrder: moveAfter ? [m, n, x] : [x, m, n], onSuccess: { })
            #expect(accepted)
            let store = HostSessionTabLayouts()
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order == (moveAfter ? target + [mID, nID] : [mID, nID] + target))
        }
    }

    @Test("The first group move preserves detached rows in their displayed order without an initial write")
    func unseededGroupRetainsHiddenAnchor() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), tabs = SessionFileTabsState(), a = TabDragPayload.window("@1")
            let x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x")), z = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/z"))
            let xp = TabDragPayload.file(x.id), zp = TabDragPayload.file(z.id), aID = SessionTabID.window(UUID()), xID = SessionTabID.file(x.id), zID = SessionTabID.file(z.id), hidden = SessionTabID.browser(UUID())
            let ids = [a: aID, xp: xID, zp: zID], panes = [xID: "%1", zID: "%2"], catalog = [aID, xID, zID, hidden]
            let store = HostSessionTabLayouts(), snapshot = store.snapshot(sessionID: session, catalog: catalog)
            #expect(snapshot.revision == 0 && snapshot.order == catalog)
            @Dependency(PreferencesService.self) var preferences
            #expect(preferences.data("sessionTabLayouts") == nil)
            tabs.directoryTabs = [x.id: x, z.id: z]
            tabs.tabOrder = [a, xp, zp]
            let hiddenTab = TabDragPayload.browser(UUID())
            var allIDs = ids
            allIDs[hiddenTab] = hidden
            let allBefore = tabs.presentedTabOrder([a, xp, zp, hiddenTab], panes: [], layout: .init(ids: allIDs, layout: snapshot, sourcePanes: panes))
            #expect(allBefore == [a, hiddenTab, xp, zp])
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: snapshot, sourcePanes: panes)) { edit, initial, visible, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: visible, initialOrderRevision: snapshot.revision)
            }
            let accepted = tabs.moveGroup([xp], at: .end(tabs.tabOrder), visible: tabs.tabOrder, sessionOrder: tabs.tabOrder, shared: shared)
            #expect(accepted)
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes) { _ in nil }
            #expect(HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog).order == [aID, hidden, zID, xID])
        }
    }

    @Test("Group moves keep a trailing detached tab as their shared anchor", arguments: [false, true])
    func groupEndKeepsDetachedAnchor(initialized: Bool) {
        let a = TabDragPayload.window("@1"), x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID())
        let aID = SessionTabID.window(UUID()), hidden = SessionTabID.browser(UUID()), xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID()), group = UUID()
        let ids = [a: aID, x: xID, y: yID], catalog = [xID, yID, aID, hidden]
        var layout = SessionTabLayout(order: catalog, groups: [xID: group, yID: group], revision: 2, ordersGroups: initialized ? true : nil)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, initial, _, _, done in
            #expect(edit == .moveGroup([xID, yID], before: hidden, groupID: group))
            if let initial {
                layout = layout.initializingGroupOrder(from: initial)
            }
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            done()
        }
        let accepted = shared.moveGroup([x, y], order: [a, x, y], initialOrder: [x, y, a], onSuccess: { })
        #expect(accepted && layout.order == [aID, xID, yID, hidden])
    }

    @Test("A split group submits its complete shared membership while a local group stays local", arguments: [false, true])
    func partialAndLocalGroups(local: Bool) {
        let a = TabDragPayload.window("@1"), x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID()), z = TabDragPayload.file(UUID()), group = UUID()
        let aID = SessionTabID.window(UUID()), xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID()), zID = SessionTabID.file(UUID())
        let ids = [a: aID, x: xID, y: yID, z: zID]
        var layout = SessionTabLayout(order: [xID, yID, zID, aID], groups: [xID: group, yID: group, zID: group], revision: 2, ordersGroups: true)
        var sent = false
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, done in
            sent = true
            #expect(edit == .moveGroup([xID, yID, zID], before: nil, groupID: group))
            let applied = layout.apply(edit, catalog: layout.order)
            #expect(applied)
            done()
        }
        let tabs = SessionFileTabsState()
        tabs.sharedManualTabGroups = ids.compactMapValues { layout.groups[$0] }
        tabs.sharedOrdersTabGroups = true
        tabs.tabOrder = local ? [a, .git, x, y, z] : [x, y, z, a]
        if local {
            tabs.manualTabGroups = [.git: UUID()]
            tabs.manualTabGroups[x] = tabs.manualTabGroups[.git]
        }
        let members: [TabDragPayload] = local ? [.git, x] : [x, y]
        let before = tabs.tabOrder
        let proposed: [TabDragPayload] = local ? [.git, x, a, y, z] : [a, x, z, y]
        let accepted = shared.moveGroup(members, order: proposed, initialOrder: before, localGroups: tabs.manualTabGroups, onSuccess: { })
        #expect(accepted == !local && sent == !local)
        if local {
            tabs.ordersTabGroups = true
            tabs.recordVisibleTabOrder(proposed)
            #expect(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: shared.snapshot).prefix(2) == [.git, x])
        } else {
            #expect(layout.order == [aID, xID, yID, zID])
        }
    }

    @Test("A group confirmation cannot overwrite a later private reorder", arguments: [false, true])
    func groupConfirmationPreservesLaterOrder(laterEdit: Bool) {
        let tabs = SessionFileTabsState(), a = TabDragPayload.window("@1"), x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID()), p = TabDragPayload.browser(UUID())
        let before: [TabDragPayload] = [a, x, y, .git, p], proposed: [TabDragPayload] = [x, y, a, .git, p]
        tabs.tabOrder = before
        let revision = tabs.beginTabOrderEdit()
        if laterEdit {
            tabs.beginTabOrderEdit()
            tabs.recordVisibleTabOrder([.git, p, a, x, y])
        }
        tabs.recordGroupOrder(proposed, ifUnchangedSince: revision)
        #expect(tabs.tabOrder == (laterEdit ? [.git, p, a, x, y] : proposed))
    }

    @Test("Group moves resolve private anchors and mixed source members from the complete order", arguments: [false, true])
    func sharedGroupUsesFullOrder(mixedSource: Bool) {
        let tabs = SessionFileTabsState()
        let a = TabDragPayload.window("@1"), peer = TabDragPayload.browser(UUID())
        let sharedFile = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/shared"))
        let privateFile = FileBrowserTab(path: "/private", sourcePaneID: "%1")
        let x = TabDragPayload.file(sharedFile.id), y = TabDragPayload.file(UUID()), p = TabDragPayload.file(privateFile.id)
        tabs.directoryTabs[sharedFile.id] = sharedFile
        tabs.directoryTabs[privateFile.id] = privateFile
        let aID = SessionTabID.window(UUID()), peerID = SessionTabID.browser(UUID())
        let xID = SessionTabID.file(sharedFile.id), yID = SessionTabID.file(UUID()), group = UUID()
        let ids = [a: aID, peer: peerID, x: xID, y: yID]
        let catalog = mixedSource ? [aID, xID] : [xID, yID, peerID]
        let members = mixedSource ? [x, p] : [x, y]
        let proposed: [TabDragPayload] = mixedSource ? [x, p, a] : [peer, x, y, .git]
        var layout = SessionTabLayout(order: catalog, groups: mixedSource ? [:] : [xID: group, yID: group], revision: 2, ordersGroups: true)
        var sends = 0
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, confirm in
            sends += 1
            #expect(edit == .moveGroup(mixedSource ? [xID] : [xID, yID], before: mixedSource ? aID : nil, groupID: mixedSource ? nil : group, sourcePaneID: mixedSource ? "%1" : nil))
            let moved = layout.apply(edit, catalog: catalog, sourcePanes: mixedSource ? [xID: "%1"] : [:])
            #expect(moved)
            confirm()
        }
        let before: [TabDragPayload] = mixedSource ? [a, x, p] : [x, y, peer, .git]
        let accepted = shared.moveGroup(members, order: proposed, initialOrder: before, sourcePaneID: mixedSource ? "%1" : nil) {
            tabs.ordersTabGroups = true
            tabs.recordVisibleTabOrder(proposed)
        }
        #expect(accepted && sends == 1)
        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: .init(ids: ids, layout: layout))
        #expect(displayed == proposed)
        #expect(tabs.directoryTabs[privateFile.id] === privateFile && privateFile.hostTab == nil)
    }

    @Test("A section-end group drop preserves other sections in both ordering modes", arguments: [false, true], [false, true].flatMap { ordered in [false, true].map { (ordered, $0) } })
    func groupEndIsScopedToSection(alreadyLast: Bool, mode: (Bool, Bool)) async throws {
        let (alreadyOrdered, rightBeforePeer) = mode
        let a = TabDragPayload.window("@1"), right = TabDragPayload.browser(UUID())
        let x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID()), group = UUID()
        let left: [SessionTabEntry<TabDragPayload>] = alreadyLast ? [.tab(a), .group(.manual(group), [x, y])] : [.group(.manual(group), [x, y]), .tab(a)]
        let section = left.flatMap(\.tabs)
        let full = rightBeforePeer ? (alreadyLast ? [right, a, x, y] : [x, y, right, a]) : section + [right]
        let placement = WorkbenchTabDropPlacement.end(section)
        if alreadyLast {
            #expect(placement.movingGroup([x, y], in: left) == nil)
            return
        }
        let moved = try #require(placement.movingGroup([x, y], in: left)).flatMap(\.tabs)
        var replacement = moved.makeIterator()
        let proposed = full.map { section.contains($0) ? replacement.next() ?? $0 : $0 }
        let aID = SessionTabID.window(UUID()), rightID = SessionTabID.browser(UUID())
        let xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
        let ids = [a: aID, right: rightID, x: xID, y: yID]
        let catalog = full.compactMap { ids[$0] }
        let layout = SessionTabLayout(order: catalog, groups: [xID: group, yID: group], revision: 2, ordersGroups: alreadyOrdered ? true : nil)
        let session = UUID()
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, initial, visible, _, _ in
                #expect(edit == .moveGroup([xID, yID], before: rightBeforePeer ? nil : rightID, groupID: group))
                #expect(initial == (alreadyOrdered ? nil : catalog))
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: visible, initialOrderRevision: initial.map { _ in layout.revision })
            }
            let accepted = shared.moveGroup([x, y], order: proposed, initialOrder: full, onSuccess: { })
            #expect(accepted)
            let submitted = try #require(request)
            try await store.apply(submitted, catalog: catalog) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order == (rightBeforePeer ? [rightID, aID, xID, yID] : [aID, xID, yID, rightID]))
            #expect(saved.groups == layout.groups)
        }
    }

    @Test("A local group containing Git keeps its requested position after shared ordering refreshes")
    func privateGroupOrderSurvivesSharedRefresh() {
        let a = TabDragPayload.window("@1"), x = TabDragPayload.browser(UUID()), y = TabDragPayload.browser(UUID())
        let aID = SessionTabID.window(UUID()), xID = SessionTabID.browser(UUID()), yID = SessionTabID.browser(UUID())
        let tabs = SessionFileTabsState()
        let group = UUID()
        tabs.manualTabGroups = [.git: group, x: group]
        tabs.ordersTabGroups = true
        let layout = SharedWorkbenchTabLayout.Snapshot(ids: [a: aID, x: xID, y: yID], layout: .init(order: [aID, xID, yID], revision: 1, ordersGroups: true))
        let order = tabs.presentedTabOrder([x, .git, a, y], panes: [], layout: layout)
        #expect(order == [x, .git, a, y])
        #expect(tabs.tabStripEntries(order).map(\.id) == [.group(.manual(group)), .tab(a), .tab(y)])
    }

    @Test("A whole-group edit waits for Host confirmation and keeps private source members together")
    func sharedGroupMove() {
        let a = TabDragPayload.window("@1"), x = TabDragPayload.file(UUID()), p = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID())
        let aID = SessionTabID.window(UUID()), xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
        let ids = [a: aID, x: xID, y: yID]
        let catalog = [aID, xID, yID]
        var layout = SessionTabLayout(order: catalog, revision: 2)
        var confirm: (@MainActor () -> Void)?
        var completed = false
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, initial, windows, affected, completion in
            #expect(edit == .moveGroup([yID], before: aID))
            #expect(initial == [aID, xID, yID])
            #expect(windows == nil && affected.isEmpty)
            let moved = layout.apply(edit, catalog: catalog)
            #expect(moved)
            confirm = completion
        }
        let accepted = shared.moveGroup([y], order: [y, a, p, x], initialOrder: [a, p, x, y]) { completed = true }
        #expect(accepted && !completed)
        confirm?()
        #expect(completed)
        let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        let displayed = snapshot.order([a, p, x, y]) { tab in [p, x].contains(tab) ? "%1" : (tab == y ? "%2" : nil) }
        #expect(displayed == [y, a, p, x])
        #expect(layout.groups.isEmpty)
    }

    @Test("Old Hosts do not receive group edits")
    func oldHostCannotReceiveGroupMove() {
        let tab = TabDragPayload.file(UUID()), id = SessionTabID.file(UUID())
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [tab: id], layout: .init(order: [id], supportsGroupReordering: nil))) { _, _, _, _, _ in
            Issue.record("Sent a group edit to an older Host")
        }
        let accepted = shared.moveGroup([tab], order: [tab], initialOrder: [tab], onSuccess: { })
        #expect(!accepted)
    }

    @Test
    func sharedDropKeepsLaneAnchorAndSeedsFromTheVisibleOrder() {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let first = SessionTabID.window(UUID()), second = SessionTabID.window(UUID())
        var sent: SessionTabLayout.Edit?
        var baseline: [SessionTabID]?
        var confirm: (@MainActor () -> Void)?
        var applied = false
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [a: first, b: second], layout: .init(order: [first, second]))) { edit, order, visible, affected, onSuccess in
            sent = edit
            baseline = order
            confirm = onSuccess
            #expect(visible == [second, first])
            #expect(affected == [a])
        }

        #expect(shared.snapshot.order([b, a]) == [b, a])
        #expect(shared.drop(a, at: .end([b]), order: [b, a]) { applied = true })
        #expect(!applied)
        confirm?()
        #expect(applied)
        #expect(sent == .moveToEnd(first, after: second))
        #expect(baseline == [second, first])
    }

    @Test
    func sharedTabCanMoveAfterAPrivateTabWithoutMovingOtherWindows() {
        let terminal = TabDragPayload.window("@1"), local = TabDragPayload.browser(UUID())
        let id = SessionTabID.window(UUID())
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [terminal, local]
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [terminal: id], layout: .init(order: [id], revision: 1))) { _, _, _, _, _ in
            Issue.record("A private placement sent a Host edit")
        }

        let placement = WorkbenchTabDropPlacement.end([terminal, local])
        #expect(shared.drop(terminal, at: placement, order: tabs.tabOrder) { tabs.recordTabDrop(terminal, at: placement) })
        #expect(shared.snapshot.order(tabs.tabOrder) == [local, terminal])
    }

    @Test("Dropping after a private tab in a split preserves the visible move after the Host refreshes", arguments: [false, true])
    func privateTrailingAnchorUpdatesSharedOrder(hasSharedPeerOnLeft: Bool) {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID()), cID = SessionTabID.window(UUID())
        let ids = [a: aID, b: bID, c: cID]
        let tabs = SessionFileTabsState()
        tabs.tabOrder = hasSharedPeerOnLeft ? [a, b, c, .git] : [a, c, .git]
        tabs.rightSide = [c]
        let catalog = tabs.tabOrder.compactMap { ids[$0] }
        var layout = SessionTabLayout(order: catalog, revision: 1)
        var edits = 0
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, initial, windows, _, confirm in
            edits += 1
            #expect(edit == .moveToEnd(aID, after: cID, groupMembership: .leave))
            #expect(initial == nil && windows == (hasSharedPeerOnLeft ? [bID, cID, aID] : [cID, aID]))
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            confirm()
        }

        let placement = WorkbenchTabDropPlacement.end(tabs.tabOrder.filter { !tabs.rightSide.contains($0) })
        #expect(shared.drop(a, at: placement, order: tabs.tabOrder) {
            tabs.recordTabDrop(a, at: placement)
        })
        let refreshed = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout)
        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: refreshed)
        #expect(edits == 1)
        #expect(displayed.filter { !tabs.rightSide.contains($0) } == (hasSharedPeerOnLeft ? [b, .git, a] : [.git, a]))
        #expect(displayed.filter(tabs.rightSide.contains) == [c])
    }

    @Test(arguments: [false, true])
    func privateLeadingEdgeSubmitsTheSharedOrderAndGroupMembership(withinGroup: Bool) {
        let a = TabDragPayload.file(UUID()), b = TabDragPayload.file(UUID()), x = TabDragPayload.browser(UUID())
        let first = SessionTabID.file(UUID()), second = SessionTabID.file(UUID())
        let tabs = SessionFileTabsState()
        tabs.tabOrder = withinGroup ? [a, b, x] : [x, b, a]
        let group = UUID()
        let groups = [first: group, second: group]
        var layout = SessionTabLayout(order: withinGroup ? [first, second] : [second, first], groups: groups, revision: 1)
        let ids = [a: first, b: second]
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, affected, confirm in
            let expected: SessionTabLayout.Edit = withinGroup
                ? .moveToEnd(first, after: second, groupMembership: .keep)
                : .move(first, before: second, groupMembership: .leave)
            #expect(edit == expected)
            #expect(affected == (withinGroup ? [] : [a]))
            let applied = layout.apply(edit, catalog: [first, second])
            #expect(applied)
            confirm()
        }
        let placement = WorkbenchTabDropPlacement.before(x, within: withinGroup ? tabs.tabOrder : nil)
        #expect(shared.leavesGroupOnDrop(a, at: placement, order: tabs.tabOrder) == !withinGroup)
        #expect(shared.drop(a, at: placement, order: tabs.tabOrder) { tabs.recordTabDrop(a, at: placement) })
        let expectedOrder = withinGroup ? [b, a, x] : [a, x, b]
        #expect(SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout).order(tabs.tabOrder) == expectedOrder)
        #expect(layout.groups == (withinGroup ? groups : [:]))
    }

    @Test
    func expandedGroupOnlyAcceptsItsOwnMembers() {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2"), c = TabDragPayload.window("@3")
        let placement = WorkbenchTabDropPlacement.before(c, within: [a, c])
        #expect(placement.accepts(a))
        #expect(!placement.accepts(b))
    }

    @Test("The trailing edge inserts after a shared tab and retains an expanded group's membership")
    func trailingEdgeInsertsAfterTarget() {
        let a = TabDragPayload.file(UUID()), b = TabDragPayload.file(UUID()), c = TabDragPayload.file(UUID())
        let first = SessionTabID.file(UUID()), second = SessionTabID.file(UUID()), third = SessionTabID.file(UUID())
        let group = UUID()
        let ids = [a: first, b: second, c: third]
        let layout = SessionTabLayout(order: [first, second, third], groups: [first: group, second: group], revision: 1)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, affected, _ in
            #expect(edit == .moveToEnd(first, after: second, groupMembership: .keep))
            #expect(affected.isEmpty)
        }
        let placement = WorkbenchTabDropPlacement.after(b, within: [a, b])
        #expect(placement.placing(a, in: [a, b, c]) == [b, a, c])
        #expect(!placement.accepts(c))
        #expect(shared.drop(a, at: placement, order: [a, b, c]))
    }

    @Test("Leading-edge drops respect the displayed source group before sending a shared edit", arguments: [false, true])
    func sharedLeadingEdgeRespectsSourceGroup(crossWindow: Bool) {
        let sourceTabs = SessionFileTabsState()
        let targetTabs = crossWindow ? SessionFileTabsState() : sourceTabs
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let sibling = FileBrowserTab(path: "/other", sourcePaneID: "%1")
        sourceTabs.directoryTabs[file.id] = file
        targetTabs.directoryTabs[sibling.id] = sibling
        let source = TabDragPayload.file(file.id)
        let peer = TabDragPayload.file(sibling.id)
        let terminal = TabDragPayload.window("@2")
        let terminalID = SessionTabID.window(UUID())
        let order = crossWindow ? [terminal, peer] : [terminal, peer, source]
        var sent: [SessionTabLayout.Edit] = []
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [
            terminal: terminalID, peer: .file(sibling.id), source: .file(file.id),
        ], layout: .init())) { edit, _, _, _, _ in
            sent.append(edit)
        }
        let sourceWindow = UUID()
        let destinationWindow = crossWindow ? UUID() : sourceWindow
        let context = WorkbenchTabContext(
            workspaceID: destinationWindow, hostID: nil, sessionName: "work", onRejected: { },
            sourcePaneGroup: { drag in
                (drag.workspaceID == sourceWindow ? sourceTabs : targetTabs).groupID(for: drag.tab)?.paneID
            },
            receive: { drag, placement, _ in shared.drop(drag.tab, at: placement, order: order) }
        )
        let drag = WorkbenchTabDrag(workspaceID: sourceWindow, hostID: nil, sessionName: "work", tab: source)

        func drop(_ placement: WorkbenchTabDropPlacement) -> Bool {
            context.drop(drag, at: placement, rightSide: false) { destination in
                shared.drop(source, at: destination, order: order)
            }
        }

        #expect(drop(.before(terminal)))
        #expect(sent.isEmpty)
        #expect(context.resolvedPlacement(drag, at: .after(terminal)) == nil)
        #expect(drop(.after(terminal)))
        #expect(sent.isEmpty)
        #expect(drop(.before(peer, within: crossWindow ? [peer] : [source, peer])))
        #expect(sent == (crossWindow ? [] : [.move(.file(file.id), before: .file(sibling.id), groupMembership: .keep)]))
        sent.removeAll()

        #expect(drop(.group([terminal])))
        let manualGroup = UUID()
        sourceTabs.sharedManualTabGroups[source] = manualGroup
        targetTabs.sharedManualTabGroups[peer] = manualGroup
        #expect(drop(.before(terminal)))
        #expect(sent == [
            .group(.file(file.id), with: [terminalID]),
            .move(.file(file.id), before: terminalID, groupMembership: .leave),
        ])
    }

    @Test("Trailing drops use same-level anchors in the destination section", arguments: [false, true])
    func trailingDropSkipsAutomaticGroups(crossWindow: Bool) throws {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let file = FileBrowserTab(path: "/project", sourcePaneID: "%1")
        let outside = TabDragPayload.window("@3"), child = TabDragPayload.file(file.id)
        let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID())
        let outsideID = SessionTabID.window(UUID()), childID = SessionTabID.file(UUID())
        let order = crossWindow ? [b, child] : [a, b, outside, child]
        let catalog = [aID, bID, outsideID, childID]
        var layout = SessionTabLayout(order: catalog)
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [
            a: aID, b: bID, outside: outsideID, child: childID,
        ], layout: layout)) { edit, _, windows, _, _ in
            #expect(edit == .moveToEnd(aID, after: bID))
            #expect(windows == (crossWindow ? [bID, aID] : [bID, aID, outsideID]))
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
        }
        func apply(_ destination: WorkbenchTabDropPlacement) -> Bool {
            #expect(destination.placing(a, in: order) == (crossWindow ? [b, a, child] : [b, a, outside, child]))
            return shared.drop(a, at: destination, order: order)
        }

        let workspace = UUID()
        let context = WorkbenchTabContext(
            workspaceID: workspace, hostID: nil, sessionName: "work", onRejected: { },
            sourcePaneGroup: { $0.tab == child ? "%1" : nil },
            receive: { _, destination, _ in apply(destination) }
        )
        let drag = WorkbenchTabDrag(workspaceID: crossWindow ? UUID() : workspace, hostID: nil, sessionName: "work", tab: a)
        let placement = try #require(context.resolvedPlacement(drag, at: .end([b, child])))
        let hover = WorkbenchTabHover(tab: a, placement: placement, sourcePaneID: nil)
        let tabs = SessionFileTabsState()
        tabs.directoryTabs[file.id] = file
        let section = crossWindow ? [b, child] : [a, b, child]
        #expect(TabStripInsertion.resolve(hover, order: section, tabs: tabs, paneOrder: ["%1"]) == .init(row: .tab(b), side: .after))
        #expect(context.drop(drag, at: .end([b, child]), rightSide: false, reorder: apply))
        #expect(layout.order == [bID, aID, outsideID, childID])
    }

    @Test("Only transferable tabs receive cross-window insertion feedback")
    func detachedWindowHoverChecksTransfer() throws {
        let manager = DetachedTerminalWindows()
        let terminal = TabDragPayload.window("@2")
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        manager.reserve(target)
        let workspace = try #require(manager.workspace(containing: target))
        let context = WorkbenchTabContext(
            workspaceID: workspace.id, hostID: nil, sessionName: "work", onRejected: { },
            canTransfer: { manager.canTransfer($0, to: workspace.id, session: { _ in "work" }) },
            receive: { _, _, _ in
                Issue.record("An incompatible tab reached transfer")
                return false
            }
        )
        let placement = WorkbenchTabDropPlacement.before(terminal)
        let git = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .git)
        #expect(context.resolvedPlacement(git, at: placement) == nil)
        #expect(context.drop(git, at: placement, rightSide: false) { _ in
            Issue.record("A cross-window drag reached local reordering")
            return false
        })
        #expect(context.resolvedPlacement(context.drag(.git), at: placement) == placement)

        let transferable = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(context.resolvedPlacement(transferable, at: placement) == placement)
    }

    @Test("A section with no same-level anchor keeps the shared rank")
    func trailingDropWithoutAnchorKeepsRank() {
        let a = TabDragPayload.window("@1"), child = TabDragPayload.file(UUID())
        let aID = SessionTabID.window(UUID()), childID = SessionTabID.file(UUID())
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: [a: aID, child: childID], layout: .init(order: [aID, childID]))) { _, _, _, _, _ in
            Issue.record("An empty section sent a shared reorder")
        }
        let destination = WorkbenchTabDropPlacement.end([])
        #expect(destination.placing(a, in: [a, child]) == [a, child])
        var moved = false
        #expect(shared.drop(a, at: destination, order: [a, child]) { moved = true })
        #expect(moved)
    }

    @Test
    func movingBeforeAnOutsideTabDissolvesTheOldLocalGroup() {
        let a = TabDragPayload.window("@1"), b = TabDragPayload.browser(UUID()), c = TabDragPayload.browser(UUID())
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [a, b, c]
        #expect(tabs.mergeTab(a, into: [b], visible: tabs.tabOrder))
        tabs.recordTabDrop(b, at: .before(a, within: [a, b]))
        #expect(tabs.manualTabGroups.count == 2)
        tabs.recordTabDrop(b, at: .before(c))
        #expect(tabs.manualTabGroups.isEmpty)
        #expect(tabs.tabOrder == [a, b, c])
    }

    @Test
    func closingPrivateMemberRevealsTheSharedGroup() {
        let terminal = TabDragPayload.window("@1"), other = TabDragPayload.window("@2")
        let local = TabDragPayload.browser(UUID())
        let tabs = SessionFileTabsState()
        #expect(tabs.mergeTab(terminal, into: [local], visible: [local, terminal, other]))
        let sharedGroup = UUID()
        tabs.sharedManualTabGroups = [terminal: sharedGroup, other: sharedGroup]

        tabs.reconcileLocalTabGroups(visible: [terminal, other])

        #expect(tabs.manualTabGroups.isEmpty)
        #expect(tabs.tabStripEntries([terminal, other]).map(\.id) == [.group(.manual(sharedGroup))])
    }

    @Test(arguments: ["session", "host", "both"], [TabDragPayload.window("@1"), .file(UUID()), .browser(UUID())])
    func incompatibleDropIsConsumedWithoutMovingOrReordering(scope: String, tab: TabDragPayload) {
        var rejected = 0
        var transfers = 0
        var reorders = 0
        let destination = WorkbenchTabContext(
            workspaceID: UUID(), hostID: "host-a", sessionName: "work",
            onRejected: { rejected += 1 },
            receive: { _, _, _ in transfers += 1
                return true
            }
        )
        let drag = WorkbenchTabDrag(
            workspaceID: UUID(), hostID: scope == "session" ? "host-a" : "host-b",
            sessionName: scope == "host" ? "work" : "other", tab: tab
        )

        #expect(destination.drop(drag, at: .end([]), rightSide: false) { _ in
            reorders += 1
            return true
        })
        #expect(rejected == 1)
        #expect(transfers == 0 && reorders == 0)
    }

    @Test(arguments: [nil, "viewer-host"] as [String?])
    func rejectedSessionMergePreservesBothWorkspaces(hostID: String?) throws {
        let manager = DetachedTerminalWindows()
        let first = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@1"))
        let second = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@2"))
        let session: (DetachedTerminalTarget) -> String? = { $0 == first ? "one" : "two" }
        let source = try #require(manager.detach(first, position: nil, session: session))
        let target = try #require(manager.detach(second, position: nil, session: session))
        var notices = 0
        let destination = WorkbenchTabContext(
            workspaceID: target.id, hostID: hostID, sessionName: "two", onRejected: { notices += 1 },
            receive: { drag, _, _ in manager.transfer(drag, to: target.id, session: session) }
        )
        let drag = WorkbenchTabDrag(workspaceID: source.id, hostID: hostID, sessionName: "one", tab: .window("@1"))

        #expect(destination.drop(drag, at: .before(.window("@2")), rightSide: true) { _ in false })
        #expect(notices == 1)
        #expect(manager.workspaces.count == 2)
        #expect(source.members == [first] && target.members == [second])
        #expect(source.selection == .window("@1") && target.selection == .window("@2"))
    }

    @Test(arguments: [false, true], [WorkbenchTabDropPlacement.before(.window("@2")), .group([.window("@2")]), .end([.window("@2")])])
    func matchingSessionStillTransfersToRequestedPosition(succeeded: Bool, requested: WorkbenchTabDropPlacement) {
        var transfers = 0
        let sourceID = UUID()
        let destination = WorkbenchTabContext(
            workspaceID: UUID(), hostID: nil, sessionName: "work",
            onRejected: { Issue.record("Valid transfer was rejected") },
            receive: { drag, placement, right in
                transfers += 1
                #expect(drag.workspaceID == sourceID && drag.tab == .window("@1"))
                #expect(placement == requested && right)
                return succeeded
            }
        )
        let drag = WorkbenchTabDrag(workspaceID: sourceID, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(destination.drop(drag, at: requested, rightSide: true) { _ in
            Issue.record("Cross-window transfer reached local reordering")
            return false
        } == succeeded)
        #expect(transfers == 1)
    }

    @Test(arguments: [nil, UUID()] as [UUID?])
    func sameWorkspaceKeepsLocalReordering(workspaceID: UUID?) {
        var reorders = 0
        let context = WorkbenchTabContext(
            workspaceID: workspaceID, hostID: nil, sessionName: "work",
            onRejected: { Issue.record("Local reordering was rejected") },
            receive: { _, _, _ in Issue.record("Local reordering reached transfer")
                return false
            }
        )
        #expect(context.drop(context.drag(.window("@1")), at: .before(.window("@2")), rightSide: false) { _ in
            reorders += 1
            return true
        })
        #expect(reorders == 1)
    }
}
