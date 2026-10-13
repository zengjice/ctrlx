import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct RemoteSessionStructureTests {
    private func pane(_ id: String, session: String, window: Int = 0) -> PaneState {
        PaneState(paneId: id, sessionName: session, windowIndex: window, tmuxWindowId: "@\(window)")
    }

    @Test
    func identifiesRenamesPerHostAndRemapsEveryWindow() {
        let old: [PaneKey: PaneState] = [
            .init(pairId: "A", paneId: "%0"): pane("%0", session: "old"),
            .init(pairId: "A", paneId: "%1"): pane("%1", session: "old", window: 1),
            .init(pairId: "B", paneId: "%0"): pane("%0", session: "old"),
        ]
        var new = old
        new[.init(pairId: "A", paneId: "%0")] = pane("%0", session: "new")
        new[.init(pairId: "A", paneId: "%1")] = pane("%1", session: "new", window: 1)
        let renames = RemoteSessionStructure(panes: new).renames(from: .init(panes: old))
        #expect(renames.count == 1)
        #expect(renames.first?.hostID == "A")
        #expect(renames.first?.mapping == SessionRenameMapping(
            oldName: "old", newName: "new", windowIDs: ["old:0": "new:0", "old:1": "new:1"]
        ))
    }

    @Test
    func ignoresMetadataDisconnectsAndPartialMoves() {
        let key = PaneKey(pairId: "A", paneId: "%0")
        let old = RemoteSessionStructure(panes: [key: pane("%0", session: "old")])
        var updated = pane("%0", session: "old")
        updated.windowName = "title changed"
        updated.currentPath = "/another/project"
        updated.width = 200
        #expect(RemoteSessionStructure(panes: [key: updated]) == old)
        #expect(RemoteSessionStructure(panes: [:]).renames(from: old).isEmpty)
        let other = PaneKey(pairId: "A", paneId: "%1")
        let multiple = RemoteSessionStructure(panes: [key: updated, other: pane("%1", session: "old", window: 1)])
        let moved = RemoteSessionStructure(panes: [key: updated, other: pane("%1", session: "new", window: 1)])
        #expect(moved.renames(from: multiple).isEmpty)
        #expect(RemoteSessionStructure(panes: [.init(pairId: "B", paneId: "%0"): pane("%0", session: "new")])
            .renames(from: old).isEmpty)
    }

    @Test
    func catalogSyncWaitsForMatchingRoutingWithoutConfusingHosts() {
        let structure = RemoteSessionStructure(panes: [
            .init(pairId: "A", paneId: "%0"): pane("%0", session: "old"),
            .init(pairId: "B", paneId: "%0"): pane("%0", session: "new"),
        ])
        let page = RemoteBrowserTab(
            id: UUID(),
            sessionName: "new",
            title: "Page",
            url: "about:blank",
            isLoading: false,
            isAgentOwned: false,
            sourcePaneID: "%0"
        )
        #expect(!structure.canSyncBrowserCatalog([page], hostID: "A", sessionName: "old"))
        #expect(!structure.canSyncBrowserCatalog([page], hostID: "A", sessionName: "new"))
        #expect(structure.canSyncBrowserCatalog([page], hostID: "B", sessionName: "new"))
        #expect(structure.canSyncBrowserCatalog([], hostID: "A", sessionName: "old"), "Empty catalogs must still remove closed pages")
        #expect(!structure.canSyncBrowserCatalog([], hostID: "missing", sessionName: "old"))
    }

    @Test("Host snapshots reach all mounted scenes before stale-session cleanup", arguments: [false, true])
    func allScenesObserveRename(filesOnly: Bool) async throws {
        _ = NSApplication.shared
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "A", paneStates: ["%0": pane("%0", session: "old")]))
        store.handleStateUpdate(.init(pairId: "B", paneStates: ["%0": pane("%0", session: "old")]))
        let target = try #require(DetachedTerminalTarget(hostID: "A", windowID: "@0"))
        let detached = DetachedTerminalWorkspace(target: target, sessionName: "old")
        if filesOnly {
            detached.members = []
        }
        let mainTabs = WorkbenchTabStore()
        let scenes = [ProbeState(tabs: mainTabs), ProbeState(tabs: detached.tabs, detached: detached), ProbeState(tabs: WorkbenchTabStore(), hostID: "B")]
        let windows = scenes.map { state in
            let window = NSWindow(
                contentRect: .init(x: -10_000, y: -10_000, width: 100, height: 100),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Probe(store: store, state: state))
            window.contentView?.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.close() } }
        await Task.yield()
        store.handleStateUpdate(.init(pairId: "A", paneStates: ["%0": pane("%0", session: "new")]))
        for _ in 0..<50 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            if scenes.allSatisfy({ $0.prunes == 1 }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scenes.allSatisfy { $0.prunes == 1 })
        for state in scenes.prefix(2) {
            #expect(state.sessionName == "new")
            #expect(state.tabs.existing(hostID: "A", session: "old") == nil)
            #expect(state.tabs.existing(hostID: "A", session: "new") === state.originalTabs)
            #expect(state.originalTabs.selectedFileTabId == state.file.id)
            #expect(state.originalTabs.openFileTabs.first?.origin == .terminalWindow("new:0"))
        }
        #expect(detached.sessionName == "new")
        #expect(scenes[2].sessionName == "old")
        #expect(scenes[2].tabs.existing(hostID: "B", session: "old") === scenes[2].originalTabs)
    }

    @MainActor
    final private class ProbeState {
        let tabs: WorkbenchTabStore
        let detached: DetachedTerminalWorkspace?
        let hostID: String
        var sessionName = "old"
        let file = OpenFileTab(path: "/project", directoryPath: "/project", origin: .terminalWindow("old:0"), isDirectory: true)
        let originalTabs: SessionFileTabsState
        var prunes = 0

        init(tabs: WorkbenchTabStore, detached: DetachedTerminalWorkspace? = nil, hostID: String = "A") {
            self.tabs = tabs
            self.detached = detached
            self.hostID = hostID
            self.originalTabs = tabs.tabs(hostID: hostID, session: "old")
            originalTabs.openFileTabs = [file]
            originalTabs.selectedFileTabId = file.id
        }

        func rename(host: String, mapping: SessionRenameMapping) {
            detached?.renameSession(hostID: host, from: mapping.oldName, to: mapping.newName, windowIDs: mapping.windowIDs)
            tabs.renameSession(hostID: host, from: mapping.oldName, to: mapping.newName, windowIDs: mapping.windowIDs)
            if hostID == host, sessionName == mapping.oldName {
                sessionName = mapping.newName
            }
        }
    }

    private struct Probe: View {
        let store: SessionStore
        let state: ProbeState
        var body: some View {
            Text("Remote workspace")
                .modifier(RemoteSessionStructureModifier(structure: .init(panes: store.paneStates), onRename: state.rename, onSyncBrowserTabs: { }) {
                    // The same ordering required by MainView's stale tab cleanup.
                    #expect(store.sessions(for: state.hostID).contains { $0.sessionName == state.sessionName })
                    state.prunes += 1
                })
        }
    }
}
