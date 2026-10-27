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
}
