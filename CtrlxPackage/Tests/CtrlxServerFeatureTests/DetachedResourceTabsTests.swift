import AppKit
import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct DetachedResourceTabsTests {
    enum Kind: CaseIterable, Equatable, Sendable {
        case files
        case browser
        case simulator
    }

    @Test(arguments: [nil, "viewer"] as [String?], [false, true])
    func creationReplyClaimsSourceWindowBeforeCatalogProjection(host: String?, simulator: Bool) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let tabs = group.tabs.tabs(hostID: host, session: "work")
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let selection = group.selection
        let selectionRevision = group.selectionRevision
        var tab = BrowserTab(url: URL(staticString: "https://example.com"))
        tab.isAgentBrowser = !simulator
        tab.isSimulator = simulator

        #expect(manager.claimOpenedBrowser(tab, hostID: host, session: "work", workspaceID: group.id, resolveSession: { _ in "work" }))
        #expect(manager.browserOwner(hostID: host, session: "work", id: tab.id, windowID: nil) == group.id)
        #expect(main.openBrowserTabs.isEmpty)
        #expect(tabs.openBrowserTabs == [tab])
        #expect(group.selection == selection && group.selectionRevision == selectionRevision)
        #expect(tabs.selectedBrowserTabId == nil)

        // The later Host catalog must update the adopted tab, not create one in main.
        if simulator {
            let descriptor = RemoteSimulatorTab(id: tab.id, sessionName: "work", title: "Phone", runtime: "iOS", isPrimary: false, resourceSessionID: UUID())
            for (id, state) in [(nil, main), (group.id, tabs)] as [(UUID?, SessionFileTabsState)] {
                state.syncHostSimulatorTabs([descriptor].filter {
                    manager.browserOwner(hostID: host, session: "work", id: $0.id, windowID: $0.windowID) == id
                }, sessionWindowIDs: ["@1"])
            }
        } else {
            let descriptor = RemoteBrowserTab(id: tab.id, sessionName: "work", title: "Page", url: tab.url.absoluteString, isLoading: false, isAgentOwned: false, resourceSessionID: UUID())
            for (id, state) in [(nil, main), (group.id, tabs)] as [(UUID?, SessionFileTabsState)] {
                state.syncHostBrowserTabs([descriptor].filter {
                    manager.browserOwner(hostID: host, session: "work", id: $0.id, windowID: $0.windowID) == id
                }, sessionWindowIDs: ["@1"])
            }
        }
        let revision = manager.presentationRevision
        #expect(manager.claimOpenedBrowser(tab, hostID: host, session: "work", workspaceID: group.id, resolveSession: { _ in "work" }))
        #expect(manager.presentationRevision == revision)
        #expect(main.openBrowserTabs.isEmpty && tabs.openBrowserTabs.map(\.id) == [tab.id])
        #expect(tabs.openBrowserTabs.first?.originWindowId == nil)
        #expect(tabs.openBrowserTabs.first?.isSimulator == simulator)
        #expect(tabs.selectedBrowserTabId == nil)
    }

    @Test(arguments: [nil, "viewer"] as [String?], [Kind.browser, .simulator])
    func creationReplyMovesAlreadyProjectedResourceWithoutChangingSelection(host: String?, kind: Kind) throws {
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let payload = resource(kind, in: main)
        let tab = try #require(main.openBrowserTabs.first)
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let destination = group.tabs.tabs(hostID: host, session: "work")
        let selection = group.selection
        main.selectedBrowserTabId = tab.id
        main.rightSide = [payload]
        main.selectedRight = payload
        let browserState = main.remoteBrowserTabs[tab.id]
        let simulatorState = main.remoteSimulatorTabs[tab.id]

        #expect(manager.claimOpenedBrowser(tab, hostID: host, session: "work", workspaceID: group.id, resolveSession: { _ in "work" }))

        #expect(main.openBrowserTabs.isEmpty && main.selectedBrowserTabId == nil && main.selectedRight == nil)
        #expect(destination.openBrowserTabs.map(\.id) == [tab.id])
        #expect(destination.remoteBrowserTabs[tab.id] == browserState)
        #expect(destination.remoteSimulatorTabs[tab.id] == simulatorState)
        #expect(group.selection == selection && destination.selectedBrowserTabId == nil)
    }

    @Test(arguments: ["host", "session", "closed"])
    func creationReplyRejectsUnrelatedOrClosedWindow(_ reason: String) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: "viewer", windowID: "@1"))
        let group = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let tab = BrowserTab(url: URL(staticString: "about:blank"))

        #expect(!manager.claimOpenedBrowser(
            tab, hostID: reason == "host" ? "other" : "viewer", session: reason == "session" ? "other" : "work",
            workspaceID: reason == "closed" ? UUID() : group.id, resolveSession: { _ in "work" }
        ))
        #expect(group.tabs.tabs(hostID: "viewer", session: "work").openBrowserTabs.isEmpty)
        #expect(manager.mainTabs.tabs(hostID: "viewer", session: "work").openBrowserTabs.isEmpty)
        #expect(group.tabs.existing(hostID: "other", session: "work") == nil)
        #expect(group.tabs.existing(hostID: "viewer", session: "other") == nil)
    }

    @Test(arguments: [nil, "viewer"] as [String?])
    func independentFileLinkKeepsSourceWindowAndMainFilesNavigation(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let existing = HostFileTab(sessionName: "work", initialDirectory: "/main", resourceSessionID: UUID())
        let created = HostFileTab(sessionName: "work", initialDirectory: "/source", resourceSessionID: existing.resourceSessionID)
        let windows = ["work": ["@1", "@2"]]
        manager.syncFileTabs(hostID: host, descriptors: [existing, created], sessionWindows: windows)
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let mainFile = try #require(main.directoryTabs[existing.id])
        mainFile.navigate("/main/retained")
        main.selectedFileTabId = existing.id

        manager.claimFile(created.id, hostID: host, session: "work", workspaceID: group.id)
        let detached = group.tabs.tabs(hostID: host, session: "work")
        let file = try #require(detached.directoryTabs[created.id])
        file.navigate("/source/child")
        manager.syncFileTabs(hostID: host, descriptors: [existing, created], sessionWindows: windows)

        #expect(detached.directoryTabs[created.id] === file && file.path == "/source/child")
        #expect(file.sourcePaneID == nil)
        #expect(main.openFileTabs.map(\.id) == [existing.id])
        #expect(main.directoryTabs[existing.id] === mainFile && mainFile.path == "/main/retained")
        #expect(main.selectedFileTabId == existing.id && detached.selectedFileTabId == nil)
    }

    private func resource(_ kind: Kind, in tabs: SessionFileTabsState) -> TabDragPayload {
        if kind == .files {
            let file = FileBrowserTab(path: "/fixture", sourcePaneID: "%1")
            file.query = "retained query"
            tabs.openFileTabs.append(.init(id: file.id, path: "/fixture", directoryPath: "/fixture", isDirectory: true))
            tabs.directoryTabs[file.id] = file
            tabs.scrollOffsets[file.id] = 120
            return .file(file.id)
        }
        var browser = BrowserTab(url: URL(staticString: "about:blank"), originWindowId: "work:1")
        browser.isSimulator = kind == .simulator
        tabs.openBrowserTabs.append(browser)
        if kind == .simulator {
            tabs.remoteSimulatorTabs[browser.id] = .init(id: browser.id, sessionName: "work", windowID: "@1", sourcePaneID: "%1", title: "Phone", runtime: "iOS", isPrimary: true)
        } else {
            tabs.remoteBrowserTabs[browser.id] = .init(id: browser.id, sessionName: "work", windowID: "@1", title: "Retained page", url: "about:blank", isLoading: false, isAgentOwned: true, sourcePaneID: "%1")
        }
        return .browser(browser.id)
    }

    @Test(arguments: [nil, "viewer"] as [String?], Kind.allCases)
    func independentlyDetachesAndReturnsWithoutTakingTheSourceTerminal(host: String?, kind: Kind) throws {
        _ = NSApplication.shared
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let payload = resource(kind, in: main)
        let anchor = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        main.tabOrder = [.window("@1"), payload]
        main.rightSide = [payload]
        main.selectedRight = payload
        let files = main.directoryTabs
        let browsers = main.remoteBrowserTabs
        let simulators = main.remoteSimulatorTabs

        let group = try #require(manager.detach(.init(workspaceID: nil, hostID: host, sessionName: "work", tab: payload), anchor: anchor, position: nil, session: { _ in "work" }))

        let detached = group.tabs.tabs(hostID: host, session: "work")
        #expect(group.members.isEmpty && manager.targets.isEmpty)
        #expect(manager.owner(hostID: host, windowID: "@1") == nil)
        #expect(group.selection == payload && detached.tabOrder == [payload])
        #expect(main.rightSide.isEmpty && main.selectedRight == nil)
        #expect(main.openFileTabs.isEmpty && main.openBrowserTabs.isEmpty)
        #expect(detached.remoteBrowserTabs == browsers && detached.remoteSimulatorTabs == simulators)
        for (id, model) in files {
            #expect(detached.directoryTabs[id] === model)
            #expect(model.query == "retained query" && detached.scrollOffsets[id] == 120)
        }

        let native = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        manager.attach(native, toWorkspace: group.id)
        native.close()

        #expect(manager.workspaces.isEmpty)
        #expect(main.tabOrder.contains(payload))
        #expect(main.remoteBrowserTabs == browsers && main.remoteSimulatorTabs == simulators)
        for (id, model) in files {
            #expect(main.directoryTabs[id] === model)
        }
    }

    @Test(arguments: [nil, "viewer"] as [String?], Kind.allCases)
    func mergesAndReturnsThroughTheSameTransfer(host: String?, kind: Kind) throws {
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let payload = resource(kind, in: main)
        let anchor = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(.init(workspaceID: nil, hostID: host, sessionName: "work", tab: payload), anchor: anchor, position: nil, session: { _ in "work" }))
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@2"))
        let destination = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        var sourceClosed = false
        group.onClose = { sourceClosed = true }

        #expect(manager.transfer(.init(workspaceID: group.id, hostID: host, sessionName: "work", tab: payload), to: destination.id, session: { _ in "work" }))
        #expect(sourceClosed && manager.workspaces[group.id] == nil)
        let tabs = destination.tabs.tabs(hostID: host, session: "work")
        #expect(tabs.tabOrder.contains(payload) && destination.selection == payload)
        #expect(manager.transfer(.init(workspaceID: destination.id, hostID: host, sessionName: "work", tab: payload), to: nil, session: { _ in "work" }))
        #expect(main.tabOrder.contains(payload) && !tabs.tabOrder.contains(payload))
        #expect(destination.members == [target])
    }

    @Test(arguments: Kind.allCases)
    func staleAndForeignDetachRequestsLeaveTheResourceInPlace(_ kind: Kind) throws {
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: "one", session: "work")
        let payload = resource(kind, in: main)
        let anchor = try #require(DetachedTerminalTarget(hostID: "one", windowID: "@1"))
        let foreign = try #require(DetachedTerminalTarget(hostID: "two", windowID: "@1"))
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: "one", sessionName: "work", tab: payload)
        #expect(manager.detach(drag, anchor: foreign, position: nil, session: { _ in "work" }) == nil)
        #expect(manager.detach(drag, anchor: anchor, position: nil, session: { _ in "other" }) == nil)
        let stale = WorkbenchTabDrag(workspaceID: UUID(), hostID: "one", sessionName: "work", tab: payload)
        #expect(manager.detach(stale, anchor: anchor, position: nil, session: { _ in "work" }) == nil)
        #expect(manager.workspaces.isEmpty)
        #expect(main.openFileTabs.count + main.openBrowserTabs.count == 1)
        #expect(!TabDragPayload.git.canDetach && !TabDragPayload.fileExplorer.canDetach)
    }

    @Test(arguments: [nil, "viewer"] as [String?], Kind.allCases.flatMap { kind in [false, true].map { (kind, $0) } })
    func returnButtonMovesOnlyTheRequestedResource(host: String?, configuration: (Kind, Bool)) throws {
        let (kind, keepSibling) = configuration
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let payload = resource(kind, in: main)
        let anchor = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(.init(workspaceID: nil, hostID: host, sessionName: "work", tab: payload), anchor: anchor, position: nil, session: { _ in "work" }))
        let detached = group.tabs.tabs(hostID: host, session: "work")
        let sibling = keepSibling ? resource(kind, in: detached) : nil
        var closed = false
        group.onClose = { closed = true }

        #expect(manager.returnToMain(.init(workspaceID: group.id, hostID: host, sessionName: "work", tab: payload), anchor: anchor, session: { _ in "work" }))

        #expect(main.tabOrder.contains(payload) && !detached.tabOrder.contains(payload))
        #expect(manager.mainRequest?.target == anchor && manager.mainRequest?.action == .tab(payload))
        #expect(closed == !keepSibling)
        if let sibling {
            #expect(manager.workspaces[group.id] === group)
            #expect(!main.tabOrder.contains(sibling))
            #expect(detached.openFileTabs.contains { .file($0.id) == sibling } || detached.openBrowserTabs.contains { .browser($0.id) == sibling })
        } else {
            #expect(manager.workspaces.isEmpty)
        }
    }

    @Test(arguments: [nil, "viewer"] as [String?])
    func returningATerminalLeavesItsResourceInTheSeparateWindow(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let group = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let detached = group.tabs.tabs(hostID: host, session: "work")
        let file = resource(.files, in: detached)

        #expect(manager.returnToMain(.init(workspaceID: group.id, hostID: host, sessionName: "work", tab: .window("@1")), anchor: target, session: { _ in "work" }))

        #expect(group.members.isEmpty && manager.workspaces[group.id] === group)
        #expect(manager.owner(hostID: host, windowID: "@1") == nil)
        #expect(detached.openFileTabs.contains { .file($0.id) == file })
        #expect(manager.mainRequest?.action == .tab(.window("@1")))
    }

    @Test(arguments: ["host", "session", "stale", "main"])
    func invalidReturnsKeepTheResourceAndDoNotSelectAnUnrelatedMainTab(_ invalid: String) throws {
        let manager = DetachedTerminalWindows()
        let main = manager.mainTabs.tabs(hostID: "host", session: "work")
        let payload = resource(.files, in: main)
        let anchor = try #require(DetachedTerminalTarget(hostID: "host", windowID: "@1"))
        let group = try #require(manager.detach(.init(workspaceID: nil, hostID: "host", sessionName: "work", tab: payload), anchor: anchor, position: nil, session: { _ in "work" }))
        let target = invalid == "host" ? try #require(DetachedTerminalTarget(hostID: "other", windowID: "@1")) : anchor
        let workspaceID: UUID? = invalid == "main" ? nil : (invalid == "stale" ? UUID() : group.id)

        #expect(!manager.returnToMain(.init(workspaceID: workspaceID, hostID: "host", sessionName: "work", tab: payload), anchor: target, session: { _ in invalid == "session" ? "other" : "work" }))

        #expect(manager.mainRequest == nil && manager.workspaces[group.id] === group)
        #expect(main.openFileTabs.isEmpty)
        #expect(group.tabs.tabs(hostID: "host", session: "work").openFileTabs.count == 1)
    }
}
