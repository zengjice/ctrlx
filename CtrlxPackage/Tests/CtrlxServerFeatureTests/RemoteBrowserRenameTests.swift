import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct RemoteBrowserRenameTests {
    @Test(arguments: [false, true], ["together", "catalogFirst", "panesFirst"])
    func renameRefreshesBothBrowserSurfaces(detached: Bool, delivery: String) async throws {
        _ = NSApplication.shared
        let state = try ProbeState(detached: detached)
        let window = NSWindow(
            contentRect: .init(x: -10_000, y: -10_000, width: 120, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Probe(state: state))
        window.orderBack(nil)
        defer { window.close() }
        try await wait(window) { state.hasRequests(session: "old", operation: .takeControl) }

        if delivery == "panesFirst" {
            state.store.handleStateUpdate(.init(pairId: "host", paneStates: ["%0": state.pane(session: "new")]))
            try await wait(window) { state.sessionName == "new" }
            state.catalog = state.pages(session: "new")
        } else {
            // ViewerRelayClient publishes the catalog before forwarding the pane snapshot.
            state.catalog = state.pages(session: "new")
            if delivery == "catalogFirst" {
                try await wait(window) { state.deferredSyncs > 0 }
                #expect(state.originalTabs.selectedBrowserTabId == state.leftID)
                #expect(state.originalTabs.selectedRight == .browser(state.rightID))
            }
            state.store.handleStateUpdate(.init(pairId: "host", paneStates: ["%0": state.pane(session: "new")]))
        }
        try await wait(window) { state.hasRequests(session: "new", operation: .takeControl) }

        #expect(state.sessionName == "new")
        #expect(state.tabs.existing(hostID: "host", session: "old") == nil)
        #expect(state.tabs.existing(hostID: "host", session: "new") === state.originalTabs)
        #expect(state.originalTabs.remoteBrowserTabs.values.allSatisfy { $0.sessionName == "new" })
        #expect(state.originalTabs.selectedBrowserTabId == state.leftID)
        #expect(state.originalTabs.selectedRight == .browser(state.rightID))
        #expect(state.originalTabs.rightSide == [.browser(state.rightID)])
        #expect(state.originalTabs.tabOrder == [.browser(state.rightID), .browser(state.leftID)])
        #expect(state.originalTabs.splitRatio == 0.65)
        #expect(state.hasRequests(session: "new", operation: .frame))
        if detached {
            #expect(state.workspace?.sessionName == "new")
        }
    }

    private func wait(_ window: NSWindow, until condition: () -> Bool) async throws {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Timed out waiting for renamed browser surfaces")
    }

    @MainActor @Observable
    final class ProbeState {
        let store = SessionStore()
        let tabs: WorkbenchTabStore
        let workspace: DetachedTerminalWorkspace?
        let originalTabs: SessionFileTabsState
        let leftID = UUID()
        let rightID = UUID()
        var sessionName = "old"
        var catalog: [RemoteBrowserTab] = []
        @ObservationIgnored var requests: [BrowseBrowser] = []
        @ObservationIgnored var deferredSyncs = 0

        init(detached: Bool) throws {
            self.workspace = try detached ? DetachedTerminalWorkspace(
                target: #require(DetachedTerminalTarget(hostID: "host", windowID: "@0")), sessionName: "old"
            ) : nil
            self.tabs = workspace?.tabs ?? WorkbenchTabStore()
            self.originalTabs = tabs.tabs(hostID: "host", session: "old")
            self.catalog = pages(session: "old")
            store.handleStateUpdate(.init(pairId: "host", paneStates: ["%0": pane(session: "old")]))
            sync(host: "host", session: "old")
            originalTabs.selectedBrowserTabId = leftID
            originalTabs.rightSide = [.browser(rightID)]
            originalTabs.selectedRight = .browser(rightID)
            originalTabs.tabOrder = [.browser(rightID), .browser(leftID)]
            originalTabs.splitRatio = 0.65
        }

        func pane(session: String) -> PaneState {
            PaneState(paneId: "%0", sessionName: session, windowIndex: 0, tmuxWindowId: "@0")
        }

        func pages(session: String) -> [RemoteBrowserTab] {
            [leftID, rightID].map {
                RemoteBrowserTab(
                    id: $0,
                    sessionName: session,
                    windowID: "@0",
                    title: "Page",
                    url: "about:blank",
                    isLoading: false,
                    isAgentOwned: false,
                    sourcePaneID: "%0"
                )
            }
        }

        func rename(host: String, mapping: SessionRenameMapping) {
            workspace?.renameSession(hostID: host, from: mapping.oldName, to: mapping.newName, windowIDs: mapping.windowIDs)
            tabs.renameSession(hostID: host, from: mapping.oldName, to: mapping.newName, windowIDs: mapping.windowIDs)
            sessionName = mapping.newName
        }

        func sync(host: String, session: String) {
            guard RemoteSessionStructure(panes: store.paneStates).canSyncBrowserCatalog(catalog, hostID: host, sessionName: session) else {
                deferredSyncs += 1
                return
            }
            tabs.tabs(hostID: host, session: session).syncHostBrowserTabs(
                catalog.filter { $0.sessionName == session }, sessionWindowIDs: ["@0"]
            )
        }

        func send(_ request: BrowseBrowser) async throws -> RemoteBrowserResponse {
            requests.append(request)
            guard let tab = catalog.first(where: { $0.id == request.tabID && $0.sessionName == request.sessionName }) else {
                throw URLError(.resourceUnavailable)
            }
            return .init(
                tab: tab,
                frame: request.operation == .frame ? .init(jpeg: Data([1]), width: 10, height: 10, generation: 1) : nil,
                controlID: request.operation == .takeControl ? UUID() : request.controlID
            )
        }

        func hasRequests(session: String, operation: RemoteBrowserOperation) -> Bool {
            [leftID, rightID].allSatisfy { id in
                requests.contains { $0.tabID == id && $0.sessionName == session && $0.operation == operation }
            }
        }
    }

    private struct Probe: View {
        let state: ProbeState

        var body: some View {
            let session = state.sessionName
            let tabs = state.tabs.existing(hostID: "host", session: session)
            HStack {
                if let id = tabs?.selectedBrowserTabId, let tab = tabs?.remoteBrowserTabs[id] {
                    Surface(tab: tab, state: state).id("\(tab.id):\(tab.sessionName)")
                }
                if case let .browser(id) = tabs?.selectedRight, let tab = tabs?.remoteBrowserTabs[id] {
                    Surface(tab: tab, state: state).id("\(tab.id):\(tab.sessionName)")
                }
            }
            .id(session)
            .modifier(RemoteSessionStructureModifier(
                structure: .init(panes: state.store.paneStates),
                browserCatalogs: ["host": state.catalog],
                selection: .init(hostId: "host", hostName: "Host", sessionName: session),
                onRename: state.rename,
                onSyncBrowserTabs: {
                    state.sync(host: "host", session: state.sessionName)
                },
                onPrune: {
                    #expect(state.tabs.existing(hostID: "host", session: state.sessionName) === state.originalTabs)
                }
            ))
        }
    }

    /// Mirrors RemoteBrowserView's owned session and watch lifecycle, using an injected Host.
    private struct Surface: View {
        @State private var session: RemoteBrowserSession

        init(tab: RemoteBrowserTab, state: ProbeState) {
            _session = State(initialValue: RemoteBrowserSession(tab: tab, send: state.send))
        }

        var body: some View {
            Color.clear
                .task { await session.watch() }
                .onDisappear { session.stop() }
        }
    }
}
