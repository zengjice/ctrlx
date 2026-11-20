import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct IOSPaneLinkedTabsTests {
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
        let applied = layout.apply(move, catalog: catalog)
        #expect(applied)
        #expect(model.sharedEntries(layout).flatMap(\.tabs) == [b, a, x, y, z])

        let group = UUID()
        let manual = SessionTabLayout(order: catalog, groups: [x: group, z: group], revision: 1)
        #expect(model.sharedMove(x, before: b, layout: manual) == .move(x, before: b))
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

        #expect(model.sharedEntries(host, topLevelOrder: saved).flatMap(\.tabs) == [.window(b), privateTab, .window(a)])
        #expect(model.initialSharedOrder(topLevelOrder: saved) == [.window(a), .window(b)])

        let atEnd = try #require(model.movingPrivateTab(privateTab, before: [], layout: host, stored: saved))
        #expect(model.sharedEntries(host, topLevelOrder: atEnd).flatMap(\.tabs) == [.window(b), .window(a), privateTab])
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
        let swapped = SessionTabLayout(order: [second.sessionTabID, first.sessionTabID], revision: 2)
        #expect(restored.sharedEntries(swapped).flatMap(\.tabs) == [second, p, first].map(\.sessionTabID))
        #expect(restored.adjacentLinkedTab(p, direction: 1, layout: swapped) == .tab(first))
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
