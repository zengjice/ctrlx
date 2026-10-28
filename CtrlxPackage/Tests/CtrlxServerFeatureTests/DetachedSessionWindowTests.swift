import AppKit
import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct DetachedSessionWindowTests {
    @Test(arguments: [nil, "remote"] as [String?])
    func sessionMovesItsLiveLayoutAndClosesBackIntoMain(host: String?) throws {
        _ = NSApplication.shared
        let manager = DetachedTerminalWindows()
        let original = manager.mainTabs.tabs(hostID: host, session: "work")
        let file = OpenFileTab(path: "/report.md", directoryPath: "/")
        let simulatorID = UUID()
        var simulator = BrowserTab(id: simulatorID, url: URL(staticString: "about:blank"), originWindowId: "@1")
        simulator.isSimulator = true
        original.openFileTabs = [file]
        original.openBrowserTabs = [simulator]
        original.remoteSimulatorTabs[simulatorID] = .init(id: simulatorID, sessionName: "work", windowID: "@1", sourcePaneID: "%1", title: "iPhone", runtime: "iOS", isPrimary: true)
        original.selectedFileTabId = file.id
        original.scrollOffsets[file.id] = 350
        original.tabOrder = [.window("@2"), .file(file.id), .browser(simulatorID), .window("@1")]
        original.rightSide = [.window("@1")]
        original.selectedRight = .window("@1")
        original.splitRatio = 0.7
        original.isRightPaneFocused = true

        let group = try #require(manager.detachSession(hostID: host, name: "work", windowIDs: ["@1", "@2"], selectedWindowID: "@2", position: nil, session: { _ in "work" }))
        #expect(group.isSessionWindow)
        #expect(group.tabs.existing(hostID: host, session: "work") === original)
        #expect(manager.mainTabs.existing(hostID: host, session: "work") == nil)
        #expect(group.members.map(\.windowID) == ["@1", "@2"])
        #expect(original.tabOrder == [.window("@2"), .file(file.id), .browser(simulatorID), .window("@1")])
        #expect(group.tabs.restoredSelection?.windowID == "@2")
        #expect(original.selectedFileTabId == file.id && original.selectedRight == .window("@1"))

        let main = manager.mainTabs.tabs(hostID: host, session: "work")
        let added = OpenFileTab(path: "/new.md", directoryPath: "/")
        main.openFileTabs.append(added)
        main.tabOrder = [.file(added.id)]
        manager.mainTabs.recoverySelection = .init(hostID: host, sessionName: "other", windowID: "@9")
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(window, toWorkspace: group.id)
        window.close()

        #expect(manager.workspaces.isEmpty)
        #expect(manager.mainTabs.existing(hostID: host, session: "work") === original)
        #expect(original.openFileTabs.map(\.id) == [file.id, added.id])
        #expect(original.remoteSimulatorTabs[simulatorID] != nil)
        #expect(original.scrollOffsets[file.id] == 350)
        #expect(original.splitRatio == 0.7 && original.isRightPaneFocused)
        #expect(original.rightSide == [.window("@1")] && original.selectedRight == .window("@1"))
        #expect(manager.mainTabs.recoverySelection?.sessionName == "other")
        #expect(manager.mainTabs.restoredSelection == nil)
    }

    @Test(arguments: [nil, "remote"] as [String?])
    func repeatedSessionOpenDoesNotCollectAlreadyDetachedTabs(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let independent = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let group = try #require(manager.detachSession(hostID: host, name: "work", windowIDs: ["@1", "@2"], selectedWindowID: "@1", position: nil, session: { _ in "work" }))
        let repeated = try #require(manager.detachSession(hostID: host, name: "work", windowIDs: ["@1", "@2"], selectedWindowID: "@2", position: nil, session: { _ in "work" }))
        #expect(repeated === group)
        #expect(group.members.map(\.windowID) == ["@2"])
        #expect(manager.workspace(containing: target) === independent)
        #expect(manager.workspaces.count == 2)
    }

    @Test(arguments: [false, true])
    func viewerSimulatorKeepsItsPlacementAfterItsTerminalMoves(sourceFirst: Bool) throws {
        let manager = DetachedTerminalWindows()
        let simulator = RemoteSimulatorTab(id: UUID(), sessionName: "work", windowID: "@1", sourcePaneID: "%1", title: "iPhone", runtime: "iOS", isPrimary: true)
        let original = manager.mainTabs.tabs(hostID: "host", session: "work")
        original.syncHostSimulatorTabs([simulator], sessionWindowIDs: ["@1", "@2"])
        let page = BrowserTab(url: URL(staticString: "about:blank"), originWindowId: "@1")
        original.openBrowserTabs.append(page)
        let group = try #require(manager.detachSession(hostID: "host", name: "work", windowIDs: ["@1", "@2"], selectedWindowID: "@2", position: nil, session: { _ in "work" }))
        #expect(manager.simulatorTabs([simulator], hostID: "host", session: "work", workspaceID: group.id) == [simulator])
        #expect(manager.transfer(.init(workspaceID: group.id, hostID: "host", sessionName: "work", tab: .window("@1")), to: nil, session: { _ in "work" }))
        #expect(original.remoteSimulatorTabs[simulator.id] == simulator)

        let order: [UUID?] = sourceFirst ? [group.id, nil] : [nil, group.id]
        for workspaceID in order {
            let store = try #require(manager.store(for: workspaceID))
            let ids = ["@1", "@2"].filter { manager.owner(hostID: "host", windowID: $0) == workspaceID }
            store.tabs(hostID: "host", session: "work").syncHostSimulatorTabs(
                manager.simulatorTabs([simulator], hostID: "host", session: "work", workspaceID: workspaceID),
                sessionWindowIDs: ids
            )
        }

        #expect(manager.mainTabs.existing(hostID: "host", session: "work")?.remoteSimulatorTabs[simulator.id] == nil)
        #expect(original.remoteSimulatorTabs[simulator.id] == simulator)
        #expect(original.openBrowserTabs.contains { $0.id == simulator.id })
        #expect(manager.browserOwner(hostID: "host", session: "work", id: page.id, windowID: "@1") == group.id)
        #expect(manager.simulatorTabs([simulator], hostID: "other-host", session: "work", workspaceID: group.id).isEmpty)
    }

    @Test
    func sessionIdentityIncludesHostAndRejectsStaleTargets() throws {
        let manager = DetachedTerminalWindows()
        #expect(manager.detachSession(hostID: nil, name: "work", windowIDs: ["work:1"], selectedWindowID: nil, position: nil, session: { _ in "work" }) == nil)
        #expect(manager.detachSession(hostID: nil, name: "work", windowIDs: ["@1"], selectedWindowID: nil, position: nil, session: { _ in "replaced" }) == nil)
        for host: String? in [nil, "one", "two"] {
            let group = try #require(manager.detachSession(hostID: host, name: "work", windowIDs: ["@1"], selectedWindowID: nil, position: nil, session: { _ in "work" }))
            #expect(group.hostID == host)
        }
        #expect(manager.workspaces.count == 3)
    }

    @Test
    func oldRecoveryScenesDecodeWithoutTheSessionWindowFlag() throws {
        let original = WorkspaceRecoveryScene(id: UUID(), isMain: false, sessions: [])
        let restored = try JSONDecoder().decode(WorkspaceRecoveryScene.self, from: JSONEncoder().encode(original))
        #expect(restored.isSessionWindow == nil)
    }

    @Test
    func sessionDragsOnlyDetachBeyondTheNativeWindow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let bounds = WindowTabDragSource.tabStripFrame(tabFrame: .init(x: 110, y: 500, width: 200, height: 40), windowFrame: window, isSession: true)
        #expect(bounds == window)
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: .init(x: 650, y: 400), tabStripFrame: bounds))
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: .init(x: 1_000, y: 400), tabStripFrame: bounds))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: true, mouseReleased: true, point: .init(x: 1_000, y: 400), tabStripFrame: bounds))
    }
}
