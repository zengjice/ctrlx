import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct RemoteBrowserOwnershipRenameTests {
    @Test(arguments: [false, true], [false, true])
    func movedBrowserKeepsItsOwnerAcrossSceneRenameOrder(sourceFirst: Bool, onRight: Bool) async throws {
        _ = NSApplication.shared
        let manager = DetachedTerminalWindows()
        let store = SessionStore()
        let sourceTarget = try #require(DetachedTerminalTarget(hostID: "host", windowID: "@0"))
        let destinationTarget = try #require(DetachedTerminalTarget(hostID: "host", windowID: "@1"))
        let source = try #require(manager.detach(
            sourceTarget, position: nil, session: { _ in "old" }
        ))
        let destination = try #require(manager.detach(
            destinationTarget, position: nil, session: { _ in "old" }
        ))
        let id = UUID()
        let oldPage = page(id: id, session: "old")
        source.tabs.tabs(hostID: "host", session: "old").syncHostBrowserTabs([oldPage], sessionWindowIDs: ["@0"])
        #expect(manager.transfer(
            .init(workspaceID: source.id, hostID: "host", sessionName: "old", tab: .browser(id)),
            to: destination.id, session: { _ in "old" }
        ))
        let tabs = destination.tabs.tabs(hostID: "host", session: "old")
        tabs.tabOrder = [.browser(id), .window("@1")]
        tabs.splitRatio = 0.65
        if onRight {
            tabs.rightSide = [.browser(id)]
            tabs.selectedRight = .browser(id)
        } else {
            tabs.selectedBrowserTabId = id
        }
        store.handleStateUpdate(.init(pairId: "host", paneStates: panes(session: "old")))
        let states = [source, destination].map {
            ProbeState(manager: manager, store: store, workspace: $0, catalog: [oldPage])
        }
        let windows = states.map { state in
            let window = NSWindow(
                contentRect: .init(x: -10_000, y: -10_000, width: 120, height: 100),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Probe(state: state))
            window.orderBack(nil)
            return window
        }
        defer { windows.forEach { $0.close() } }
        try await wait(windows) { states.allSatisfy { $0.syncs > 0 } }

        store.handleStateUpdate(.init(pairId: "host", paneStates: panes(session: "new")))
        // Deliver to one native scene first, with a full render before the second.
        // The other scene's private selection still refers to the old session.
        for index in sourceFirst ? [0, 1] : [1, 0] {
            let state = states[index]
            state.structure = RemoteSessionStructure(panes: store.paneStates)
            state.catalog = [page(id: id, session: "new")]
            try await wait(windows) { state.sessionName == "new" && state.newSessionSyncs > 0 }
            #expect(manager.browserOwner(hostID: "host", session: "new", id: id, windowID: "@0") == destination.id)
        }

        // Further catalogs must not make an incorrect ownership decision permanent.
        for state in states {
            state.sync()
            #expect(state.workspace.sessionName == "new")
            #expect(state.workspace.tabs.existing(hostID: "host", session: "old") == nil)
        }
        #expect(source.tabs.existing(hostID: "host", session: "new")?.openBrowserTabs.isEmpty == true)
        #expect(destination.tabs.existing(hostID: "host", session: "new") === tabs)
        #expect(tabs.openBrowserTabs.map(\.id) == [id])
        #expect(tabs.remoteBrowserTabs[id]?.sessionName == "new")
        #expect(tabs.tabOrder == [.browser(id), .window("@1")])
        #expect(tabs.splitRatio == 0.65)
        if onRight {
            #expect(tabs.selectedRight == .browser(id))
            #expect(tabs.rightSide == [.browser(id)])
        } else {
            #expect(tabs.selectedBrowserTabId == id)
        }
    }

    private func page(id: UUID, session: String) -> RemoteBrowserTab {
        .init(
            id: id,
            sessionName: session,
            windowID: "@0",
            title: "Moved page",
            url: "about:blank",
            isLoading: false,
            isAgentOwned: false,
            sourcePaneID: "%0"
        )
    }

    private func panes(session: String) -> [String: PaneState] {
        Dictionary(uniqueKeysWithValues: (0...1).map { index in
            ("%\(index)", PaneState(paneId: "%\(index)", sessionName: session, windowIndex: index, tmuxWindowId: "@\(index)"))
        })
    }

    private func wait(_ windows: [NSWindow], until condition: () -> Bool) async throws {
        for _ in 0..<200 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for scene rename")
    }

    @MainActor @Observable
    final class ProbeState {
        let manager: DetachedTerminalWindows
        let store: SessionStore
        let workspace: DetachedTerminalWorkspace
        var structure: RemoteSessionStructure
        var catalog: [RemoteBrowserTab]
        var sessionName = "old"
        @ObservationIgnored var syncs = 0
        @ObservationIgnored var newSessionSyncs = 0

        init(manager: DetachedTerminalWindows, store: SessionStore, workspace: DetachedTerminalWorkspace, catalog: [RemoteBrowserTab]) {
            self.manager = manager
            self.store = store
            self.workspace = workspace
            self.structure = RemoteSessionStructure(panes: store.paneStates)
            self.catalog = catalog
        }

        func rename(host: String, mapping: SessionRenameMapping) {
            manager.renameSession(hostID: host, from: mapping.oldName, to: mapping.newName, windowIDs: mapping.windowIDs)
            sessionName = mapping.newName
        }

        func sync() {
            guard RemoteSessionStructure(panes: store.paneStates).canSyncBrowserCatalog(catalog, hostID: "host", sessionName: sessionName) else { return }
            let values = catalog.filter {
                $0.sessionName == sessionName && manager.browserOwner(hostID: "host", session: sessionName, id: $0.id, windowID: $0.windowID) == workspace.id
            }
            workspace.tabs.tabs(hostID: "host", session: sessionName).syncHostBrowserTabs(values, sessionWindowIDs: workspace.members.map(\.windowID))
            syncs += 1
            if sessionName == "new" {
                newSessionSyncs += 1
            }
        }
    }

    private struct Probe: View {
        let state: ProbeState

        var body: some View {
            Text(state.sessionName)
                .modifier(RemoteSessionStructureModifier(
                    structure: state.structure,
                    browserCatalogs: ["host": state.catalog],
                    selection: .init(hostId: "host", hostName: "Host", sessionName: state.sessionName),
                    onRename: state.rename,
                    onSyncBrowserTabs: state.sync,
                    onPrune: { }
                ))
        }
    }
}
