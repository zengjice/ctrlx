import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite
@MainActor
struct WorkbenchTabDropTests {
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
