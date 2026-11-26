import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Tmux window reorder")
@MainActor
struct WindowReorderTests {
    @Test("Detaching an earlier terminal cannot swap untouched source groups during the first group move", arguments: [false, true], [1, 2])
    func detachedTerminalKeepsDisplayedSourceOrder(detached: Bool, membersPerPane: Int) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), tabs = SessionFileTabsState()
            let early = TabDragPayload.window("@1"), current = TabDragPayload.window("@2")
            let earlyID = SessionTabID.window(UUID()), currentID = SessionTabID.window(UUID())
            let firstFiles = (0..<membersPerPane).map { FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/first-\($0)")) }
            let secondFiles = (0..<membersPerPane).map { FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/second-\($0)")) }
            let m = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/m")), n = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/n"))
            let mp = TabDragPayload.file(m.id), np = TabDragPayload.file(n.id), mID = SessionTabID.file(m.id), nID = SessionTabID.file(n.id)
            let resources = firstFiles + secondFiles + [m, n]
            let catalog = [earlyID, currentID] + resources.map { SessionTabID.file($0.id) }
            let panes = Dictionary(uniqueKeysWithValues: firstFiles.map { (SessionTabID.file($0.id), "%1") } + secondFiles.map { (SessionTabID.file($0.id), "%2") })
            let layout = SessionTabLayout(order: catalog, groups: [mID: group, nID: group], revision: 3)
            var ids = Dictionary(uniqueKeysWithValues: resources.map { (TabDragPayload.file($0.id), SessionTabID.file($0.id)) })
            ids[early] = earlyID
            ids[current] = currentID
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: panes, paneOrder: ["%1", "%2"])
            tabs.directoryTabs = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
            tabs.sharedManualTabGroups = snapshot.groups
            tabs.tabOrder = (detached ? [current] : [early, current]) + [mp, np] + (firstFiles + secondFiles).map { .file($0.id) }
            let states = [PaneState(paneId: "%1", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 0), PaneState(paneId: "%2", sessionName: "work", windowIndex: 1, tmuxWindowId: "@2", paneIndex: 0)]
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: states, layout: snapshot)
            let originalSources = tabs.tabStripEntries(before).compactMap(\.sourcePaneID)
            #expect(originalSources == (detached ? ["%2", "%1"] : ["%1", "%2"]))
            var request: EditSessionTabLayout?, confirmation: (@MainActor () -> Void)?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, done in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
                confirmation = done
            }
            #expect(tabs.moveGroup([mp, np], at: .before(current), visible: before, sessionOrder: before, shared: shared))
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes, paneOrder: ["%1", "%2"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            #expect(rows.compactMap(\.sourcePaneID) == originalSources)
            #expect(Array(rows.prefix(3).map(\.tabs)) == [[earlyID], [mID, nID], [currentID]])
            tabs.sharedOrdersTabGroups = true
            confirmation?()
            let after = tabs.presentedTabOrder(tabs.tabOrder, panes: states, layout: .init(ids: ids, layout: saved, sourcePanes: panes))
            #expect(tabs.tabStripEntries(after).compactMap(\.sourcePaneID) == originalSources)
        }
    }

    @Test("A first source-group move preserves a detached Files row before untouched source groups", arguments: [false, true], [false, true])
    func unseededSourceMoveKeepsHiddenRows(savedLayout: Bool, fileVisible: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            @MainActor
            func file(_ path: String, pane: String? = nil) -> FileBrowserTab {
                FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: pane, initialDirectory: path))
            }
            let session = UUID(), tabs = SessionFileTabsState(), w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
            let r = file("/target"), d = file("/detached"), s = file("/source", pane: "%1"), x = file("/x", pane: "%2"), y = file("/y", pane: "%2")
            let rp = TabDragPayload.file(r.id), dp = TabDragPayload.file(d.id), sp = TabDragPayload.file(s.id), xp = TabDragPayload.file(x.id), yp = TabDragPayload.file(y.id)
            let rID = SessionTabID.file(r.id), dID = SessionTabID.file(d.id), sID = SessionTabID.file(s.id), xID = SessionTabID.file(x.id), yID = SessionTabID.file(y.id)
            let catalog = [wID, rID, sID, dID, xID, yID], panes = [sID: "%1", xID: "%2", yID: "%2"]
            @Dependency(PreferencesService.self) var preferences
            if savedLayout {
                try preferences.setData(JSONEncoder().encode([session: SessionTabLayout(order: catalog, revision: 3)]), "sessionTabLayouts")
            }
            let store = HostSessionTabLayouts(), layout = store.snapshot(sessionID: session, catalog: catalog)
            let allIDs = [w: wID, rp: rID, dp: dID, sp: sID, xp: xID, yp: yID]
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: allIDs.filter { fileVisible || $0.key != dp }, layout: layout, sourcePanes: panes, paneOrder: ["%1", "%2"])
            tabs.directoryTabs = Dictionary(uniqueKeysWithValues: [r, d, s, x, y].map { ($0.id, $0) })
            tabs.tabOrder = [w, rp, sp, xp, yp] + (fileVisible ? [dp] : [])
            let states = [PaneState(paneId: "%1", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 0), PaneState(paneId: "%2", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 1)]
            let allBefore = tabs.presentedTabOrder([w, rp, sp, dp, xp, yp], panes: states, layout: .init(ids: allIDs, layout: layout, sourcePanes: panes))
            #expect(tabs.tabStripEntries(allBefore).map(\.tabs) == [[w], [rp], [dp], [sp], [xp, yp]])
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: states, layout: snapshot)
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
            }
            #expect(tabs.moveGroup([xp, yp], at: .before(rp), visible: before, sessionOrder: before, shared: shared))
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes, paneOrder: ["%1", "%2"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { panes[$0].map(SessionTabGroup.pane) }
            #expect(rows.map(\.tabs) == [[wID], [xID, yID], [rID], [dID], [sID]])
        }
    }

    @Test("A Mac local group cannot rewrite an untouched shared row or its member order", arguments: [
        (false, false, false), (false, false, true), (false, true, false), (false, true, true),
        (true, false, false), (true, false, true), (true, true, false), (true, true, true),
    ])
    func localGroupingPreservesSharedMemberOrder(automatic: Bool, locallyGrouped: Bool, privateBeforeTerminal: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            @MainActor
            func file(_ path: String, pane: String? = nil) -> FileBrowserTab {
                FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: pane, initialDirectory: path))
            }
            let session = UUID(), group = UUID(), tabs = SessionFileTabsState(), w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
            let a = file("/a", pane: automatic ? "%1" : nil), b = file("/b", pane: automatic ? "%1" : nil), x = file("/x", pane: "%2"), y = file("/y", pane: "%2"), p = FileBrowserTab(path: "/private")
            let s = file("/unmoved-source", pane: "%0"), sp = TabDragPayload.file(s.id), sID = SessionTabID.file(s.id)
            let ap = TabDragPayload.file(a.id), bp = TabDragPayload.file(b.id), xp = TabDragPayload.file(x.id), yp = TabDragPayload.file(y.id), pp = TabDragPayload.file(p.id)
            let aID = SessionTabID.file(a.id), bID = SessionTabID.file(b.id), xID = SessionTabID.file(x.id), yID = SessionTabID.file(y.id)
            let catalog = [wID, sID, bID, aID, xID, yID], groups = automatic ? [:] : [aID: group, bID: group]
            let panes = automatic ? [sID: "%0", aID: "%1", bID: "%1", xID: "%2", yID: "%2"] : [sID: "%0", xID: "%2", yID: "%2"]
            let layout = SessionTabLayout(order: catalog, groups: groups, revision: 3)
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: [w: wID, ap: aID, bp: bID, xp: xID, yp: yID, sp: sID], layout: layout, sourcePanes: panes, paneOrder: ["%0", "%1", "%2"])
            tabs.directoryTabs = Dictionary(uniqueKeysWithValues: [a, b, x, y, p, s].map { ($0.id, $0) })
            tabs.tabOrder = privateBeforeTerminal ? [pp, w, ap, sp, bp, xp, yp] : [w, ap, pp, sp, bp, xp, yp]
            tabs.sharedManualTabGroups = snapshot.groups
            if locallyGrouped {
                #expect(tabs.mergeTab(ap, into: [pp], visible: tabs.tabOrder))
            }
            let states = (0..<3).map { PaneState(paneId: "%\($0)", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: $0) }
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: states, layout: snapshot)
            let aIndex = try #require(before.firstIndex(of: ap)), bIndex = try #require(before.firstIndex(of: bp))
            let terminalIndex = try #require(before.firstIndex(of: w))
            #expect((aIndex < bIndex) == locallyGrouped)
            #expect((aIndex < terminalIndex) == (locallyGrouped && privateBeforeTerminal))
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
            }
            #expect(tabs.moveGroup([xp, yp], at: .before(w), visible: before, sessionOrder: before, shared: shared))
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes, paneOrder: ["%0", "%1", "%2"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order.filter { $0 == aID || $0 == bID } == [bID, aID])
            #expect(saved.groups == groups)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            #expect(rows.map(\.tabs) == (automatic ? [[xID, yID], [wID], [sID], [bID, aID]] : [[xID, yID], [wID], [bID, aID], [sID]]))
        }
    }

    @Test("A detached ordinary Files row stays before an untouched source group", arguments: [false, true], [false, true])
    func hiddenFileRemainsBeforeSourceGroup(fileVisible: Bool, windowGrouped: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), tabs = SessionFileTabsState()
            let w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
            let m = TabDragPayload.file(UUID()), n = TabDragPayload.file(UUID()), d = TabDragPayload.file(UUID())
            let mID = SessionTabID.file(UUID()), nID = SessionTabID.file(UUID()), dID = SessionTabID.file(UUID())
            let source = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/source")), sourceTab = TabDragPayload.file(source.id), sourceID = SessionTabID.file(source.id), peer = SessionTabID.file(UUID())
            let target = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: windowGrouped ? "%2" : nil, initialDirectory: "/target")), r = TabDragPayload.file(target.id), rID = SessionTabID.file(target.id)
            let catalog = windowGrouped ? [wID, mID, nID, sourceID, dID, rID, peer] : [wID, rID, sourceID, dID, mID, nID, peer]
            var groups = [mID: group, nID: group], panes = [sourceID: "%1", peer: "%1"]
            if windowGrouped {
                groups[wID] = group
                panes[rID] = "%2"
            }
            let layout = SessionTabLayout(order: catalog, groups: groups, revision: 3)
            var ids = [w: wID, r: rID, m: mID, n: nID, sourceTab: sourceID]
            if fileVisible {
                ids[d] = dID
            }
            tabs.tabOrder = [w, r, m, n, sourceTab] + (fileVisible ? [d] : [])
            tabs.directoryTabs = [source.id: source, target.id: target]
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: panes, paneOrder: ["%1", "%2"])
            tabs.sharedManualTabGroups = snapshot.groups
            let states = [PaneState(paneId: "%1", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 0), PaneState(paneId: "%2", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 1)]
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: states, layout: snapshot)
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
            }
            let accepted = tabs.moveGroup(windowGrouped ? [w, m, n] : [m, n], at: .before(r), visible: before, sessionOrder: before, shared: shared)
            #expect(accepted)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(#require(request), catalog: catalog, sourcePanes: panes, paneOrder: ["%1", "%2"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            let expected: [[SessionTabID]] = windowGrouped ? [[dID], [sourceID, peer], [wID, mID, nID], [rID]] : [[wID], [mID, nID], [rID], [dID], [sourceID, peer]]
            #expect(rows.map(\.tabs) == expected)
        }
    }

    @Test("First source-group ordering preserves the displayed Browser and Files member order", arguments: [false, true], [false, true])
    func initialGroupRetainsDisplayedMemberOrder(savedOrder: Bool, browserFirst: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), tabs = SessionFileTabsState(), w = TabDragPayload.window("@1"), wID = SessionTabID.window(UUID())
            let file = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/files")), f = TabDragPayload.file(file.id), fID = SessionTabID.file(file.id)
            let browserID = UUID(), b = TabDragPayload.browser(browserID), bID = SessionTabID.browser(browserID)
            let catalog = [wID, fID, bID], panes = [fID: "%1", bID: "%1"], store = HostSessionTabLayouts()
            @Dependency(PreferencesService.self) var preferences
            if savedOrder {
                try preferences.setData(JSONEncoder().encode([session: SessionTabLayout(order: catalog, revision: 3, ordersGroups: true)]), "sessionTabLayouts")
            }
            let activeStore = savedOrder ? HostSessionTabLayouts() : store
            let layout = activeStore.snapshot(sessionID: session, catalog: catalog)
            tabs.tabOrder = [w] + (browserFirst ? [b, f] : [f, b])
            tabs.directoryTabs[file.id] = file
            tabs.remoteBrowserTabs[browserID] = .init(id: browserID, sessionName: "work", windowID: "@1", title: "Browser", url: "about:blank", isLoading: false, isAgentOwned: false, sourcePaneID: "%1")
            tabs.sharedOrdersTabGroups = savedOrder
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: [w: wID, f: fID, b: bID], layout: layout, sourcePanes: panes, paneOrder: ["%1"])
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: snapshot)
            let members = try #require(tabs.tabStripEntries(before).first { $0.sourcePaneID == "%1" }?.tabs)
            let expectedMembers: [TabDragPayload] = !savedOrder && browserFirst ? [b, f] : [f, b]
            #expect(members == expectedMembers)
            var request: EditSessionTabLayout?, confirmation: (@MainActor () -> Void)?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, done in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
                confirmation = done
            }
            let accepted = tabs.moveGroup(members, at: .before(w), visible: before, sessionOrder: before, shared: shared)
            #expect(accepted)
            try await activeStore.apply(#require(request), catalog: catalog, sourcePanes: panes, paneOrder: ["%1"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            confirmation?()
            #expect(saved.order == expectedMembers.compactMap { snapshot.ids[$0] } + [wID])
            #expect(tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: .init(ids: snapshot.ids, layout: saved, sourcePanes: panes)) == expectedMembers + [w])
        }
    }

    @Test("An unseeded source-group move preserves a hidden shared Files row")
    func unseededGroupPreservesHiddenOrdinaryFile() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), w = SessionTabID.window(UUID()), d = SessionTabID.file(UUID()), r = SessionTabID.file(UUID()), x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID())
            let catalog = [w, x, d, r, y], panes = [x: "%1", y: "%1"], store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([x, y], before: r, sourcePaneID: "%1"), initialOrder: [w, r, x, y], initialOrderRevision: 0), catalog: catalog, sourcePanes: panes) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order == [w, d, x, y, r])
        }
    }

    @Test("A first partial-group move preserves two untouched shared Files", arguments: [false, true], [false, true])
    func firstGroupPreservesHiddenOrdinaryFile(fileVisible: Bool, sourceFirst: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), tabs = SessionFileTabsState()
            let d = TabDragPayload.file(UUID()), r = TabDragPayload.file(UUID()), m = TabDragPayload.file(UUID()), n = TabDragPayload.file(UUID())
            let leader = SessionTabID.file(UUID()), dID = SessionTabID.file(UUID()), rID = SessionTabID.file(UUID()), mID = SessionTabID.file(UUID()), nID = SessionTabID.file(UUID())
            let source = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/source")), sourceID = SessionTabID.file(source.id), sourceTab = TabDragPayload.file(source.id)
            let top = [leader, dID, rID, mID, nID], catalog = sourceFirst ? [sourceID] + top : top + [sourceID]
            let layout = SessionTabLayout(order: catalog, groups: [leader: group, mID: group, nID: group], revision: 3)
            var ids: [TabDragPayload: SessionTabID] = [r: rID, m: mID, n: nID, sourceTab: sourceID]
            if fileVisible {
                ids[d] = dID
            }
            tabs.tabOrder = (fileVisible ? [d] : []) + [r, m, n, sourceTab]
            tabs.directoryTabs[source.id] = source
            let snapshot = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout, sourcePanes: [sourceID: "%1"])
            tabs.sharedManualTabGroups = snapshot.groups
            let before = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: snapshot)
            var request: EditSessionTabLayout?
            let shared = SharedWorkbenchTabLayout(snapshot: snapshot) { edit, initial, windows, _, _ in
                request = .init(sessionID: session, edit: edit, initialOrder: initial, visibleWindows: windows, initialOrderRevision: layout.revision)
            }
            let accepted = tabs.moveGroup([m, n], at: .before(r), visible: before, sessionOrder: before, shared: shared)
            #expect(accepted)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(#require(request), catalog: catalog, sourcePanes: [sourceID: "%1"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? (tab == sourceID ? .pane("%1") : nil)
            }
            #expect(rows.map(\.tabs) == [[dID], [leader, mID, nID], [rID], [sourceID]])
        }
    }

    @Test("First ordering keeps hidden source rows in pane order", arguments: [0, 1, 2])
    func hiddenSourceRowsKeepPaneOrder(visibleSources: Int) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), file = SessionTabID.file(UUID())
            let m = SessionTabID.file(UUID()), n = SessionTabID.file(UUID())
            let a = SessionTabID.file(UUID()), aa = SessionTabID.file(UUID()), b = SessionTabID.file(UUID()), bb = SessionTabID.file(UUID())
            let panes = [a: "%1", aa: "%1", b: "%2", bb: "%2"], catalog = [b, bb, a, aa, file, m, n]
            let layout = SessionTabLayout(order: catalog, groups: [m: group, n: group], revision: 3)
            let visible = [file, m, n] + (visibleSources == 2 ? [a, b] : visibleSources == 1 ? [b] : [])
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([m, n], before: file, groupID: group), initialOrder: visible, initialOrderRevision: layout.revision), catalog: catalog, sourcePanes: panes, paneOrder: ["%1", "%2"]) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            #expect(rows.map(\.tabs) == [[m, n], [file], [a, aa], [b, bb]])
        }
    }

    @Test("First group ordering keeps hidden source members with their displayed row", arguments: [false, true])
    func firstGroupKeepsHiddenSourceMembers(fullyHidden: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID()
            let m = SessionTabID.file(UUID()), n = SessionTabID.file(UUID()), file = SessionTabID.file(UUID())
            let visible = SessionTabID.file(UUID()), hidden = SessionTabID.file(UUID()), panes = [visible: "%1", hidden: "%1"]
            let catalog = [hidden, m, n, file, visible]
            let layout = SessionTabLayout(order: catalog, groups: [m: group, n: group], revision: 3)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([m, n], before: nil, groupID: group), initialOrder: fullyHidden ? [m, n, file] : [m, n, file, visible], initialOrderRevision: layout.revision), catalog: catalog, sourcePanes: panes) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            #expect(rows.map(\.tabs) == [[file], [hidden, visible], [m, n]])
        }
    }

    @Test("A first group move keeps a completely detached source group after untouched Files")
    func fullyHiddenSourceGroupKeepsDisplayedPosition() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), window = SessionTabID.window(UUID())
            let file = SessionTabID.file(UUID()), m = SessionTabID.file(UUID()), n = SessionTabID.file(UUID())
            let x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID()), panes = [x: "%1", y: "%1"]
            let catalog = [window, x, y, file, m, n]
            let layout = SessionTabLayout(order: catalog, groups: [m: group, n: group], revision: 3)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([m, n], before: file, groupID: group), initialOrder: [window, file, m, n], initialOrderRevision: layout.revision), catalog: catalog, sourcePanes: panes) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { tab in
                saved.groups[tab].map(SessionTabGroup.manual) ?? panes[tab].map(SessionTabGroup.pane)
            }
            #expect(rows.map(\.tabs) == [[window], [m, n], [file], [x, y]])
        }
    }

    @Test("The first resource-group move keeps an untouched terminal group and its neighboring rows")
    func firstResourceGroupPreservesTerminalGroup() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID()
            let a = SessionTabID.window(UUID()), b = SessionTabID.window(UUID()), c = SessionTabID.window(UUID())
            let file = SessionTabID.file(UUID()), source = SessionTabID.file(UUID())
            let catalog = [a, b, c, file, source]
            let layout = SessionTabLayout(order: [a, file, b, c, source], groups: [a: group, c: group], revision: 2)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([source], before: a, sourcePaneID: "%1"), initialOrder: [a, c, file, b, source], initialOrderRevision: layout.revision), catalog: catalog, sourcePanes: [source: "%1"]) { projected in
                #expect(projected.order.filter {
                    if case .window = $0 {
                        true
                    } else {
                        false
                    }
                } == [a, b, c])
                return nil
            }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            let rows = SessionTabEntry.grouped(saved.order, preserveGroupPositions: true) { saved.groups[$0].map(SessionTabGroup.manual) }
            #expect(rows.map(\.tabs) == [[source], [a, c], [file], [b]])
        }
    }

    @Test("First group initialization keeps untouched resources and windows in their displayed order")
    func firstWindowGroupPreservesUntouchedRows() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID(), a = SessionTabID.window(UUID()), b = SessionTabID.window(UUID()), c = SessionTabID.window(UUID()), file = SessionTabID.file(UUID())
            let layout = SessionTabLayout(order: [a, file, b, c], groups: [a: group, c: group], revision: 2)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: layout]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([a, c], before: nil, groupID: group), initialOrder: [a, c, file, b], initialOrderRevision: layout.revision), catalog: [a, b, c, file]) { projected in
                #expect(projected.order == [file, b, a, c])
                return nil
            }
            #expect(HostSessionTabLayouts().snapshot(sessionID: session, catalog: [b, a, c, file]).order == [file, b, a, c])
        }
    }

    @Test("The first group move preserves current tmux window order despite an unchanged layout revision")
    func initialGroupOrderPreservesLiveWindows() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID()
            let ids = (0..<4).map { _ in SessionTabID.window(UUID()) }
            let file = SessionTabID.file(UUID())
            let initial = SessionTabLayout(order: ids + [file], groups: [ids[3]: group, file: group], revision: 3)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: initial]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            let catalog = [ids[0], ids[2], ids[1], ids[3], file]
            #expect(store.snapshot(sessionID: session, catalog: catalog).revision == initial.revision)
            try await store.apply(.init(sessionID: session, edit: .moveGroup([ids[3], file], before: ids[0], groupID: group), initialOrder: initial.order, initialOrderRevision: initial.revision), catalog: catalog) { projected in
                #expect(projected.order.filter { ids.contains($0) } == [ids[3], ids[0], ids[2], ids[1]])
                return nil
            }
            #expect(HostSessionTabLayouts().snapshot(sessionID: session, catalog: [ids[3], ids[0], ids[2], ids[1], file]).groups == initial.groups)
        }
    }

    @Test("First group ordering cannot overwrite a concurrently confirmed order", arguments: [false, true])
    func initialGroupOrderRequiresMatchingRevision(alreadyOrdered: Bool) async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let session = UUID(), group = UUID()
            let a = SessionTabID.file(UUID()), b = SessionTabID.file(UUID()), c = SessionTabID.file(UUID())
            let x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID())
            let catalog = [a, b, c, x, y]
            let initial = SessionTabLayout(order: catalog, groups: [x: group, y: group], revision: 3, ordersGroups: alreadyOrdered ? true : nil)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: initial]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .move(c, before: b)), catalog: catalog) { _ in nil }
            let confirmed = store.snapshot(sessionID: session, catalog: catalog)
            let stale = EditSessionTabLayout(sessionID: session, edit: .moveGroup([x, y], before: a, groupID: group), initialOrder: [x, y, a, b, c], initialOrderRevision: initial.revision)
            if alreadyOrdered {
                try await store.apply(stale, catalog: catalog) { _ in nil }
            } else {
                do {
                    try await store.apply(stale, catalog: catalog) { _ in Issue.record("Confirmed a stale initial order")
                        return nil
                    }
                    Issue.record("Accepted a stale initial order")
                } catch { #expect(error is FileBrowserError) }
                #expect(store.snapshot(sessionID: session, catalog: catalog) == confirmed)
                try await store.apply(.init(sessionID: session, edit: stale.edit, initialOrder: [x, y, a, c, b], initialOrderRevision: confirmed.revision), catalog: catalog) { _ in nil }
            }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order == [x, y, a, c, b])
            #expect(saved.groups == initial.groups)
        }
    }

    @Test("The first group move seeds displayed group order and survives reopening the Host store")
    func persistsGroupOrder() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let session = UUID(), group = UUID()
            let a = SessionTabID.window(UUID()), x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID()), z = SessionTabID.browser(UUID())
            let catalog = [a, x, y, z]
            let initial = SessionTabLayout(order: [x, a, y, z], groups: [y: group, z: group], revision: 3)
            @Dependency(PreferencesService.self) var preferences
            try preferences.setData(JSONEncoder().encode([session: initial]), "sessionTabLayouts")
            let store = HostSessionTabLayouts()
            try await store.apply(.init(sessionID: session, edit: .moveGroup([x], before: y), initialOrder: [a, y, z, x], initialOrderRevision: initial.revision), catalog: catalog) { _ in nil }
            let saved = HostSessionTabLayouts().snapshot(sessionID: session, catalog: catalog)
            #expect(saved.order == [a, x, y, z])
            #expect(saved.groups == initial.groups)
            #expect(saved.ordersGroups == true && saved.supportsGroupReordering == true)
        }
    }

    @Test("Only a terminal move changes tmux order, including after another workbench or tmux edits the session")
    func sharedLayoutReordersLiveSession() async throws {
        let path = try #require(TmuxBinaryLocator.liveValue.find())
        let socket = "/tmp/ctrlx-tab-\(UUID().uuidString.prefix(12)).sock"
        let runner = ProcessRunner.liveValue
        let run: ([String]) async throws -> ProcessResult = { arguments in
            try await runner.run(executable: path, arguments: ["-S", socket, "-f", "/dev/null"] + arguments, environment: ["TMUX": "", "TMUX_PANE": ""], timeout: 10)
        }
        try await withDependencies {
            $0[ProcessRunner.self] = runner
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0.continuousClock = ContinuousClock()
        } operation: {
            _ = try await run(["new-session", "-d", "-s", "tabs", "/bin/cat"])
            do {
                for name in ["second", "third"] {
                    _ = try await run(["new-window", "-t", "tabs:", "-n", name, "/bin/cat"])
                }
                let settings = AppSettings()
                settings.tmuxPath = path
                settings.tmuxSocket = socket
                let coordinator = AppCoordinator(settings: settings)
                let panes = await coordinator.tmuxService.refreshPanes()
                coordinator.resourceSessions.update(panes)
                let sessionID = try #require(panes.first?.workspaceIdentity?.sessionID)
                let order: [SessionTabID] = panes.sorted { $0.windowIndex < $1.windowIndex }.compactMap { $0.workspaceIdentity.map { .window($0.windowID) } }
                try #require(order.count == 3)
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.revision == 0)

                let session = try coordinator.resourceSessions.resolve(sessionID)
                let first = try SessionTabID.file(coordinator.hostFileTabs.open(session: session, directory: "/tmp").id)
                let second = try SessionTabID.file(coordinator.hostFileTabs.open(session: session, directory: "/").id)
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .group(first, with: [second]),
                    initialOrder: [order[0], order[2], second, first]
                ))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [second, first])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                let placeFileBeforeDetachedWindow = EditSessionTabLayout(sessionID: sessionID, edit: .move(first, before: order[1]))
                try await coordinator.editSessionTabLayout(placeFileBeforeDetachedWindow)
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == [order[0], first, order[1], order[2], second])

                // Moving C across Files alone still has to reconcile the hidden B.
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .move(order[2], before: first),
                    visibleWindows: [order[0], order[2]]
                ))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                try await coordinator.editSessionTabLayout(placeFileBeforeDetachedWindow)
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .move(order[2], before: order[0]),
                    visibleWindows: [order[0], order[2]]
                ))
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@2\n@1\n@0\n")
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == Array(order.reversed()) + [first, second])

                _ = try await run(["swap-window", "-d", "-s", "@0", "-t", "@2"])
                await coordinator.tmuxService.refreshPanes()
                try await coordinator.editSessionTabLayout(.init(sessionID: sessionID, edit: .group(second, with: [first])))
                #expect(coordinator.sharedSessionTabLayouts[sessionID]?.order == order + [first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")

                let request = EditSessionTabLayout(sessionID: sessionID, edit: .moveToEnd(order[0], after: order[2]))
                try await coordinator.editSessionTabLayout(request)
                let saved = try #require(coordinator.sharedSessionTabLayouts[sessionID])
                #expect(saved.order == [order[1], order[2], order[0], first, second])
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@1\n@2\n@0\n")

                let next = EditSessionTabLayout(sessionID: sessionID, edit: .moveToEnd(order[1], after: nil))
                try await withDependencies {
                    $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                        if arguments.contains(where: { $0.contains("swap-window") }) {
                            return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("injected swap failure".utf8))
                        }
                        return try await runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    }
                } operation: {
                    await #expect(throws: (any Error).self) { try await coordinator.editSessionTabLayout(next) }
                }
                #expect(coordinator.sharedSessionTabLayouts[sessionID] == saved)
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@1\n@2\n@0\n")
                try await coordinator.editSessionTabLayout(.init(sessionID: sessionID, edit: .group(order[0], with: [first, second])))
                let grouped = try #require(coordinator.sharedSessionTabLayouts[sessionID])
                _ = try await run(["swap-window", "-d", "-s", "@1", "-t", "@2"])
                let identity = try #require(panes.first?.workspaceIdentity)
                await #expect(throws: TmuxError.self) {
                    try await coordinator.tmuxService.moveWindows(in: "tabs", to: ["@1", "@2", "@0"], expectedWorkspacePane: identity, expectedOrder: ["@1", "@2", "@0"])
                }
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@2\n@1\n@0\n")
                try await coordinator.editSessionTabLayout(.init(
                    sessionID: sessionID, edit: .moveGroup([first, second, order[0]], before: order[1], groupID: grouped.groups[first]), initialOrder: grouped.order, initialOrderRevision: grouped.revision
                ))
                let movedGroup = try #require(coordinator.sharedSessionTabLayouts[sessionID])
                #expect(movedGroup.order == [order[2], first, second, order[0], order[1]])
                #expect(movedGroup.groups == grouped.groups && movedGroup.ordersGroups == true)
                #expect(try await run(["list-windows", "-t", "tabs", "-F", "#{window_id}"]).stdoutString == "@2\n@0\n@1\n")
            } catch {
                _ = try? await run(["kill-server"])
                throw error
            }
            _ = try await run(["kill-server"])
        }
    }

    @Test("A terminal returned after Git in a new session keeps its position after the next Host edit")
    func firstTerminalReturnSurvivesSubsequentGrouping() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = HostSessionTabLayouts()
            let sessionID = UUID()
            let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
            let x = TabDragPayload.file(UUID()), y = TabDragPayload.file(UUID())
            let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID())
            let xID = SessionTabID.file(UUID()), yID = SessionTabID.file(UUID())
            let ids = [a: aID, b: bID, x: xID, y: yID]
            var catalog = [aID, bID, xID, yID]
            let snapshot = store.snapshot(sessionID: sessionID, catalog: catalog)
            var request: EditSessionTabLayout?
            var complete: (@MainActor () -> Void)?
            let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: snapshot)) { edit, baseline, windows, _, confirm in
                request = .init(sessionID: sessionID, edit: edit, initialOrder: baseline, visibleWindows: windows)
                complete = confirm
            }
            let tabs = SessionFileTabsState()
            tabs.tabOrder = [b, .git, x, y]
            tabs.rightSide = [.git]
            let placement = WorkbenchTabDropPlacement.end([.git])
            #expect(shared.drop(a, at: placement, order: tabs.tabOrder) {
                tabs.tabOrder.append(a)
                tabs.recordTabDrop(a, at: placement)
                tabs.rightSide.insert(a)
            })
            let move = try #require(request)
            #expect(snapshot.revision == 0)
            #expect(move.visibleWindows == [bID, aID])
            try await store.apply(move, catalog: catalog) { layout in
                let windows = layout.order.filter { $0 == aID || $0 == bID }
                catalog = windows + [xID, yID]
                return windows
            }
            complete?()
            try await store.apply(.init(sessionID: sessionID, edit: .group(xID, with: [yID])), catalog: catalog) { _ in nil }

            let refreshed = store.snapshot(sessionID: sessionID, catalog: catalog)
            let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: .init(ids: ids, layout: refreshed))
            #expect(refreshed.revision == 2)
            #expect(displayed.filter(tabs.rightSide.contains) == [.git, a])
        }
    }

    @Test
    func permanentSessionRemovalCannotBeUndoneByAnInFlightLayoutEdit() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = HostSessionTabLayouts()
            let closed = UUID(), other = UUID()
            let a = SessionTabID.file(UUID()), b = SessionTabID.file(UUID())
            let catalog = [a, b]
            let edit = SessionTabLayout.Edit.group(a, with: [b])
            try await store.apply(.init(sessionID: closed, edit: edit), catalog: catalog) { _ in nil }
            try await store.apply(.init(sessionID: other, edit: edit), catalog: catalog) { _ in nil }
            await #expect(throws: FileBrowserError.self) {
                try await store.apply(.init(sessionID: closed, edit: edit), catalog: catalog) { _ in
                    try store.remove(closed)
                    return nil
                }
            }
            let reopened = HostSessionTabLayouts()
            #expect(reopened.snapshot(sessionID: closed, catalog: catalog).revision == 0)
            #expect(reopened.snapshot(sessionID: other, catalog: catalog).revision == 1)
        }
    }

    private func pane(
        _ paneId: String,
        session: String,
        window: Int,
        stableId: String
    ) -> PaneInfo {
        PaneInfo(
            paneId: paneId,
            target: "\(session):\(window).0",
            sessionName: session,
            windowIndex: window,
            tmuxWindowId: stableId,
            paneIndex: 0,
            command: "zsh",
            currentPath: "/tmp",
            width: 80,
            height: 24,
            isActive: true
        )
    }

    @Test("Plans stable-id swaps without assuming a zero base index")
    func plansBaseIndexOneOrder() throws {
        let current = [
            TmuxService.WindowPosition(stableId: "@1", index: 1),
            TmuxService.WindowPosition(stableId: "@2", index: 2),
            TmuxService.WindowPosition(stableId: "@3", index: 3),
        ]

        let swaps = try TmuxService.windowReorderSwaps(
            current: current,
            desiredIds: ["@3", "@1", "@2"]
        )

        #expect(swaps == [
            TmuxService.WindowSwap(sourceId: "@3", targetIndex: 1),
            TmuxService.WindowSwap(sourceId: "@1", targetIndex: 2),
        ])
    }

    @Test("Preserves sparse tmux index slots")
    func preservesSparseIndices() throws {
        let current = [
            TmuxService.WindowPosition(stableId: "@4", index: 4),
            TmuxService.WindowPosition(stableId: "@8", index: 8),
            TmuxService.WindowPosition(stableId: "@12", index: 12),
        ]

        let swaps = try TmuxService.windowReorderSwaps(
            current: current,
            desiredIds: ["@8", "@12", "@4"]
        )

        #expect(swaps == [
            TmuxService.WindowSwap(sourceId: "@8", targetIndex: 4),
            TmuxService.WindowSwap(sourceId: "@12", targetIndex: 8),
        ])
    }

    @Test("Rejects stale, partial, and duplicate requests")
    func rejectsInvalidOrders() {
        let current = [
            TmuxService.WindowPosition(stableId: "@1", index: 1),
            TmuxService.WindowPosition(stableId: "@2", index: 2),
        ]

        for desired in [["@1"], ["@1", "@1"], ["@1", "@gone"]] {
            #expect(throws: TmuxError.self) {
                try TmuxService.windowReorderSwaps(current: current, desiredIds: desired)
            }
        }
    }

    @Test("Detects target changes without confusing linked sessions")
    func detectsReindexBySessionAndStableId() {
        let old = [
            pane("%1", session: "alpha", window: 1, stableId: "@7"),
            pane("%1", session: "beta", window: 4, stableId: "@7"),
            pane("%2", session: "alpha", window: 2, stableId: "@8"),
        ]
        let new = [
            pane("%1", session: "alpha", window: 2, stableId: "@7"),
            pane("%1", session: "beta", window: 4, stableId: "@7"),
            pane("%2", session: "alpha", window: 1, stableId: "@8"),
        ]

        #expect(WindowReindexMapping.detect(from: old, to: new) == [
            "alpha:1": "alpha:2",
            "alpha:2": "alpha:1",
        ])
    }

    @Test("Reorders a live tmux session without losing window identity")
    func reordersLiveSession() async throws {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        try #require(FileManager.default.isExecutableFile(atPath: tmuxPath))

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let suffix = UUID().uuidString.lowercased()
            let sessionName = "ctrlx-reorder-\(suffix)"
            let socketPath = "/tmp/gw-\(suffix.prefix(8)).sock"
            let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
            defer { try? FileManager.default.removeItem(atPath: socketPath) }

            _ = try await service.createSession(baseName: sessionName, width: 80, height: 24)
            do {
                _ = try await service.newWindow(sessionName: sessionName, windowName: "second")
                _ = try await service.newWindow(sessionName: sessionName, windowName: "third")
                _ = await service.refreshPanes()

                let before = service.windows
                    .filter { $0.sessionName == sessionName }
                    .sorted { $0.windowIndex < $1.windowIndex }
                #expect(before.count == 3)
                #expect(before.allSatisfy { $0.stableId.hasPrefix("@") })

                let desired = [before[2].stableId, before[0].stableId, before[1].stableId]
                let originalPaneIds = Set(before.flatMap(\.panes).map(\.paneId))
                let originalIndices = before.map(\.windowIndex)
                let mapping = try await service.moveWindows(in: sessionName, to: desired)
                _ = await service.refreshPanes()

                let after = service.windows
                    .filter { $0.sessionName == sessionName }
                    .sorted { $0.windowIndex < $1.windowIndex }
                #expect(after.map(\.stableId) == desired)
                #expect(after.map(\.windowIndex) == originalIndices)
                #expect(Set(after.flatMap(\.panes).map(\.paneId)) == originalPaneIds)
                #expect(mapping.count == before.count)

                try await service.killSession(sessionName)
            } catch {
                try? await service.killSession(sessionName)
                throw error
            }
        }
    }
}
