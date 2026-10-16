import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct TerminalNotificationNavigationTests {
    @Test(arguments: [nil, "host-a", "host-b"] as [String?])
    func revealsOnlyTheOwningHostAndTab(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let main = TrackingWindow()
        manager.attach(main, toWorkspace: nil)
        var groups: [(host: String?, workspace: DetachedTerminalWorkspace, window: TrackingWindow)] = []
        for hostID in [nil, "host-a", "host-b"] as [String?] {
            let target = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@1"))
            manager.reserve(target)
            let workspace = try #require(manager.workspace(containing: target))
            let second = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@2"))
            #expect(manager.merge(second, into: workspace.id, session: { _ in "work" }))
            let window = TrackingWindow()
            manager.attach(window, toWorkspace: workspace.id)
            groups.append((hostID, workspace, window))
        }

        let owner = try #require(manager.reveal(
            selection(host: host), localPanes: [localPane()], remoteSessions: remoteSessions()
        ) { Issue.record("An owned detached tab must not open the main window") })
        let selected = try #require(groups.first { $0.host == host })
        #expect(owner == selected.workspace.id)
        #expect(selected.workspace.selection == .window("@1"))
        #expect(selected.window.actions == ["restore", "key", "front"])
        let revision = selected.workspace.selectionRevision
        for _ in 0..<3 {
            #expect(manager.focusNativeWindow(workspaceID: owner))
        }
        #expect(selected.workspace.selectionRevision == revision, "Activation retries must not reselect or refit the tab")
        #expect(main.actions.isEmpty)
        for other in groups where other.host != host {
            #expect(other.workspace.selection == .window("@2"))
            #expect(other.window.actions.isEmpty)
        }
    }

    @Test(arguments: [nil, "host-a"] as [String?])
    func oldNotificationsFollowMovedTabsAndReturnToMain(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let notification = selection(host: host)
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        let original = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        let current = try #require(manager.detach(target, position: nil, session: { _ in "work" }))
        #expect(original.id != current.id)
        #expect(manager.workspaces[original.id] == nil)
        var mainOpens = 0
        func reveal() -> UUID? {
            manager.reveal(notification, localPanes: [localPane()], remoteSessions: remoteSessions()) {
                mainOpens += 1
            }
        }
        #expect(reveal() == current.id)
        #expect(mainOpens == 0)
        manager.returnToMain(target)
        #expect(reveal() == nil)
        #expect(mainOpens == 1)
    }

    @Test(arguments: [nil, "host-a"] as [String?])
    func closedNativeWindowFallsBackToMain(host: String?) throws {
        let manager = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: host, windowID: "@1"))
        manager.reserve(target)
        let window = TrackingWindow()
        manager.attach(window, to: target)
        window.close()
        var mainOpens = 0
        #expect(manager.reveal(selection(host: host), localPanes: [localPane()], remoteSessions: remoteSessions()) {
            mainOpens += 1
        } == nil)
        #expect(mainOpens == 1)
    }

    @Test
    func missingPanesAndOldHostsDoNotMatchAnotherHostsWindow() throws {
        let manager = DetachedTerminalWindows()
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        manager.reserve(local)
        let selections: [PendingMenuBarSelection] = [
            .local(paneId: "%missing"),
            .remote(hostId: "missing-host", hostName: "Missing", paneId: "%1"),
            .remote(hostId: "host-a", hostName: "A", paneId: "%1"),
        ]
        var mainOpens = 0
        for selection in selections {
            #expect(manager.reveal(selection, localPanes: [localPane()], remoteSessions: remoteSessions(stableID: nil)) {
                mainOpens += 1
            } == nil)
        }
        #expect(mainOpens == selections.count)
    }

    @Test
    func pendingDetachedSceneNeverActivatesMainAndRegistrationSurvivesReparenting() throws {
        let manager = DetachedTerminalWindows()
        let main = TrackingWindow()
        main.contentView = NSHostingView(rootView: WorkbenchWindowRegistration(workspaceID: nil, windows: manager))
        main.contentView?.layoutSubtreeIfNeeded()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@1"))
        manager.reserve(target)
        let owner = try #require(manager.reveal(.local(paneId: "%1"), localPanes: [localPane()], remoteSessions: nil) {
            Issue.record("Reserved ownership must wait for its detached scene")
        })
        var activations = 0
        #expect(!manager.focusNativeWindow(workspaceID: owner) { activations += 1 })
        #expect(activations == 0, "Activating the app without the target window could reveal its unrelated key window")
        #expect(main.actions.isEmpty)

        let detached = TrackingWindow()
        detached.contentView = NSHostingView(rootView: WorkbenchWindowRegistration(workspaceID: owner, windows: manager))
        detached.contentView?.layoutSubtreeIfNeeded()
        detached.contentView = NSView()
        main.contentView = NSView()
        #expect(manager.focusNativeWindow(workspaceID: owner) { activations += 1 })
        #expect(activations == 1)
        #expect(detached.actions == ["restore", "key", "front"])
        #expect(main.actions.isEmpty)
        #expect(manager.focusNativeWindow(workspaceID: nil))
        #expect(main.actions == ["restore", "key", "front"])
        #expect(!manager.focusNativeWindow(workspaceID: UUID()) { activations += 1 })
        #expect(activations == 1)
        #expect(main.actions.count == 3)
    }

    private func selection(host: String?) -> PendingMenuBarSelection {
        host.map { .remote(hostId: $0, hostName: $0, paneId: "%1") } ?? .local(paneId: "%1")
    }

    private func localPane() -> PaneInfo {
        PaneInfo(
            paneId: "%1", target: "renamed:7.0", sessionName: "renamed", windowIndex: 7,
            tmuxWindowId: "@1", paneIndex: 0, command: "zsh", currentPath: "/tmp",
            width: 80, height: 24, isActive: true
        )
    }

    private func remoteSessions(stableID: String? = "@1") -> SessionStore {
        let store = SessionStore()
        for host in ["host-a", "host-b"] {
            store.handleStateUpdate(SessionStateMessage(pairId: host, paneStates: [
                "%1": PaneState(paneId: "%1", sessionName: "renamed", windowIndex: 7, tmuxWindowId: stableID),
            ]))
        }
        return store
    }

    final private class TrackingWindow: NSWindow {
        var actions: [String] = []

        init() {
            _ = NSApplication.shared
            super.init(contentRect: .init(x: 100, y: 100, width: 500, height: 300), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }

        override func deminiaturize(_ sender: Any?) {
            actions.append("restore")
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            actions.append("key")
        }

        override func orderFrontRegardless() {
            actions.append("front")
        }
    }
}
