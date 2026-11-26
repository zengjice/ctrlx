import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct DetachedTerminalWindowsTests {
    @Test("Files catalog refresh leaves returning left selection for scene reconciliation", arguments: [false, true])
    func filesCatalogPreservesLeftRestoration(explicitSelection: Bool) {
        let manager = DetachedTerminalWindows()
        let tabs = manager.mainTabs.tabs(hostID: "viewer", session: "work")
        let ids = ["@1", "@2", "@3", "@4"]
        let layout = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
        )
        tabs.applySharedTerminalLayout(layout, liveWindowIds: Set(ids))
        tabs.projectRemoteTerminalLayout(layout, liveWindowIDs: Set(ids.dropFirst()), sessionWindowIDs: Set(ids))
        if explicitSelection {
            tabs.recordRemoteLeftTerminalSelection("@2")
        }

        manager.syncFileTabs(hostID: "viewer", descriptors: [], sessionWindows: ["work": ids], sharedLayout: { _ in layout })

        #expect(tabs.needsSharedTerminalVisibilityProjection(layout, liveWindowIDs: Set(ids), sessionWindowIDs: Set(ids)))
        let restored = tabs.projectRemoteTerminalLayout(layout, liveWindowIDs: Set(ids), sessionWindowIDs: Set(ids))
        #expect(restored == (explicitSelection ? nil : "@1"))
        #expect(tabs.explicitRemoteLeftTerminalID == (explicitSelection ? "@2" : nil))
    }

    @Test("Legacy Files reuse repairs source selection before presentation refresh", arguments: [false, true])
    func legacyFilesClaimRepairsSource(selectedRight: Bool) throws {
        let manager = DetachedTerminalWindows()
        let ids = ["@1", "@2", "@3", "@4"]
        let file = HostFileTab(sessionName: "work", windowID: "@4", sourcePaneID: "%3", initialDirectory: "/host")
        #expect(file.resourceSessionID == nil)
        manager.syncFileTabs(hostID: "viewer", descriptors: [file], sessionWindows: ["work": ids])
        let source = manager.mainTabs.tabs(hostID: "viewer", session: "work")
        let model = try #require(source.directoryTabs[file.id])
        model.navigate("/host/child")
        let target = try #require(DetachedTerminalTarget(hostID: "viewer", windowID: "@4"))
        let workspace = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let shared = SharedTerminalLayout(
            leftWindowId: "@1", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
        )
        let visible = Array(ids.dropLast())
        source.applySharedTerminalLayout(shared, liveWindowIds: Set(visible))
        let other = BrowserTab(url: URL(fileURLWithPath: "/tmp/kept"))
        source.openBrowserTabs.append(other)
        source.rightSide.formUnion([.file(file.id), .browser(other.id)])
        source.selectedRight = selectedRight ? .file(file.id) : .browser(other.id)
        let revision = manager.presentationRevision
        var notifications = 0
        manager.mainTabs.onResourceTransferred = { host, session, wasSelectedRight in
            #expect(host == "viewer" && session == "work")
            #expect(wasSelectedRight == selectedRight)
            #expect(source.selectedRight == (selectedRight ? nil : .browser(other.id)))
            #expect(manager.presentationRevision == revision)
            notifications += 1
            source.reconcileRemoteRightPaneSelection(
                sharedLayout: shared, sessionWindowIDs: ids, visibleWindowIDs: visible,
                userInitiated: true, recordSelection: wasSelectedRight
            )
        }

        manager.claimFile(file.id, hostID: "viewer", session: "work", workspaceID: workspace.id)

        #expect(notifications == 1)
        #expect(manager.presentationRevision == revision + 1)
        #expect(source.selectedRight == (selectedRight ? .window("@3") : .browser(other.id)))
        let request = try #require(source.remoteTerminalLayoutRequest(
            sessionName: "work", sessionWindowIDs: ids, visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: shared
        ))
        #expect(request.selectedRightWindowId == (selectedRight ? "@3" : "@4"))
        let destination = workspace.tabs.tabs(hostID: "viewer", session: "work")
        #expect(destination.directoryTabs[file.id] === model)
        #expect(model.path == "/host/child" && model.hostTab == file)
        manager.syncFileTabs(hostID: "viewer", descriptors: [file], sessionWindows: ["work": ids])
        manager.claimFile(file.id, hostID: "viewer", session: "work", workspaceID: workspace.id)
        #expect(notifications == 1)
        #expect(destination.directoryTabs[file.id] === model)
    }

    @Test("Remote Files removal projects the main layout without changing detached splits", arguments: [false, true], [false, true])
    func remoteFilesRemovalKeepsPrivatePlacement(detached: Bool, layoutAppliedFirst: Bool) throws {
        let manager = DetachedTerminalWindows()
        let ids = ["@1", "@2", "@3", "@4"]
        let workspace = detached ? try #require(manager.detach(
            #require(DetachedTerminalTarget(hostID: "viewer", windowID: "@1")), position: nil, session: { _ in "work" }
        )) : nil
        let visible = detached ? Array(ids.dropFirst()) : ids
        if let workspace {
            let native = workspace.tabs.tabs(hostID: "viewer", session: "work")
            let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/native"))
            native.openBrowserTabs.append(browser)
            native.selectedBrowserTabId = browser.id
            native.rightSide = [.window("@1")]
            native.selectedRight = .window("@1")
        }
        let files = HostFileTab(sessionName: "work", initialDirectory: "/tmp")
        manager.syncFileTabs(hostID: "viewer", descriptors: [files], sessionWindows: ["work": ids])
        let tabs = manager.mainTabs.tabs(hostID: "viewer", session: "work")
        let other = BrowserTab(url: URL(fileURLWithPath: "/tmp/kept"))
        tabs.openBrowserTabs.append(other)
        tabs.selectedFileTabId = files.id
        tabs.applySharedTerminalLayout(
            .init(leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids),
            liveWindowIds: Set(visible), sessionWindowIds: Set(ids)
        )
        if !detached {
            tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
        }
        tabs.rightSide.insert(.browser(other.id))
        tabs.selectedRight = .browser(other.id)
        let latest = SharedTerminalLayout(
            leftWindowId: "@2", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4", revision: 2, sessionWindowIds: ids
        )
        if layoutAppliedFirst {
            tabs.applySharedTerminalLayout(latest, liveWindowIds: Set(visible), sessionWindowIds: Set(ids))
        }
        manager.syncFileTabs(hostID: "viewer", descriptors: [], sessionWindows: ["work": ids], sharedLayout: { _ in latest })
        #expect(tabs.rightSide.contains(.browser(other.id)))
        #expect(tabs.selectedRight == .browser(other.id))
        #expect(!tabs.rightSide.contains(.window("@2")))
        let saved = LayoutSnapshotMapper.viewerPrivateLayout(from: LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil) { ids.firstIndex(of: $0) })
        #expect(saved.rightSide.contains(.browser(id: other.id)))
        if let workspace {
            let native = workspace.tabs.tabs(hostID: "viewer", session: "work")
            #expect(native.rightSideWindowIds == ["@1"])
            #expect(native.selectedRight == .window("@1"))
        }
    }

    @Test(arguments: [TabDragPayload.git, .fileExplorer])
    func closingHostFilesKeepsRemainingLocalRightContent(fallback: TabDragPayload) {
        let manager = DetachedTerminalWindows()
        let file = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        manager.syncFileTabs(hostID: nil, descriptors: [file], sessionWindows: ["work": ["@1"]])
        let tabs = manager.mainTabs.tabs(hostID: nil, session: "work")
        if fallback == .git {
            tabs.selectLeftGit()
            _ = tabs.selectLeftTerminalWindow("@1")
        }
        tabs.rightSide = [.file(file.id), fallback]
        tabs.selectedRight = .file(file.id)

        manager.syncFileTabs(hostID: nil, descriptors: [], sessionWindows: ["work": ["@1"]])

        #expect(tabs.rightSide == [fallback])
        #expect(tabs.selectedRight == fallback)
    }

    @Test(arguments: [nil, "viewer-host"] as [String?], [false, true])
    func hostCloseFinishesOnceInTheOwningScene(host: String?, detached: Bool) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let workspace = detached ? manager.detach(target, position: nil, session: { _ in "work" }) : nil
        let file = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        let windows = ["work": ["@1", "@2"]]
        manager.syncFileTabs(hostID: host, descriptors: [file], sessionWindows: windows)
        let store = try #require(manager.store(for: workspace?.id))
        let tabs = store.tabs(hostID: host, session: "work")
        tabs.openFileTabs[0].origin = .terminalWindow("work:2")
        tabs.selectedFileTabId = file.id
        var completions: [SessionFileTabsState.FileTabCloseResult] = []
        #expect(tabs.beginClosingHostFileTab(file.id) { completions.append($0) })
        #expect(!tabs.beginClosingHostFileTab(file.id) { _ in Issue.record("Duplicate close replaced its completion") })

        manager.syncFileTabs(hostID: host, descriptors: [file], sessionWindows: windows)
        #expect(completions.isEmpty)
        // Any scene may observe the catalog first, before the command response.
        manager.syncFileTabs(hostID: host, descriptors: [], sessionWindows: windows)
        manager.syncFileTabs(hostID: host, descriptors: [], sessionWindows: windows)
        tabs.cancelClosingHostFileTab(file.id)

        #expect(completions == [.init(wasSelectedLeft: true, wasSelectedRight: false, origin: .terminalWindow("work:2"))])
        #expect(tabs.openFileTabs.isEmpty && tabs.selectedFileTabId == nil)
    }

    @Test(arguments: ["otherFile", "git", "terminal", "right", "cancelled", "moved", "passive"])
    func hostCloseCannotReturnFromAnUnselectedOrMovedTab(action: String) throws {
        let manager = DetachedTerminalWindows()
        let file = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        let windows = ["work": ["@1"]]
        manager.syncFileTabs(hostID: nil, descriptors: [file], sessionWindows: windows)
        let tabs = manager.mainTabs.tabs(hostID: nil, session: "work")
        tabs.openFileTabs[0].origin = .terminalWindow("work:1")
        tabs.selectedFileTabId = file.id
        var completions: [SessionFileTabsState.FileTabCloseResult] = []
        if action != "passive" {
            #expect(tabs.beginClosingHostFileTab(file.id) { completions.append($0) })
        }
        switch action {
        case "otherFile":
            let other = OpenFileTab(path: "/other.md", directoryPath: "/")
            tabs.openFileTabs.append(other)
            tabs.selectedFileTabId = other.id
        case "git": tabs.selectLeftGit()
        case "terminal": _ = tabs.selectLeftTerminalWindow("@1")
        case "right":
            tabs.selectedFileTabId = nil
            tabs.rightSide = [.file(file.id)]
            tabs.selectedRight = .file(file.id)
        case "cancelled": tabs.cancelClosingHostFileTab(file.id)
        case "moved":
            let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
            let workspace = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
            manager.claimFile(file.id, hostID: nil, session: "work", workspaceID: workspace.id)
        default: break
        }
        manager.syncFileTabs(hostID: nil, descriptors: [], sessionWindows: windows)
        if ["cancelled", "moved", "passive"].contains(action) {
            #expect(completions.isEmpty)
        } else {
            #expect(completions == [.init(wasSelectedLeft: false, wasSelectedRight: action == "right", origin: nil)])
        }
        if action == "git" {
            #expect(tabs.isGitSelected)
        }
        if action == "otherFile" {
            #expect(tabs.selectedFileTabId == tabs.openFileTabs.first?.id)
        }
    }

    @Test
    func closingSharedFilesRepairsRightSelectionWithoutSelectingOnCatalogArrival() {
        let manager = DetachedTerminalWindows()
        let first = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        let second = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", isPrimary: false, initialDirectory: "/host")
        manager.syncFileTabs(hostID: nil, descriptors: [first, second], sessionWindows: ["work": ["@1"]])
        let tabs = manager.mainTabs.tabs(hostID: nil, session: "work")
        #expect(tabs.selectedFileTabId == nil && tabs.selectedRight == nil)
        tabs.rightSide = [.file(first.id), .file(second.id)]
        tabs.selectedRight = .file(first.id)
        manager.syncFileTabs(hostID: nil, descriptors: [second], sessionWindows: ["work": ["@1"]])
        #expect(tabs.selectedRight == .file(second.id))
        #expect(tabs.selectedFileTabId == nil)
    }

    @Test(arguments: [nil, "host"] as [String?])
    func hostFilesCatalogHasOnePresentationAcrossNativeWindows(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let detached = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        var tab = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        let extra = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", isPrimary: false, initialDirectory: "/host")
        let windows = ["work": ["@1", "@2"]]
        manager.syncFileTabs(hostID: host, descriptors: [tab, extra], sessionWindows: windows)
        let detachedTabs = detached.tabs.tabs(hostID: host, session: "work")
        let model = try #require(detachedTabs.directoryTabs[tab.id])
        model.navigate("/host/child")
        #expect(detachedTabs.selectedFileTabId == nil)
        for _ in 0..<3 {
            manager.syncFileTabs(hostID: host, descriptors: [tab, extra], sessionWindows: windows)
        }
        #expect(detachedTabs.openFileTabs.count == 2)
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        #expect(main.openFileTabs.isEmpty)
        manager.claimFile(tab.id, hostID: host, session: "work", workspaceID: nil)
        manager.syncFileTabs(hostID: host, descriptors: [tab, extra], sessionWindows: windows)
        #expect(main.directoryTabs[tab.id] === model)
        #expect(detachedTabs.directoryTabs[tab.id] == nil)
        tab.windowID = "@2"
        manager.syncFileTabs(hostID: host, descriptors: [tab, extra], sessionWindows: windows)
        #expect(main.directoryTabs[tab.id] === model && model.path == "/host/child")
        main.rightSide = [.file(tab.id)]
        main.selectedRight = .file(tab.id)
        manager.syncFileTabs(hostID: host, descriptors: [extra], sessionWindows: windows)
        #expect(main.openFileTabs.isEmpty && main.selectedRight == nil)
        #expect(detachedTabs.openFileTabs.map(\.id) == [extra.id])
    }

    @Test(arguments: [nil, "viewer-host"] as [String?], [false, true])
    func claimingHostFilesNotifiesSourceSplitRepair(host: String?, fromDetached: Bool) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let workspace = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let sourceID = fromDetached ? workspace.id : nil
        let destinationID = fromDetached ? nil : workspace.id
        let sourceWindowID = fromDetached ? "@1" : "@2"
        let file = HostFileTab(sessionName: "work", windowID: sourceWindowID, sourcePaneID: "%1", initialDirectory: "/host")
        let windows = ["work": ["@1", "@2"]]
        manager.syncFileTabs(hostID: host, descriptors: [file], sessionWindows: windows)
        let source = try #require(manager.store(for: sourceID)).tabs(hostID: host, session: "work")
        let destination = try #require(manager.store(for: destinationID)).tabs(hostID: host, session: "work")
        let model = try #require(source.directoryTabs[file.id])
        model.navigate("/host/child")
        source.selectedFileTabId = file.id
        source.tabOrder = [.file(file.id), .window(sourceWindowID)]
        source.rightSide = [.window(sourceWindowID)]
        source.selectedRight = .window(sourceWindowID)
        let revision = manager.presentationRevision

        manager.claimFile(file.id, hostID: host, session: "work", workspaceID: sourceID)
        #expect(manager.presentationRevision == revision)
        #expect(source.selectedFileTabId == file.id && source.isSplit)

        manager.claimFile(file.id, hostID: host, session: "work", workspaceID: destinationID)

        // MainView reacts to this revision by repairing its own selection and split.
        try #require(manager.presentationRevision == revision + 1)
        #expect(source.directoryTabs.isEmpty && source.openFileTabs.isEmpty && source.selectedFileTabId == nil)
        #expect(destination.directoryTabs[file.id] === model && model.path == "/host/child")
        #expect(source.reconcileRightPaneSelection(sessionWindowIDs: [sourceWindowID], includeLocalTabs: host == nil))
        let selected = WorkspaceTerminalSelection.leftWindowID(
            current: nil, orderedIDs: ["@1", "@2"], activeID: "@1", rightSide: source.rightSideWindowIds,
            owns: { manager.owner(hostID: host, windowID: $0) == sourceID }
        )
        source.repairLeftContent(hasTerminal: selected != nil)
        #expect(selected == sourceWindowID)
        #expect(!source.isSplit && source.selectedRight == nil)
        #expect(manager.workspaces[workspace.id] === workspace)

        manager.syncFileTabs(hostID: host, descriptors: [file], sessionWindows: windows)
        manager.claimFile(file.id, hostID: host, session: "work", workspaceID: destinationID)
        manager.claimFile(UUID(), hostID: host, session: "work", workspaceID: sourceID)
        manager.claimFile(file.id, hostID: host, session: "work", workspaceID: UUID())
        #expect(manager.presentationRevision == revision + 1)
        #expect(destination.openFileTabs.map(\.id) == [file.id])
        #expect(destination.directoryTabs[file.id] === model)
        #expect(source.openFileTabs.isEmpty && !source.isSplit)
    }

    @Test(arguments: [nil, "viewer-host"] as [String?])
    func claimingHostFilesClosesAnEmptySourceWorkbench(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let workspace = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let file = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
        manager.syncFileTabs(hostID: host, descriptors: [file], sessionWindows: ["work": ["@1"]])
        let model = try #require(workspace.tabs.tabs(hostID: host, session: "work").directoryTabs[file.id])
        var closed = false
        workspace.onClose = { closed = true }
        manager.returnToMain(target)
        #expect(workspace.members.isEmpty && !closed)

        manager.claimFile(file.id, hostID: host, session: "work", workspaceID: nil)

        #expect(closed)
        #expect(manager.workspaces[workspace.id] == nil)
        #expect(manager.mainTabs.tabs(hostID: host, session: "work").directoryTabs[file.id] === model)
    }

    @Test(arguments: [nil, "host"] as [String?])
    func renameMigratesAllOwnersOnceAndKeepsHostAndSessionIsolation(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let sourceTarget = try #require(DetachedTerminalTarget(hostID: host, windowID: "@0"))
        let otherSessionTarget = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let foreignTarget = try #require(DetachedTerminalTarget(hostID: "foreign", windowID: "@0"))
        let source = try #require(manager.detach(sourceTarget, position: nil, session: { _ in "old" }))
        let otherSession = try #require(manager.detach(otherSessionTarget, position: nil, session: { _ in "other" }))
        let foreign = try #require(manager.detach(foreignTarget, position: nil, session: { _ in "old" }))
        let sourceTabs = source.tabs.tabs(hostID: host, session: "old")
        let browser = BrowserTab(url: URL(staticString: "about:blank"), originWindowId: "@0")
        sourceTabs.openBrowserTabs = [browser]
        #expect(manager.transfer(
            .init(workspaceID: source.id, hostID: host, sessionName: "old", tab: .browser(browser.id)),
            to: nil, session: { _ in "old" }
        ))
        let main = manager.mainTabs.tabs(hostID: host, session: "old")
        main.selectedBrowserTabId = browser.id
        let unrelatedSession = otherSession.tabs.tabs(hostID: host, session: "other")
        let unrelatedHost = foreign.tabs.tabs(hostID: "foreign", session: "old")
        let unrelatedMain = manager.mainTabs.tabs(hostID: "foreign", session: "old")
        for _ in 0..<3 {
            manager.renameSession(hostID: host, from: "old", to: "new", windowIDs: ["old:0": "new:0"])
            #expect(manager.mainTabs.existing(hostID: host, session: "new") === main)
            #expect(manager.mainTabs.existing(hostID: host, session: "old") == nil)
            #expect(source.tabs.existing(hostID: host, session: "new") === sourceTabs)
            #expect(source.tabs.existing(hostID: host, session: "old") == nil)
            #expect(source.sessionName == "new")
            #expect(manager.browserOwner(hostID: host, session: "new", id: browser.id, windowID: "@0") == nil)
            #expect(main.selectedBrowserTabId == browser.id)
            #expect(otherSession.sessionName == "other")
            #expect(otherSession.tabs.existing(hostID: host, session: "other") === unrelatedSession)
            #expect(foreign.sessionName == "old")
            #expect(foreign.tabs.existing(hostID: "foreign", session: "old") === unrelatedHost)
            #expect(manager.mainTabs.existing(hostID: "foreign", session: "old") === unrelatedMain)
        }
    }

    @Test
    func multipleTerminalsCanMoveBothWaysOnlyWithinTheirHostAndSession() throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let b = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        let foreign = try #require(DetachedTerminalTarget(hostID: "remote", windowID: "@2"))
        let otherSession = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@3"))
        let session: (DetachedTerminalTarget) -> String? = { $0 == otherSession ? "other" : "work" }
        manager.reserve(a)
        let group = try #require(manager.workspace(containing: a))
        #expect(manager.merge(b, into: group.id, session: session))
        #expect(group.members == [a, b])
        #expect(!manager.merge(foreign, into: group.id, session: session))
        #expect(!manager.merge(otherSession, into: group.id, session: session))
        #expect(manager.focus(hostID: nil, windowID: "@1"))
        #expect(group.selection == .window("@1"))
        let drag = WorkbenchTabDrag(workspaceID: group.id, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(manager.transfer(drag, to: nil, session: session))
        #expect(group.members == [b])
        #expect(manager.owner(hostID: nil, windowID: "@1") == nil)
        // The scene's original terminal can detach again without aliasing the old scene.
        #expect(manager.reserve(a))
        #expect(manager.workspace(containing: a)?.id != group.id)
    }

    @Test("Returning a terminal after Git uses the shared order of the destination", arguments: [false, true])
    func returningTerminalToPrivateLane(alreadyOrdered: Bool) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let session: (DetachedTerminalTarget) -> String? = { _ in "work" }
        let detached = try #require(manager.detach(target, position: nil, session: session))
        let tabs = manager.mainTabs.tabs(hostID: nil, session: "work")
        let a = TabDragPayload.window("@1"), b = TabDragPayload.window("@2")
        let aID = SessionTabID.window(UUID()), bID = SessionTabID.window(UUID())
        let ids = [a: aID, b: bID]
        let catalog = [aID, bID]
        var layout = SessionTabLayout(order: alreadyOrdered ? [bID, aID] : catalog, revision: 1)
        tabs.tabOrder = [b, .git]
        tabs.rightSide = [.git]
        var edits = 0
        let shared = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, windows, _, confirm in
            edits += 1
            #expect(edit == .moveToEnd(aID, after: bID, groupMembership: .leave))
            #expect(windows == [bID, aID])
            let applied = layout.apply(edit, catalog: catalog)
            #expect(applied)
            confirm()
        }
        let context = WorkbenchTabContext(
            workspaceID: nil, hostID: nil, sessionName: "work", onRejected: { },
            canTransfer: { manager.canTransfer($0, to: nil, session: session) },
            receive: { drag, placement, right in
                shared.drop(drag.tab, at: placement, order: tabs.tabOrder) {
                    let transferred = manager.transfer(drag, to: nil, session: session)
                    #expect(transferred)
                    tabs.recordTabDrop(drag.tab, at: placement)
                    #expect(right)
                    tabs.rightSide.insert(drag.tab)
                }
            }
        )
        let drag = WorkbenchTabDrag(workspaceID: detached.id, hostID: nil, sessionName: "work", tab: a)
        #expect(context.drop(drag, at: .end([.git]), rightSide: true) { _ in false })

        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: [], layout: .init(ids: ids, layout: layout))
        #expect(edits == (alreadyOrdered ? 0 : 1))
        #expect(displayed.filter(tabs.rightSide.contains) == [.git, a])
        #expect(manager.owner(hostID: nil, windowID: "@1") == nil)
    }

    @Test("A returning shared Files tab previews the dissolution of its source group", arguments: [false, true], [nil, 1, 3] as [Int?])
    func returningSharedFilePreviewsGroupRemoval(atEnd: Bool, sourcePane: Int?) throws {
        let manager = DetachedTerminalWindows()
        let linked = HostFileTab(sessionName: "work", windowID: "@2", sourcePaneID: "%2", initialDirectory: "/linked")
        let returning = HostFileTab(
            sessionName: "work", windowID: sourcePane.map { "@\($0)" }, sourcePaneID: sourcePane.map { "%\($0)" }, initialDirectory: "/returning"
        )
        let session: (DetachedTerminalTarget) -> String? = { _ in "work" }
        manager.syncFileTabs(hostID: nil, descriptors: [linked, returning], sessionWindows: ["work": ["@1", "@2", "@3"]])
        let tabs = manager.mainTabs.tabs(hostID: nil, session: "work")
        let x = TabDragPayload.file(linked.id), z = TabDragPayload.file(returning.id)
        tabs.tabOrder = [x, z]
        let detached = try #require(manager.detach(
            .init(workspaceID: nil, hostID: nil, sessionName: "work", tab: z),
            anchor: nil, position: nil, session: session
        ))
        let xID = SessionTabID.file(linked.id), zID = SessionTabID.file(returning.id)
        let group = UUID()
        let catalog = [xID, zID]
        var layout = SessionTabLayout(order: catalog, groups: [xID: group, zID: group], revision: 1)
        let destination = SharedWorkbenchTabLayout(snapshot: .init(ids: [x: xID], layout: layout)) { _, _, _, _, _ in
            Issue.record("A hover sent a Host edit")
        }
        tabs.sharedManualTabGroups = destination.snapshot.groups
        detached.tabs.tabs(hostID: nil, session: "work").sharedManualTabGroups = [z: group]
        func sourceTabs(_ drag: WorkbenchTabDrag) -> SessionFileTabsState? {
            manager.store(for: drag.workspaceID)?.existing(hostID: drag.hostID, session: drag.sessionName)
        }
        let context = WorkbenchTabContext(
            workspaceID: nil, hostID: nil, sessionName: "work", onRejected: { },
            sharedTabLayout: destination,
            sourcePaneGroup: { sourceTabs($0)?.groupID(for: $0.tab)?.paneID },
            sourcePaneID: { sourceTabs($0)?.sourcePaneID(for: $0.tab) },
            incomingSharedTabID: manager.sharedResourceTabID(for:),
            canTransfer: { manager.canTransfer($0, to: nil, session: session) },
            receive: { drag, placement, _ in
                guard let id = manager.sharedResourceTabID(for: drag) else { return false }
                let ids = [x: xID, z: id]
                let incoming = SharedWorkbenchTabLayout(snapshot: .init(ids: ids, layout: layout)) { edit, _, _, _, confirm in
                    let applied = layout.apply(edit, catalog: catalog)
                    #expect(applied)
                    tabs.sharedManualTabGroups = SharedWorkbenchTabLayout.Snapshot(ids: ids, layout: layout).groups
                    confirm()
                }
                return incoming.drop(drag.tab, at: placement, order: tabs.tabOrder) {
                    let transferred = manager.transfer(drag, to: nil, session: session)
                    #expect(transferred)
                    tabs.recordTabDrop(drag.tab, at: placement)
                }
            }
        )
        let drag = WorkbenchTabDrag(workspaceID: detached.id, hostID: nil, sessionName: "work", tab: z)
        let placement = atEnd ? WorkbenchTabDropPlacement.end([x]) : .after(x)
        let panes = (1...3).map { index in
            PaneState(paneId: "%\(index)", sessionName: "work", windowIndex: index, tmuxWindowId: "@\(index)", paneIndex: 0)
        }
        let hover = try #require(context.hover(drag, at: placement))
        #expect(hover.sharedTabID == zID)
        let insertAfter = sourcePane == 3
        let marker = TabStripInsertion.resolve(hover, order: tabs.tabOrder, tabs: tabs, paneOrder: panes.map(\.paneId), shared: destination)
        #expect(marker == .init(row: .tab(x), side: insertAfter ? .after : .before))

        #expect(context.drop(drag, at: placement, rightSide: false) { _ in false })
        let displayed = tabs.presentedTabOrder(tabs.tabOrder, panes: panes, layout: .init(ids: [x: xID, z: zID], layout: layout))
        let xRow = SessionTabEntry<TabDragPayload>.ID.group(.pane("%2"))
        let zRow = sourcePane.map { SessionTabEntry<TabDragPayload>.ID.group(.pane("%\($0)")) } ?? .tab(z)
        #expect(tabs.tabStripEntries(displayed).map(\.id) == (insertAfter ? [xRow, zRow] : [zRow, xRow]))
    }

    @Test
    func directoryAndBrowserStateMoveWithoutRecreationAndReturnOnNativeClose() throws {
        _ = NSApplication.shared
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        manager.reserve(target)
        let group = try #require(manager.workspace(containing: target))
        let main = manager.mainTabs.tabs(hostID: nil, session: "work")
        let files = FileBrowserTab(path: "/tmp", sourcePaneID: "%1")
        files.query = "report"
        main.openFileTabs = [.init(id: files.id, path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        main.directoryTabs[files.id] = files
        main.selectedFileTabId = files.id
        main.rightSide = [.file(files.id)]
        main.selectedRight = .file(files.id)
        let browser = try BrowserTab(url: #require(URL(string: "about:blank")))
        let browserState = BrowserTabState(initialURL: browser.url)
        main.openBrowserTabs = [browser]
        main.browserStates[browser.id] = browserState
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .file(files.id))
        #expect(manager.transfer(drag, to: group.id, session: { _ in "work" }))
        let detached = group.tabs.tabs(hostID: nil, session: "work")
        #expect(detached.directoryTabs[files.id] === files)
        #expect(detached.directoryTabs[files.id]?.query == "report")
        #expect(main.directoryTabs.isEmpty && main.selectedFileTabId == nil && main.selectedRight == nil)
        #expect(manager.transfer(
            WorkbenchTabDrag(workspaceID: nil, hostID: nil, sessionName: "work", tab: .browser(browser.id)),
            to: group.id,
            session: { _ in "work" }
        ))
        #expect(detached.browserStates[browser.id] === browserState)
        #expect(main.browserStates.isEmpty)
        let native = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        native.isReleasedWhenClosed = false
        manager.attach(native, to: target)
        manager.didClose(target, window: native)
        #expect(manager.targets.isEmpty)
        #expect(main.directoryTabs[files.id] === files)
        #expect(main.openFileTabs.map(\.id) == [files.id])
        #expect(main.browserStates[browser.id] === browserState)
        #expect(main.openBrowserTabs.map(\.id) == [browser.id])
    }

    @Test
    func filesOnlyWorkspaceCanAdoptANewTerminal() throws {
        let manager = DetachedTerminalWindows()
        let first = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let created = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@2"))
        manager.reserve(first)
        let group = try #require(manager.workspace(containing: first))
        let tabs = group.tabs.tabs(hostID: nil, session: "work")
        tabs.openFileTabs = [.init(path: "/tmp", directoryPath: "/tmp", isDirectory: true)]
        manager.returnToMain(first)
        #expect(group.members.isEmpty)
        #expect(manager.merge(created, into: group.id, session: { _ in "work" }))
        #expect(group.members == [created])
        #expect(group.selection == .window("@2"))
    }

    @Test
    func crossSceneDropRejectsStaleSourcesAndForeignDestinations() throws {
        let manager = DetachedTerminalWindows()
        let a = try #require(DetachedTerminalTarget(hostID: "A", windowID: "@1"))
        let b = try #require(DetachedTerminalTarget(hostID: "B", windowID: "@1"))
        manager.reserve(a)
        manager.reserve(b)
        let one = try #require(manager.workspace(containing: a))
        let two = try #require(manager.workspace(containing: b))
        let drag = WorkbenchTabDrag(workspaceID: one.id, hostID: "A", sessionName: "work", tab: .window("@1"))
        #expect(manager.canTransfer(drag, to: nil, session: { _ in "work" }))
        #expect(manager.workspaces[one.id]?.selection == .window("@1"))
        #expect(!manager.transfer(drag, to: two.id, session: { _ in "work" }))
        let forged = WorkbenchTabDrag(workspaceID: nil, hostID: "A", sessionName: "work", tab: .window("@1"))
        #expect(!manager.transfer(forged, to: one.id, session: { _ in "work" }))
        #expect(manager.targets == [a, b])
    }

    @Test
    func reorderSubsetPreservesOtherNativeWindows() {
        #expect(TabDragPayload.mergingWindowOrder(["@3", "@1"], into: ["@1", "@2", "@3", "@4"]) == ["@3", "@2", "@1", "@4"])
        #expect(TabDragPayload.mergingWindowOrder(["@1", "@1"], into: ["@1", "@2"]) == nil)
        #expect(TabDragPayload.mergingWindowOrder(["@8"], into: ["@1", "@2"]) == nil)
    }

    @Test
    func detachUsesTheSameTransferAndClearsTheSourceSplit() throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        let main = manager.mainTabs.tabs(hostID: nil, session: "work")
        main.tabOrder = [.window("@1"), .window("@2")]
        main.rightSide = [.window("@1"), .window("@2")]
        main.selectedRight = .window("@1")
        let first = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        #expect(main.rightSide == [.window("@2")])
        #expect(main.selectedRight == .window("@2"))
        #expect(first.members == [target])
        let second = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        #expect(first.id != second.id)
        #expect(manager.workspaces[first.id] == nil)
        #expect(manager.owner(hostID: nil, windowID: "@1") == second.id)
        #expect(manager.presentationRevision == 2)
    }

    @Test
    func stableIdentityIncludesHost() throws {
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        let another = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@12"))
        #expect(Set([local, remote, another]).count == 3)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "session:1") == nil)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "%12") == nil)
        #expect(try JSONDecoder().decode(DetachedTerminalTarget.self, from: JSONEncoder().encode(remote)) == remote)
    }

    @Test
    func reservationIsUniqueAndCloseOnlyReleasesItsOwnPresentation() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
        #expect(!state.reserve(local))
        #expect(state.reserve(remote))
        let old = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let current = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        state.attach(old, to: local)
        state.attach(current, to: local)
        state.didClose(local, window: old)
        #expect(state.contains(hostID: nil, windowID: "@12"))
        state.didClose(local, window: current)
        #expect(!state.contains(hostID: nil, windowID: "@12"))
        #expect(state.contains(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
    }

    @Test
    func requestsCaptureSourceAndDoNotRevokeOwnership() throws {
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@8"))
        state.reserve(target)
        state.request(.files(paneID: "%9"), from: target)
        let first = try #require(state.mainRequest)
        state.request(.fork(paneID: "%9", destination: .worktree), from: target)
        #expect(state.mainRequest?.target == target)
        #expect(state.mainRequest?.id != first.id)
        #expect(state.mainRequest?.action == .fork(paneID: "%9", destination: .worktree))
        state.request(.url("https://example.com", paneID: "%9"), from: target)
        #expect(state.mainRequest?.target == target)
        #expect(state.mainRequest?.action == .url("https://example.com", paneID: "%9"))
        #expect(state.targets == [target])
    }

    @Test
    func nativeCloseReleasesOwnershipEvenAfterContentReparenting() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@19"))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        state.reserve(target)
        window.contentView = NSHostingView(rootView: WorkbenchWindowRegistration(workspaceID: state.owner(hostID: nil, windowID: "@19"), windows: state))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView = NSView()
        #expect(state.targets.contains(target))
        state.close(target)
        #expect(!state.targets.contains(target))
    }

    @Test
    func rightSideReturnNeverDuplicatesTheLeftRenderer() {
        let windows = [(stableID: "@1", id: "renamed:3"), (stableID: "@2", id: "renamed:7")]
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@2"]) == "renamed:3")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: []) == "renamed:7")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@1", "@2"]) == nil)
    }

    @Test(arguments: [nil, "viewer-host"] as [String?])
    func fileRequestFromRightSplitUsesOwnedSelectionBeforeAndAfterReconciliation(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let other = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let left = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let right = try #require(DetachedTerminalTarget(hostID: host, windowID: "@3"))
        manager.reserve(other)
        manager.reserve(left)
        let workspace = try #require(manager.workspace(containing: left))
        #expect(manager.merge(right, into: workspace.id, session: { _ in "work" }))
        let tabs = workspace.tabs.tabs(hostID: host, session: "work")
        tabs.rightSide = [.window("@3")]
        tabs.selectedRight = .window("@3")
        let windows = [(stableID: "@1", id: "work:0"), (stableID: "@2", id: "work:1"), (stableID: "@3", id: "work:2")]
        let owns = { manager.owner(hostID: host, windowID: $0) == workspace.id }
        let selection = DetachedTerminalWindows.mainSelection(target: "@3", current: "@1", windows: windows, rightSide: tabs.rightSideWindowIds, owns: owns)
        #expect(selection == "work:1")
        func snapshot(_ selected: String?) -> BrowserOpenSelection {
            .init(
                localWindowID: host == nil ? selected : nil,
                remoteSession: host.map { .init(hostId: $0, hostName: "Peer", sessionName: "work") },
                remoteWindowID: host == nil ? nil : selected,
                tabs: tabs,
                fileBrowserActiveWindowIDs: []
            )
        }
        let initial = snapshot(selection)
        let repaired = WorkspaceTerminalSelection.leftWindowID(
            current: windows.first { $0.id == selection }?.stableID, orderedIDs: windows.map(\.stableID),
            activeID: "@1", rightSide: tabs.rightSideWindowIds, owns: owns
        )
        #expect(repaired == "@2")
        #expect(initial == snapshot(windows.first { $0.stableID == repaired }?.id))
        tabs.selectedFileTabId = UUID()
        #expect(initial != snapshot(selection), "Real navigation must still invalidate an asynchronous open")
        #expect(DetachedTerminalWindows.mainSelection(target: "@3", current: "@2", windows: windows, rightSide: ["@3"], owns: { $0 == "@3" }) == nil)
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: [], owns: owns) == "work:1")
    }

    @Test
    func dragOriginStaysInsideItsTabEvenWhenHostingVisibleRectIsLarger() {
        let bounds = CGRect(x: 0, y: 0, width: 109, height: 25)
        let hostVisibleRect = CGRect(x: -242.5, y: -1, width: 900, height: 79)
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 150, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: -85, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 40), bounds: bounds, visibleRect: hostVisibleRect))

        let clipped = CGRect(x: 40, y: 0, width: 69, height: 25)
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 20, y: 12), bounds: bounds, visibleRect: clipped))
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: clipped))
    }

    @Test
    func onlyUnclaimedMouseReleaseAwayFromTabStripDetaches() {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        let belowStrip = CGPoint(x: 500, y: 500)
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: .move, cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: .copy, cancelled: false, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: true, mouseReleased: true, point: belowStrip, tabStripFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: false, point: belowStrip, tabStripFrame: frame))
    }

    @Test
    func maximizedWindowCanDetachIntoItsOwnContent() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = WindowTabDragSource.tabStripFrame(
            tabFrame: CGRect(x: 240, y: 820, width: 100, height: 26), windowFrame: windowFrame
        )
        #expect(frame == CGRect(x: 0, y: 820, width: 1_440, height: 26))
        let point = CGPoint(x: 300, y: 740)
        #expect(windowFrame.contains(point))
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test(arguments: [CGPoint(x: 500, y: 663), CGPoint(x: 890, y: 663), CGPoint(x: 500, y: 630), CGPoint(x: 500, y: 696)])
    func reorderingAndSmallVerticalMovementDoNotDetach(point: CGPoint) {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test(arguments: [CGPoint(x: 500, y: 620), CGPoint(x: 500, y: 706), CGPoint(x: 70, y: 663), CGPoint(x: 930, y: 663)])
    func movingBeyondStripMarginDetaches(point: CGPoint) {
        let frame = CGRect(x: 100, y: 650, width: 800, height: 26)
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: point, tabStripFrame: frame))
    }

    @Test
    func tabStripCoordinatesSupportAnotherDisplay() {
        let frame = WindowTabDragSource.tabStripFrame(
            tabFrame: CGRect(x: -1_300, y: -100, width: 110, height: 26),
            windowFrame: CGRect(x: -1_600, y: -900, width: 1_600, height: 900)
        )
        #expect(frame == CGRect(x: -1_600, y: -100, width: 1_600, height: 26))
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: CGPoint(x: -1_200, y: -200), tabStripFrame: frame))
    }

    @Test
    func draggingPayloadMatchesExistingTabDropProtocol() throws {
        let original = TabDragPayload.window("@23")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TabDragPayload.self, from: data) == original)
    }

    @Test(arguments: [true, false])
    func releasePointStaysTiedToMouseUpEvent(releasedInsideStrip: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let inside = CGPoint(x: 400, y: 563)
        let outside = CGPoint(x: 400, y: 400)
        let releaseLocation = releasedInsideStrip ? inside : outside
        let laterLocation = releasedInsideStrip ? outside : inside
        let release = try mouseEvent(.leftMouseUp, location: releaseLocation, window: window, timestamp: 1)
        let laterMove = try mouseEvent(.mouseMoved, location: laterLocation, window: window, timestamp: 2)
        #expect(release.window === window)
        let laterPoint = WindowTabDragSource.screenPoint(for: laterMove)
        let releasePoint = WindowTabDragSource.screenPoint(for: release)
        #expect(releasePoint == window.convertPoint(toScreen: releaseLocation))
        #expect(laterPoint == window.convertPoint(toScreen: laterLocation))
        #expect(releasePoint != laterPoint)
        let strip = window.convertToScreen(CGRect(x: 0, y: 550, width: 800, height: 26))
        #expect(WindowTabDragSource.shouldDetach(
            operation: [], cancelled: false, mouseReleased: true,
            point: releasePoint, tabStripFrame: strip
        ) == !releasedInsideStrip)
    }

    @Test
    func windowlessReleaseAlreadyUsesScreenCoordinates() throws {
        let point = CGPoint(x: -1_200, y: 500)
        let event = try mouseEvent(.leftMouseUp, location: point, window: nil, timestamp: 1)
        #expect(event.window == nil)
        #expect(WindowTabDragSource.screenPoint(for: event) == point)
    }

    private func mouseEvent(_ type: NSEvent.EventType, location: CGPoint, window: NSWindow?, timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    @Test
    func placementSupportsNegativeScreenOrigins() {
        let display = CGRect(x: -1_600, y: 0, width: 1_600, height: 1_000)
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -1_650, y: -200), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_600, y: 0))
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -50, y: 900), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_000, y: 300))
    }
}
