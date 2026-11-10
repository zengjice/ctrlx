import AppKit
import CtrlxCommon
import CtrlxNetworking
import Observation
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct MainWindowPaneSelectionTests {
    @Test(
        "Notification selects a non-first tab after session layout restoration",
        arguments: [nil, "host-a"] as [String?],
        ["@2", "@3"]
    )
    func notificationWinsLayout(hostID: String?, target: String) async throws {
        let state = ProbeState(hostID: hostID)
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.layoutApplications == 1 }
        state.tabs.selectedFileTabId = UUID()
        state.tabs.selectedBrowserTabId = UUID()
        state.tabs.isGitSelected = true
        state.session = state.destination
        state.store.requestPaneSelection(hostID: hostID, pane: state.pane(target))
        try await settle(window) { state.revealedPanes.count == 1 }
        #expect(state.selectedWindowID == target)
        #expect(state.tabs.selectedFileTabId == nil)
        #expect(state.tabs.selectedBrowserTabId == nil)
        #expect(!state.tabs.isGitSelected)
        #expect(state.events.suffix(2) == ["layout", "pane"])
        #expect(state.store.pendingPaneSelection == nil)
        let applied = state.layoutApplications
        try await settle(window) { state.observedRequestID == nil }
        #expect(state.selectedWindowID == target, "Clearing the request must not restore the first tab again")
        #expect(state.layoutApplications == applied)

        // A later canonical Host update still takes effect; notification priority is one-shot.
        state.layout = .init(leftWindowId: "@1", revision: 2)
        try await settle(window) { state.layoutApplications > applied }
        #expect(state.selectedWindowID == "@1")
        #expect(state.revealedPanes.count == 1)
    }

    @Test("A notification queued before mounting is applied after the initial layout")
    func initialNotification() async throws {
        let state = ProbeState(hostID: "host-a")
        state.session = state.destination
        state.store.requestPaneSelection(hostID: state.hostID, pane: state.pane("@3"))
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.revealedPanes.count == 1 && state.observedRequestID == nil }
        #expect(state.events == ["layout", "pane"])
        #expect(state.selectedWindowID == "@3")
    }

    @Test("Local notification reveals the terminal behind its own Files flag", arguments: [false, true])
    func clearsTargetFilesAfterSharedLayoutSwitch(previousAlsoShowsFiles: Bool) async throws {
        let state = ProbeState(hostID: nil)
        state.session = state.destination
        state.layout = .init(leftWindowId: "@2", revision: 1)
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.layoutApplications == 1 }
        let targetWindowID = state.pane("@2").windowId
        let previousWindowID = state.pane("@1").windowId
        state.legacyExplorerWindows = [targetWindowID, "other:7"]
        #expect(state.isFilesVisible)

        // Host layout switches to B without clearing A's Files presentation.
        state.layout = .init(leftWindowId: "@1", revision: 2)
        try await settle(window) { state.selectedWindowID == "@1" }
        #expect(state.legacyExplorerWindows.contains(targetWindowID))
        if previousAlsoShowsFiles {
            state.legacyExplorerWindows.insert(previousWindowID)
        }
        state.store.requestPaneSelection(hostID: nil, pane: state.pane("@2"))
        try await settle(window) { state.revealedPanes.count == 1 && state.observedRequestID == nil }
        #expect(state.selectedWindowID == "@2")
        #expect(!state.isFilesVisible, "Selecting A must reveal its terminal, not its old Files view")
        #expect(!state.legacyExplorerWindows.contains(previousWindowID))
        #expect(state.legacyExplorerWindows == ["other:7"])
    }

    @Test("Same-session and repeated taps select the target without restoring the default")
    func repeatedSameSessionTap() async throws {
        let state = ProbeState(hostID: "host-a")
        state.session = state.destination
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.layoutApplications == 1 }
        for count in 1...2 {
            state.store.userDidSelectTab(hostID: state.hostID, session: "work")
            state.selectedWindowID = "@3"
            state.store.requestPaneSelection(hostID: state.hostID, pane: state.pane("@2"))
            try await settle(window) { state.revealedPanes.count == count && state.observedRequestID == nil }
            #expect(state.selectedWindowID == "@2")
            #expect(state.layoutApplications == 1)
        }
    }

    @Test("Right-side notification keeps the left tab and selects its own right tab")
    func rightSideSelection() async throws {
        let state = ProbeState(hostID: "host-a")
        state.layout = .init(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1)
        state.session = state.destination
        state.store.requestPaneSelection(hostID: state.hostID, pane: state.pane("@3"))
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.revealedPanes.count == 1 && state.observedRequestID == nil }
        #expect(state.selectedWindowID == "@1")
        #expect(state.tabs.selectedRight == .window("@3"))
        #expect(state.tabs.isRightPaneFocused)
    }

    @Test("User navigation cancels a queued notification", arguments: [false, true])
    func userCancels(selectSession: Bool) {
        let store = WorkbenchTabStore()
        let pane = PaneState(paneId: "%2", sessionName: "work", windowIndex: 2, tmuxWindowId: "@2")
        store.requestPaneSelection(hostID: "host-a", pane: pane)
        if selectSession {
            store.userDidSelectSession()
        } else {
            store.userDidSelectTab(hostID: "host-a", session: "work")
        }
        #expect(store.takePaneSelection(in: .remote(hostID: "host-a", sessionName: "work")) == nil)
    }

    @Test("Private layout hydration completes before notification selection", arguments: [false, true])
    func waitsForLayout(userNavigates: Bool) async throws {
        let state = ProbeState(hostID: "host-a")
        state.session = state.destination
        state.isPaneSelectionReady = false
        state.store.requestPaneSelection(hostID: state.hostID, pane: state.pane("@2"))
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.layoutApplications == 1 }
        #expect(state.revealedPanes.isEmpty)
        #expect(state.store.pendingPaneSelection != nil)
        state.tabs.selectedBrowserTabId = UUID()
        if userNavigates {
            state.store.userDidSelectTab(hostID: state.hostID, session: "work")
            state.selectedWindowID = "@3"
        }
        state.isPaneSelectionReady = true
        try await settle(window) { state.observedRequestID == nil }
        #expect(state.selectedWindowID == (userNavigates ? "@3" : "@2"))
        #expect(state.revealedPanes.count == (userNavigates ? 0 : 1))
        if !userNavigates {
            #expect(state.tabs.selectedBrowserTabId == nil)
        }
    }

    @Test("Requests are scoped by Host and replaced by newer notifications")
    func requestScopeAndReplacement() throws {
        let store = WorkbenchTabStore()
        let first = PaneState(paneId: "%2", sessionName: "work", windowIndex: 2, tmuxWindowId: "@2")
        let latest = PaneState(paneId: "%3", sessionName: "work", windowIndex: 3, tmuxWindowId: "@3")
        store.requestPaneSelection(hostID: "host-a", pane: first)
        #expect(store.takePaneSelection(in: .local(sessionName: "work")) == nil)
        #expect(store.takePaneSelection(in: .remote(hostID: "host-b", sessionName: "work")) == nil)
        store.requestPaneSelection(hostID: "host-a", pane: latest)
        let result = try #require(store.takePaneSelection(in: .remote(hostID: "host-a", sessionName: "work")))
        #expect(result.pane.paneId == "%3")
        #expect(store.takePaneSelection(in: .remote(hostID: "host-a", sessionName: "work")) == nil)
    }

    @Test("A closed notification target is consumed without preventing manual navigation")
    func missingTarget() async throws {
        let state = ProbeState(hostID: "host-a")
        state.session = state.destination
        state.store.requestPaneSelection(hostID: state.hostID, pane: state.pane("@2"))
        state.liveWindowIDs.remove("@2")
        let window = mount(state)
        defer { window.close() }
        try await settle(window) { state.store.pendingPaneSelection == nil && state.layoutApplications == 1 }
        #expect(state.revealedPanes.isEmpty)
        state.store.userDidSelectTab(hostID: state.hostID, session: "work")
        state.selectedWindowID = "@3"
        try await settle(window) { state.observedRequestID == nil }
        #expect(state.selectedWindowID == "@3")
    }

    private func mount(_ state: ProbeState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 160, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Probe(state: state))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for pane selection")
    }

    @MainActor @Observable
    final class ProbeState {
        let hostID: String?
        let store = WorkbenchTabStore()
        let tabs = SessionFileTabsState()
        var session: SidebarSessionSelection? = .local(sessionName: "other")
        var layout = SharedTerminalLayout(leftWindowId: "@1", revision: 1)
        var selectedWindowID = "@1"
        var legacyExplorerWindows: Set<String> = []
        var isPaneSelectionReady = true
        var liveWindowIDs: Set = ["@1", "@2", "@3"]
        @ObservationIgnored var layoutApplications = 0
        @ObservationIgnored var revealedPanes: [String] = []
        @ObservationIgnored var events: [String] = []
        @ObservationIgnored var observedRequestID: UUID?

        init(hostID: String?) {
            self.hostID = hostID
        }

        var destination: SidebarSessionSelection {
            if let hostID {
                .remote(hostID: hostID, sessionName: "work")
            } else {
                .local(sessionName: "work")
            }
        }

        func pane(_ windowID: String) -> PaneState {
            PaneState(paneId: "%\(windowID.dropFirst())", sessionName: "work", windowIndex: Int(windowID.dropFirst()) ?? 0, tmuxWindowId: windowID)
        }

        var isFilesVisible: Bool {
            legacyExplorerWindows.contains(pane(selectedWindowID).windowId)
        }
    }

    private struct Probe: View {
        let state: ProbeState

        var body: some View {
            Text(state.isFilesVisible ? "Files" : "Terminal")
                .modifier(SharedTerminalLayoutObserversModifier(
                    session: state.session,
                    layout: state.layout,
                    pendingPaneSelectionID: state.store.pendingPaneSelection?.id,
                    isPaneSelectionReady: state.isPaneSelectionReady,
                    onLayoutChanged: { session in
                        guard session == state.session else { return }
                        state.layoutApplications += 1
                        state.events.append("layout")
                        state.tabs.applySharedTerminalLayout(state.layout, liveWindowIds: state.liveWindowIDs)
                        state.selectedWindowID = state.layout.leftWindowId
                    },
                    onSelectPane: { session, id in
                        guard
                            session == state.session, state.store.pendingPaneSelection?.id == id,
                            let request = state.store.takePaneSelection(in: session),
                            state.liveWindowIDs.contains(request.pane.stableWindowId) else { return }
                        state.events.append("pane")
                        state.revealedPanes.append(request.pane.paneId)
                        let onRight = state.tabs.rightSide.contains(.window(request.pane.stableWindowId))
                        state.tabs.isRightPaneFocused = onRight
                        if onRight {
                            state.tabs.selectedRight = .window(request.pane.stableWindowId)
                        } else {
                            let selected = if request.hostID == nil {
                                state.tabs.selectLeftTerminalWindow(
                                    request.pane.stableWindowId, windowID: request.pane.windowId,
                                    previousWindowID: state.pane(state.selectedWindowID).windowId,
                                    legacyExplorerWindows: &state.legacyExplorerWindows
                                )
                            } else {
                                state.tabs.selectLeftTerminalWindow(request.pane.stableWindowId)
                            }
                            if selected {
                                state.selectedWindowID = request.pane.stableWindowId
                            }
                        }
                    },
                    onDisappear: { }
                ))
                .onChange(of: state.store.pendingPaneSelection?.id, initial: true) { _, id in
                    state.observedRequestID = id
                }
        }
    }
}
