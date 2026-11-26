import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct IOSPaneLinkedTabsTests {
    @Test("Two dissolved members mark their new source groups relative to the surviving terminal")
    func dissolvedGroupsWithEqualIndex() throws {
        let b = UUID(), group = UUID()
        func file(_ path: String, pane: String) -> FileBrowserTab {
            FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: pane, initialDirectory: path))
        }
        let x = file("/x", pane: "%1"), y = file("/y", pane: "%2"), s = file("/s", pane: "%1"), t = file("/t", pane: "%2")
        let model = IOSPaneLinkedTabs(files: [x, y, s, t], browsers: [], simulators: [], windows: windows([b]), storedOrder: [])
        let layout = SessionTabLayout(order: [.file(x.id), .file(y.id), .window(b), .file(s.id), .file(t.id)], groups: [.file(x.id): group, .file(y.id): group], revision: 3, ordersGroups: true)
        let edit = try #require(model.sharedMove(.file(x.id), before: .window(b), layout: layout))
        let projected = try #require(model.projecting(edit, in: layout, topLevelOrder: []))
        let before = model.sharedEntries(layout), after = model.sharedEntries(projected)
        #expect(after.map(\.tabs) == [[.file(y.id), .file(t.id)], [.file(x.id), .file(s.id)], [.window(b)]])
        #expect(IOSPaneLinkedTabs.insertionLine(for: .file(x.id), from: before, to: after, expandedGroup: .manual(group), preserveGroupPositions: true) == .before(.tab(.window(b))))
    }

    @Test("A returning member moves its existing source group's insertion line", arguments: [false, true])
    func returningMemberMovesExistingSourceGroup(expanded: Bool) throws {
        let a = UUID(), b = UUID(), c = UUID(), group = UUID()
        let s = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/s")), x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/x"))
        let y = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/y")), z = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/z"))
        let model = IOSPaneLinkedTabs(files: [s, x, y, z], browsers: [], simulators: [], windows: windows([a, b, c]), storedOrder: [])
        let layout = SessionTabLayout(order: [.window(a), .window(b), .window(c), .file(s.id), .file(x.id), .file(y.id), .file(z.id)], groups: [.file(x.id): group, .file(y.id): group, .file(z.id): group], revision: 2, ordersGroups: true)
        let edit = try #require(model.sharedMove(.file(x.id), before: .window(b), layout: layout))
        let projected = try #require(model.projecting(edit, in: layout, topLevelOrder: []))
        let before = model.sharedEntries(layout), after = model.sharedEntries(projected)
        #expect(after.map(\.id) == [.tab(.window(a)), .group(.pane("%1")), .tab(.window(b)), .tab(.window(c)), .group(.manual(group))])
        #expect(IOSPaneLinkedTabs.insertionLine(for: .file(x.id), from: before, to: after, expandedGroup: expanded ? .pane("%1") : .manual(group), preserveGroupPositions: true) == .after(.tab(.window(a))))
    }

    @Test("The first group preview uses current windows instead of saved private-tab window order")
    func firstGroupProjectionUsesCurrentWindows() throws {
        let a = UUID(), b = UUID(), group = UUID()
        let x = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/x")), y = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/y"))
        let model = IOSPaneLinkedTabs(files: [x, y], browsers: [], simulators: [], windows: windows([a, b]), storedOrder: [])
        let layout = SessionTabLayout(order: [.file(x.id), .file(y.id), .window(a), .window(b)], groups: [.file(x.id): group, .file(y.id): group], revision: 2)
        let saved: [IOSTopLevelTabID] = [.window(b), .window(a)]
        let before = model.sharedEntries(layout, topLevelOrder: saved)
        #expect(before.map(\.tabs) == [[.file(x.id), .file(y.id)], [.window(a)], [.window(b)]])
        let projected = try #require(model.projecting(.moveGroup([.file(x.id), .file(y.id)], before: nil, groupID: group), in: layout, topLevelOrder: saved))
        let after = model.sharedEntries(projected, topLevelOrder: saved)
        #expect(after.map(\.tabs) == [[.window(a)], [.window(b)], [.file(x.id), .file(y.id)]])
    }

    @Test("A restored automatic group uses retained terminal rows as its neighbors")
    func restoredAutomaticGroupBetweenTerminals() throws {
        let a = UUID(), b = UUID(), c = UUID(), group = UUID()
        let s = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/s")), x = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/x"))
        let y = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/y")), z = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/z"))
        let model = IOSPaneLinkedTabs(files: [s, x, y, z], browsers: [], simulators: [], windows: windows([a, b, c]), storedOrder: [])
        let layout = SessionTabLayout(order: [.window(a), .file(s.id), .window(b), .window(c), .file(x.id), .file(y.id), .file(z.id)], groups: [.file(x.id): group, .file(y.id): group, .file(z.id): group], revision: 2, ordersGroups: true)
        let edit = try #require(model.sharedMove(.file(x.id), before: .window(c), layout: layout))
        let projected = try #require(model.projecting(edit, in: layout, topLevelOrder: []))
        let before = model.sharedEntries(layout), after = model.sharedEntries(projected)
        #expect(after.map(\.id) == [.tab(.window(a)), .group(.pane("%1")), .tab(.window(b)), .group(.pane("%2")), .tab(.window(c)), .group(.manual(group))])
        #expect(IOSPaneLinkedTabs.insertionLine(for: .file(x.id), from: before, to: after, expandedGroup: .manual(group), preserveGroupPositions: true) == .after(.tab(.window(b))))
    }

    @Test("The first terminal-group move preserves the relative order of untouched Files and terminals")
    func firstTerminalGroupPreservesUntouchedRows() throws {
        let a = UUID(), b = UUID(), c = UUID(), group = UUID(), session = UUID()
        let file = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/file"))
        var model = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: windows([a, b, c]), storedOrder: [])
        let layout = SessionTabLayout(order: [.window(a), .file(file.id), .window(b), .window(c)], groups: [.window(a): group, .window(c): group], revision: 2)
        #expect(model.sharedEntries(layout).map(\.tabs) == [[.window(a), .window(c)], [.file(file.id)], [.window(b)]])
        let drop = IOSSessionTabDrop(hostID: "host", sessionID: session, tabs: model, layout: layout, topLevelOrder: [], isConnected: true, destination: .end)
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: session, tab: .window(a), group: [.window(a), .window(c)])
        defer { IOSSessionTabDrag.active = nil }
        guard case let .success(.moveGroup(change?, local)) = drop.plan(drag, position: 4, height: 44) else { Issue.record("Expected a terminal group move")
            return
        }
        let projected = try #require(model.projecting(change, in: layout, topLevelOrder: []))
        model.ordersGroups = true
        #expect(model.sharedEntries(projected, topLevelOrder: local).map(\.tabs) == [[.file(file.id)], [.window(b)], [.window(a), .window(c)]])
    }

    @Test("Leaving an expanded manual group uses automatic rows when locating the insertion line", arguments: [false, true])
    func leavingGroupIncludesAutomaticRows(expandedAutomatic: Bool) {
        let a = SessionTabID.window(UUID()), b = SessionTabID.file(UUID()), x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID()), z = SessionTabID.file(UUID())
        let group = UUID(), auto = SessionTabID.file(UUID())
        let current: [SessionTabEntry<SessionTabID>] = [.tab(a), .group(.pane("%1"), [auto]), .tab(b), .group(.manual(group), [x, y, z])]
        let after: [SessionTabEntry<SessionTabID>] = [.tab(a), .group(.pane("%1"), [auto]), .tab(x), .tab(b), .group(.manual(group), [y, z])]
        let line = IOSPaneLinkedTabs.insertionLine(for: x, from: current, to: after, expandedGroup: expandedAutomatic ? .pane("%1") : .manual(group))
        #expect(line == .after(expandedAutomatic ? .tab(auto) : .group(.pane("%1"))))
    }

    @Test("The first group preview starts with the same displayed order as the Host")
    func firstGroupProjection() throws {
        let a = UUID(), group = UUID()
        let b = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/b"))
        let s = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/s"))
        let x = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/x")), y = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/y"))
        var tabs = IOSPaneLinkedTabs(files: [b, s, x, y], browsers: [], simulators: [], windows: windows([a]), storedOrder: [])
        let ids: [SessionTabID] = [.window(a), .file(s.id), .file(b.id), .file(x.id), .file(y.id)]
        let layout = SessionTabLayout(order: ids, groups: [.file(x.id): group, .file(y.id): group], revision: 3)
        let edit = SessionTabLayout.Edit.moveGroup([.file(x.id), .file(y.id)], before: nil, groupID: group)
        let projected = try #require(tabs.projecting(edit, in: layout, topLevelOrder: []))
        tabs.ordersGroups = true
        #expect(tabs.sharedEntries(projected).map(\.id).suffix(2) == [.group(.pane("%1")), .group(.manual(group))])
        #expect(projected.order == [.window(a), .file(b.id), .file(s.id), .file(x.id), .file(y.id)])
    }

    @Test("A standalone reorder uses the complete visible rows for its insertion line", arguments: [false, true], [false, true])
    func insertionIncludesInterleavedAutomaticGroup(automaticPresent: Bool, expanded: Bool) throws {
        let a = UUID(), b = UUID(), c = UUID()
        let file = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/auto"))
        let source = SessionTabID.window(c), target = SessionTabID.window(b)
        let model = IOSPaneLinkedTabs(files: automaticPresent ? [file] : [], browsers: [], simulators: [], windows: windows([a, b, c]), storedOrder: [])
        let catalog: [SessionTabID] = [.window(a)] + (automaticPresent ? [.file(file.id)] : []) + [target, source]
        var layout = SessionTabLayout(order: catalog, revision: 2, ordersGroups: true)
        let before = model.sharedEntries(layout)
        let edit = try #require(model.sharedMove(source, before: target, layout: layout))
        let moved = layout.apply(edit, catalog: catalog)
        #expect(moved)
        let after = model.sharedEntries(layout)
        let line = IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: expanded ? .pane("%1") : nil)
        let expected: IOSPaneLinkedTabs.RowID = automaticPresent ? (expanded ? .tab(.file(file.id)) : .group(.pane("%1"))) : .tab(.window(a))
        #expect(line == .after(expected))
        let sourceSlot = try #require(after.map(\.id).firstIndex(of: .tab(source)))
        let targetSlot = try #require(after.map(\.id).firstIndex(of: .tab(target)))
        #expect(sourceSlot < targetSlot)
    }

    @Test("Return navigation follows the latest terminal origin without making the resource pane-bound")
    func independentResourceReturnTarget() throws {
        let current = windows([UUID(), UUID()])
        let a = try #require(current[0].panes.first?.workspaceIdentity)
        let b = try #require(current[1].panes.first?.workspaceIdentity)
        let independent = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/Shared", resourceSessionID: a.sessionID))
        let linked = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%0", initialDirectory: "/Agent"))
        let tabs = IOSPaneLinkedTabs(files: [independent, linked], browsers: [], simulators: [], windows: current, storedOrder: [])
        let file = PaneLinkedTabID.file(independent.id)
        #expect(tabs.returnTarget(for: file, openedFrom: nil) == nil)
        #expect(tabs.returnTarget(for: file, openedFrom: a)?.paneID == "%0")
        #expect(tabs.returnTarget(for: file, openedFrom: b)?.paneID == "%1")
        #expect(tabs.sourcePaneID(file) == nil)
        #expect(tabs.topLevel(stored: []).contains(.resource(file)))
        #expect(tabs.returnTarget(for: .file(linked.id), openedFrom: b)?.paneID == "%0")

        let replacement = IOSPaneLinkedTabs(files: [independent], browsers: [], simulators: [], windows: windows([UUID(), UUID()]), storedOrder: [])
        #expect(replacement.returnTarget(for: file, openedFrom: a) == nil)
    }

    @Test("Ungrouping or adding a terminal keeps automatic groups after iOS top-level rows")
    func sharedOrderKeepsAutomaticGroupsBehindTopLevelRows() {
        let aID = UUID(), bID = UUID(), cID = UUID()
        let a = SessionTabID.window(aID), b = SessionTabID.window(bID), c = SessionTabID.window(cID)
        let left = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%0", initialDirectory: "/Left"))
        let right = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/Right"))
        let local = FileBrowserTab(path: "/Private")
        let x = SessionTabID.file(left.id), y = SessionTabID.file(right.id)
        let privateTab = SessionTabID.file(local.id)
        let catalog = [a, b, x, y]
        let files = [left, right, local]
        let model = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: windows([aID, bID]), storedOrder: [])
        let saved: [IOSTopLevelTabID] = [.window(aID), .window(bID), .resource(.file(local.id))]
        var layout = SessionTabLayout(order: catalog)
        let grouped = layout.apply(.group(x, with: [a]), catalog: catalog)
        #expect(grouped && model.sharedEntries(layout, topLevelOrder: saved).flatMap(\.tabs) == [a, x, b, privateTab, y])
        let ungrouped = layout.apply(.ungroup(a), catalog: catalog)
        #expect(ungrouped && model.sharedEntries(layout, topLevelOrder: saved).flatMap(\.tabs) == [a, b, privateTab, x, y])

        layout = .init(order: catalog)
        let moved = layout.apply(.move(b, before: a), catalog: catalog)
        let withTerminalC = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: windows([aID, bID, cID]), storedOrder: [])
        #expect(moved && withTerminalC.sharedEntries(layout, topLevelOrder: saved).flatMap(\.tabs) == [b, a, privateTab, c, y, x])
    }

    @Test("Shared row and bottom drops only reorder tabs at the same level")
    func sharedMovesKeepAutomaticSourceGroupsTogether() throws {
        let aID = UUID(), bID = UUID()
        let a = SessionTabID.window(aID), b = SessionTabID.window(bID)
        let first = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/First"))
        let second = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/Second"))
        let other = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/Other"))
        let x = SessionTabID.file(first.id), y = SessionTabID.file(second.id), z = SessionTabID.file(other.id)
        let model = IOSPaneLinkedTabs(files: [first, second, other], browsers: [], simulators: [], windows: windows([aID, bID]), storedOrder: [])
        let catalog = [a, b, x, y, z]
        var layout = SessionTabLayout(order: catalog)
        #expect(model.sharedMove(x, before: b, layout: layout) == nil)
        #expect(model.sharedMove(b, before: x, layout: layout) == nil)
        #expect(model.sharedMove(x, before: z, layout: layout) == nil)
        #expect(model.sharedMove(y, before: x, layout: layout) == .move(y, before: x))
        #expect(model.sharedMove(x, before: nil, layout: layout) == .moveToEnd(x, after: y))
        #expect(model.sharedMove(z, before: nil, layout: layout) == nil)

        let move = try #require(model.sharedMove(a, before: nil, layout: layout))
        #expect(move == .moveToEnd(a, after: b))
        let before = model.sharedEntries(layout)
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout)
        #expect(after.flatMap(\.tabs) == [b, a, x, y, z])
        #expect(IOSPaneLinkedTabs.insertionLine(for: a, from: before, to: after, expandedGroup: nil) == .after(.tab(b)))

        let pane = SessionTabGroup.pane("%1")
        let moveWithinPane = try #require(model.sharedMove(x, before: nil, layout: layout))
        let movedWithinPane = layout.apply(moveWithinPane, catalog: catalog)
        #expect(movedWithinPane)
        let afterPaneMove = model.sharedEntries(layout)
        #expect(IOSPaneLinkedTabs.insertionLine(for: x, from: after, to: afterPaneMove, expandedGroup: pane) == .after(.tab(y)))
        #expect(IOSPaneLinkedTabs.insertionLine(for: x, from: after, to: afterPaneMove, expandedGroup: nil) == .after(.group(pane)))

        let group = UUID()
        var manual = SessionTabLayout(order: [a, b, z, y, x], groups: [x: group, z: group], revision: 1)
        #expect(model.sharedMove(x, before: b, layout: manual) == .move(x, before: b))
        let beforeLeavingGroup = model.sharedEntries(manual)
        let leaveGroup = try #require(model.sharedMove(x, before: nil, layout: manual))
        let leftGroup = manual.apply(leaveGroup, catalog: catalog)
        #expect(leftGroup)
        let afterLeavingGroup = model.sharedEntries(manual)
        #expect(IOSPaneLinkedTabs.insertionLine(for: x, from: beforeLeavingGroup, to: afterLeavingGroup, expandedGroup: pane) == .after(.group(pane)))

        var collapsed = SessionTabLayout(order: catalog, groups: [a: group, b: group], revision: 1)
        let beforeCollapsedMove = model.sharedEntries(collapsed)
        let leaveCollapsed = try #require(model.sharedMove(a, before: nil, layout: collapsed))
        let leftCollapsed = collapsed.apply(leaveCollapsed, catalog: catalog)
        #expect(leftCollapsed)
        let afterCollapsedMove = model.sharedEntries(collapsed)
        #expect(IOSPaneLinkedTabs.insertionLine(for: a, from: beforeCollapsedMove, to: afterCollapsedMove, expandedGroup: nil) == .after(.group(.manual(group))))
    }

    @Test("First shared edit starts from visible saved order, and a source group keeps its swipe boundary")
    func sharedOrderAndSwipeBoundary() {
        let a = FileBrowserTab(path: "/A")
        let b = FileBrowserTab(path: "/B")
        let left = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/Left"))
        let right = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/Right"))
        let other = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/Other"))
        let model = IOSPaneLinkedTabs(files: [a, b, left, right, other], browsers: [], simulators: [], windows: [], storedOrder: [])
        let localOrder: [IOSTopLevelTabID] = [.resource(.file(b.id)), .resource(.file(a.id))]
        let order = model.initialSharedOrder(topLevelOrder: localOrder)
        #expect(order == [.file(left.id), .file(right.id), .file(other.id)])
        let seed = SessionTabLayout(order: order)
        #expect(Array(model.sharedEntries(seed, topLevelOrder: localOrder).flatMap(\.tabs).prefix(2)) == [.file(b.id), .file(a.id)])

        let shared = SessionTabLayout(order: [.file(right.id), .file(other.id), .file(left.id)], revision: 1)
        #expect(model.adjacentLinkedTab(.file(right.id), direction: 1, layout: shared) == .tab(.file(left.id)))
        #expect(model.adjacentLinkedTab(.file(left.id), direction: 1, layout: shared) == .sourcePane("%1"))
        #expect(model.adjacentLinkedTab(.file(right.id), direction: -1, layout: shared) == .sourcePane("%1"))
    }

    @Test("Shared reorders respect the saved private file slot and a local move can change it")
    func privateFileKeepsItsSlot() throws {
        let a = UUID(), b = UUID()
        let file = FileBrowserTab(path: "/Private")
        let privateTab = SessionTabID.file(file.id)
        let privateSlot = IOSTopLevelTabID.resource(.file(file.id))
        let model = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: windows([a, b]), storedOrder: [])
        let saved: [IOSTopLevelTabID] = [.window(a), privateSlot, .window(b)]
        let host = SessionTabLayout(order: [.window(b), .window(a)], revision: 1)

        let current = model.sharedEntries(host, topLevelOrder: saved)
        #expect(current.flatMap(\.tabs) == [.window(b), privateTab, .window(a)])
        #expect(model.initialSharedOrder(topLevelOrder: saved) == [.window(a), .window(b)])

        let atEnd = try #require(model.movingPrivateTab(privateTab, before: [], layout: host, stored: saved))
        let reordered = model.sharedEntries(host, topLevelOrder: atEnd)
        #expect(reordered.flatMap(\.tabs) == [.window(b), .window(a), privateTab])
        #expect(IOSPaneLinkedTabs.insertionLine(for: privateTab, from: current, to: reordered, expandedGroup: nil) == .after(.tab(.window(a))))

        let move = try #require(model.sharedMove(.window(b), before: nil, layout: host, topLevelOrder: saved))
        var movedHost = host
        let applied = movedHost.apply(move, catalog: host.order)
        #expect(applied)
        let sharedReordered = model.sharedEntries(movedHost, topLevelOrder: saved)
        #expect(sharedReordered.flatMap(\.tabs) == [.window(a), privateTab, .window(b)])
        #expect(IOSPaneLinkedTabs.insertionLine(for: .window(b), from: current, to: sharedReordered, expandedGroup: nil) == .after(.tab(.window(a))))
        let beforeA = try #require(model.movingPrivateTab(privateTab, before: [.window(a)], layout: host, stored: atEnd))
        #expect(model.sharedEntries(host, topLevelOrder: beforeA).flatMap(\.tabs) == [.window(b), privateTab, .window(a)])

        let group = UUID()
        let grouped = SessionTabLayout(order: host.order, groups: [.window(a): group, .window(b): group], revision: 2)
        let beforeGroup = try #require(model.movingPrivateTab(privateTab, before: host.order, layout: grouped, stored: atEnd))
        #expect(model.sharedEntries(grouped, topLevelOrder: beforeGroup).map(\.id) == [.tab(privateTab), .group(.manual(group))])
    }

    @Test("Pane-linked private files keep their saved slots and can be reordered locally")
    func privateSourceGroupSlots() throws {
        let privateFile = FileBrowserTab(path: "/Private", sourcePaneID: "%1")
        let a = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/A"))
        let b = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/B"))
        let files = [privateFile, a, b]
        let p = PaneLinkedTabID.file(privateFile.id)
        let first = PaneLinkedTabID.file(a.id), second = PaneLinkedTabID.file(b.id)
        let model = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: [], storedOrder: [p, first, second])
        let host = SessionTabLayout(order: [first.sessionTabID, second.sessionTabID], revision: 1)

        #expect(model.sharedEntries(host).flatMap(\.tabs) == [p, first, second].map(\.sessionTabID))
        #expect(model.adjacentLinkedTab(p, direction: 1, layout: host) == .tab(first))
        let moved = try #require(model.movingPrivateMember(p.sessionTabID, before: second.sessionTabID, layout: host))
        #expect(moved == [first, p, second])
        let restored = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: [], storedOrder: moved)
        let movedEntries = restored.sharedEntries(host)
        #expect(IOSPaneLinkedTabs.insertionLine(for: p.sessionTabID, from: model.sharedEntries(host), to: movedEntries, expandedGroup: .pane("%1")) == .after(.tab(first.sessionTabID)))
        let swapped = SessionTabLayout(order: [second.sessionTabID, first.sessionTabID], revision: 2)
        let swappedEntries = restored.sharedEntries(swapped)
        #expect(swappedEntries.flatMap(\.tabs) == [second, p, first].map(\.sessionTabID))
        #expect(IOSPaneLinkedTabs.insertionLine(for: first.sessionTabID, from: movedEntries, to: swappedEntries, expandedGroup: .pane("%1")) == .after(.tab(second.sessionTabID)))
        #expect(restored.adjacentLinkedTab(p, direction: 1, layout: swapped) == .tab(first))
    }

    @Test("A shared row drop marks its final slot in the current mixed order", arguments: [false, true])
    func rowDropLineFollowsPrivateFileSlots(privateFileBeforeB: Bool) throws {
        let a = UUID(), b = UUID(), c = UUID()
        let file = FileBrowserTab(path: "/Private")
        let privateTab = SessionTabID.file(file.id)
        let privateSlot = IOSTopLevelTabID.resource(.file(file.id))
        let middle: [IOSTopLevelTabID] = privateFileBeforeB ? [privateSlot, .window(b)] : [.window(b), privateSlot]
        let saved = [.window(a)] + middle + [.window(c)]
        let model = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: windows([a, b, c]), storedOrder: [])
        let catalog = model.initialSharedOrder(topLevelOrder: saved)
        var layout = SessionTabLayout(order: catalog, revision: 1)
        let before = model.sharedEntries(layout, topLevelOrder: saved)
        let original: [SessionTabID] = privateFileBeforeB ? [.window(a), privateTab, .window(b), .window(c)] : [.window(a), .window(b), privateTab, .window(c)]
        #expect(before.flatMap(\.tabs) == original)

        let move = try #require(model.sharedMove(.window(a), before: .window(c), layout: layout, topLevelOrder: saved))
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout, topLevelOrder: saved)
        let expected: [SessionTabID] = privateFileBeforeB ? [.window(b), privateTab, .window(a), .window(c)] : [.window(b), .window(a), privateTab, .window(c)]
        #expect(after.flatMap(\.tabs) == expected)
        #expect(IOSPaneLinkedTabs.insertionLine(for: .window(a), from: before, to: after, expandedGroup: nil) == .after(.tab(.window(b))))
    }

    @Test("The bottom edge moves a shared tab after its target without leaving a manual group")
    func bottomEdgeKeepsManualGroup() throws {
        let windowIDs = (0..<3).map { _ in UUID() }
        let tabs = windowIDs.map(SessionTabID.window)
        let group = UUID()
        let groups = [tabs[0]: group, tabs[1]: group]
        let model = IOSPaneLinkedTabs(files: [], browsers: [], simulators: [], windows: windows(windowIDs), storedOrder: [])
        var layout = SessionTabLayout(order: tabs, groups: groups, revision: 1)
        let before = model.sharedEntries(layout)
        let move = try #require(model.sharedMove(tabs[0], before: tabs[1], side: .after, layout: layout))
        #expect(move == .moveToEnd(tabs[0], after: tabs[1], groupMembership: .keep))
        let applied = layout.apply(move, catalog: tabs)
        #expect(applied)
        #expect(layout.groups == groups)
        let after = model.sharedEntries(layout)
        #expect(after.flatMap(\.tabs) == [tabs[1], tabs[0], tabs[2]])
        #expect(IOSPaneLinkedTabs.insertionLine(for: tabs[0], from: before, to: after, expandedGroup: .manual(group)) == .after(.tab(tabs[1])))
    }

    @Test("Leaving a manual group marks the final slot in the current mixed list", arguments: [2, 3])
    func dropLineWhenLeavingManualGroup(memberCount: Int) throws {
        let group = UUID(), trailing = UUID()
        let groupedWindows = (0..<memberCount).map { _ in UUID() }
        let members = groupedWindows.map(SessionTabID.window)
        let source = try #require(members.first)
        let local = FileBrowserTab(path: "/Private")
        let privateTab = SessionTabID.file(local.id)
        let saved = groupedWindows.map(IOSTopLevelTabID.window) + [.resource(.file(local.id)), .window(trailing)]
        let model = IOSPaneLinkedTabs(files: [local], browsers: [], simulators: [], windows: windows(groupedWindows + [trailing]), storedOrder: [])
        let catalog = model.initialSharedOrder(topLevelOrder: saved)
        let groups = Dictionary(uniqueKeysWithValues: members.map { ($0, group) })
        var layout = SessionTabLayout(order: catalog, groups: groups, revision: 1)
        let before = model.sharedEntries(layout, topLevelOrder: saved)
        #expect(before.map(\.id) == [.group(.manual(group)), .tab(privateTab), .tab(.window(trailing))])

        let move = try #require(model.sharedMove(source, before: nil, layout: layout, topLevelOrder: saved))
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout, topLevelOrder: saved)
        #expect(after.flatMap(\.tabs) == Array(members.dropFirst()) + [.window(trailing), privateTab, source])
        #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: .manual(group)) == .after(.tab(.window(trailing))))
    }

    @Test("Restoring an automatic group leaves the insertion line at the top-level slot", arguments: [0, 2])
    func dropLineWhenDissolvingAGroupWithLinkedFiles(otherWindowCount: Int) throws {
        let window = UUID(), group = UUID()
        let file = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%0", initialDirectory: "/Project"))
        let otherWindows = (0..<otherWindowCount).map { _ in UUID() }
        let otherTabs = otherWindows.map(SessionTabID.window)
        let model = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: windows([window] + otherWindows), storedOrder: [])
        let source = SessionTabID.window(window)
        let fileTab = SessionTabID.file(file.id)
        let manual = SessionTabGroup.manual(group)
        let catalog = model.initialSharedOrder(topLevelOrder: [])
        var layout = SessionTabLayout(order: [source, fileTab] + otherTabs, groups: [source: group, fileTab: group], revision: 1)
        let before = model.sharedEntries(layout)
        let otherRows = otherTabs.map(IOSPaneLinkedTabs.RowID.tab)
        #expect(before.map(\.id) == [.group(manual)] + otherRows)

        let move = try #require(model.sharedMove(source, before: nil, layout: layout))
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout)
        #expect(after.map(\.id) == otherRows + [.tab(source), .group(.pane("%0"))])
        let expected = otherRows.last.map(IOSPaneLinkedTabs.InsertionLine.after) ?? .before(.group(manual))
        #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: manual) == expected)
        #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: nil) == expected)
    }

    @Test("Dropping into an expanded automatic group counts its original members", arguments: [false, true])
    func dropLineWhenRestoringTwoLinkedMembers(originalMemberFirst: Bool) throws {
        let window = UUID(), group = UUID()
        let files = ["X", "Y", "R"].map { FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%0", initialDirectory: "/\($0)")) }
        let x = SessionTabID.file(files[0].id), y = SessionTabID.file(files[1].id), r = SessionTabID.file(files[2].id)
        let model = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: windows([window]), storedOrder: [])
        let pane = SessionTabGroup.pane("%0")
        let fileOrder = originalMemberFirst ? [r, x, y] : [x, y, r]
        let catalog = model.initialSharedOrder(topLevelOrder: [])
        var layout = SessionTabLayout(order: [.window(window)] + fileOrder, groups: [x: group, y: group], revision: 1)
        let before = model.sharedEntries(layout)
        #expect(before.map(\.id) == [.tab(.window(window)), .group(.manual(group)), .group(pane)])
        #expect(before.last?.tabs == [r])

        let move = try #require(model.sharedMove(x, before: nil, layout: layout))
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout)
        #expect(after.map(\.id) == [.tab(.window(window)), .group(pane)])
        #expect(after.last?.tabs == (originalMemberFirst ? [r, y, x] : [y, x, r]))
        let expected: IOSPaneLinkedTabs.InsertionLine = originalMemberFirst ? .after(.tab(r)) : .after(.group(pane))
        #expect(IOSPaneLinkedTabs.insertionLine(for: x, from: before, to: after, expandedGroup: pane) == expected)
    }

    @Test("A restored automatic group uses surviving rows to mark its pane order", arguments: [["R", "X", "Y"], ["X", "Y", "R"], ["Y", "X"]])
    func dropLineWhenRestoringSeparatePaneGroups(panes: [String]) throws {
        let windowIDs = panes.map { _ in UUID() }
        let terminals = windowIDs.map(SessionTabID.window)
        let paneIDs = panes.indices.map { "%\($0)" }
        let files = paneIDs.map { FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: $0, initialDirectory: "/Project")) }
        let tabs = files.map { SessionTabID.file($0.id) }
        let xIndex = try #require(panes.firstIndex(of: "X"))
        let yIndex = try #require(panes.firstIndex(of: "Y"))
        let source = tabs[xIndex], group = UUID()
        let model = IOSPaneLinkedTabs(files: files, browsers: [], simulators: [], windows: windows(windowIDs), storedOrder: [])
        let catalog = model.initialSharedOrder(topLevelOrder: [])
        var layout = SessionTabLayout(order: terminals + tabs, groups: [source: group, tabs[yIndex]: group], revision: 1)
        let before = model.sharedEntries(layout)
        #expect(before.compactMap(\.sourcePaneID) == paneIDs.enumerated().filter { $0.offset != xIndex && $0.offset != yIndex }.map(\.element))

        let move = try #require(model.sharedMove(source, before: nil, layout: layout))
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        let after = model.sharedEntries(layout)
        #expect(after.compactMap(\.sourcePaneID) == paneIDs)

        if let rIndex = panes.firstIndex(of: "R") {
            let retained = SessionTabGroup.pane(paneIDs[rIndex])
            let expected: IOSPaneLinkedTabs.InsertionLine = xIndex < rIndex ? .before(.group(retained)) : .after(.group(retained))
            let expanded: IOSPaneLinkedTabs.InsertionLine = xIndex < rIndex ? expected : .after(.tab(tabs[rIndex]))
            #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: nil) == expected)
            #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: retained) == expanded)
        } else {
            let lastTerminal = try #require(terminals.last)
            #expect(IOSPaneLinkedTabs.insertionLine(for: source, from: before, to: after, expandedGroup: .manual(group)) == .after(.tab(lastTerminal)))
        }
    }

    @Test("A group of source-linked tabs is a visible drop target for a private row")
    func privateFileCanMoveBeforeLinkedManualGroup() throws {
        let local = FileBrowserTab(path: "/Private")
        let a = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/A"))
        let b = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%2", initialDirectory: "/B"))
        let window = UUID(), group = UUID()
        let model = IOSPaneLinkedTabs(files: [local, a, b], browsers: [], simulators: [], windows: windows([window]), storedOrder: [])
        let privateTab = SessionTabID.file(local.id)
        let members: [SessionTabID] = [.file(a.id), .file(b.id)]
        let layout = SessionTabLayout(order: [.window(window)] + members, groups: [members[0]: group, members[1]: group], revision: 1)
        let saved: [IOSTopLevelTabID] = [.window(window), .resource(.file(local.id))]
        #expect(model.sharedEntries(layout, topLevelOrder: saved).map(\.id) == [.tab(.window(window)), .group(.manual(group)), .tab(privateTab)])

        let moved = try #require(model.movingPrivateTab(privateTab, before: members, layout: layout, stored: saved))
        #expect(model.sharedEntries(layout, topLevelOrder: moved).map(\.id) == [.tab(.window(window)), .tab(privateTab), .group(.manual(group))])
    }

    @Test("Dropping a shared tab before a private row can change just the local placement")
    func sharedTabCanPassAPrivateRowLocally() throws {
        let a = UUID(), b = UUID()
        let file = FileBrowserTab(path: "/Private")
        let privateTab = SessionTabID.file(file.id)
        let privateSlot = IOSTopLevelTabID.resource(.file(file.id))
        let model = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: windows([a, b]), storedOrder: [])
        let host = SessionTabLayout(order: [.window(a), .window(b)], revision: 1)
        let saved: [IOSTopLevelTabID] = [.window(a), privateSlot, .window(b)]

        let moved = try #require(model.movingPrivateTab(.window(b), before: [privateTab], layout: host, stored: saved))
        #expect(model.sharedEntries(host, topLevelOrder: moved).flatMap(\.tabs) == [.window(a), .window(b), privateTab])
        #expect(model.movingPrivateTab(.window(b), before: [privateTab], layout: host, stored: [privateSlot, .window(a), .window(b)]) == nil)
    }

    @Test("Swipe follows the visible source group after a child is moved to a manual group")
    func swipeSkipsManuallyRegroupedChild() {
        let a = FileBrowserTab(path: "/A", sourcePaneID: "%1")
        let b = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: "%1", initialDirectory: "/B"))
        let c = FileBrowserTab(path: "/C", sourcePaneID: "%1")
        let other = FileBrowserTab(hostTab: .init(sessionName: "work", initialDirectory: "/Other"))
        let model = IOSPaneLinkedTabs(files: [a, b, c, other], browsers: [], simulators: [], windows: [], storedOrder: [])
        let group = UUID()
        let shared = SessionTabLayout(
            order: [.file(a.id), .file(b.id), .file(c.id), .file(other.id)],
            groups: [.file(b.id): group, .file(other.id): group],
            revision: 1
        )

        #expect(model.adjacentLinkedTab(.file(a.id), direction: 1, layout: shared) == .tab(.file(c.id)))
        #expect(model.adjacentLinkedTab(.file(c.id), direction: 1, layout: shared) == .sourcePane("%1"))
        #expect(model.adjacentLinkedTab(.file(a.id), direction: -1, layout: shared) == .sourcePane("%1"))
    }

    @Test("Independent Files, Browser and Simulator follow the mixed top-level order")
    func independentResourceOrder() throws {
        let file = FileBrowserTab(path: "/project")
        let child = FileBrowserTab(path: "/child", sourcePaneID: "%1")
        let browser = RemoteBrowserTab(id: UUID(), sessionName: "work", title: "Web", url: "about:blank", isLoading: false, isAgentOwned: false)
        let simulator = RemoteSimulatorTab(id: UUID(), sessionName: "work", title: "Phone", runtime: "iOS", isPrimary: true)
        let windows = TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", paneIndex: 0, windowName: "dev"),
        ])
        let window = try #require(windows.first)
        let order: [IOSTopLevelTabID] = [
            .resource(.browser(browser.id)), IOSTopLevelTabID(window: window),
            .resource(.simulator(simulator.id)), .resource(.file(file.id)),
        ]
        let layout = IOSPaneLinkedTabs(files: [file, child], browsers: [browser], simulators: [simulator], windows: windows, storedOrder: [])

        #expect(layout.topLevel(stored: order) == order)
        #expect(!layout.topLevel(stored: order).contains(.resource(.file(child.id))))
    }

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

    private func windows(_ ids: [UUID]) -> [TmuxWindow] {
        let session = UUID()
        return TmuxWindow.groupPanes(ids.enumerated().map { index, id in
            PaneState(
                paneId: "%\(index)", sessionName: "work", windowIndex: index, tmuxWindowId: "@\(index)", paneIndex: 0,
                workspaceIdentity: .init(serverID: "server", sessionID: session, windowID: id, paneID: UUID())
            )
        })
    }
}
