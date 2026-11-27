import AppKit
import CtrlxCommon
import CtrlxNetworking
import Foundation
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentForkShortcutTests {
    @Test("A retained quick Fork action resolves the current source and connection when invoked", arguments: [false, true], [false, true])
    func actionResolvesCurrentTarget(changesHost: Bool, available: Bool) throws {
        let oldSource = try #require(AgentForkSource(pane: .init(
            paneId: "%1", sessionName: "old", tmuxWindowId: "@1", currentPath: "/old",
            agentSession: .init(paneId: "%1", pluginID: "codex"), claudeSessionID: UUID().uuidString
        )))
        let source = try #require(AgentForkSource(pane: .init(
            paneId: "%2", sessionName: "work", tmuxWindowId: "@2", currentPath: "/current",
            agentSession: .init(paneId: "%2", pluginID: "codex"), claudeSessionID: UUID().uuidString
        )))
        var inputState = ViewerWorkspaceInputState()
        inputState.update(.init(pairId: "current-pair", paneStates: [:]))
        let latest = AgentForkShortcut.Target(
            source: source, tabName: "Current", hostID: changesHost ? "current-host" : nil, inputState: changesHost ? inputState : nil
        )
        var current: AgentForkShortcut.Target? = .init(source: oldSource, tabName: "Old", hostID: nil, inputState: nil)
        var resolved = 0
        var launched: (AgentForkShortcut.Target, ForkAgentSession)?
        let action = AgentForkShortcut.action(resolve: { resolved += 1
            return current
        }) { launched = ($0, $1) }
        #expect(resolved == 0)

        current = available ? latest : nil
        action()

        #expect(resolved == 1)
        if available {
            let (target, request) = try #require(launched)
            #expect(target.source == source && request.source == source)
            #expect(target.hostID == latest.hostID && target.inputState == latest.inputState)
            #expect(request.windowName?.hasPrefix("Current-") == true)
            #expect(request.inheritsSourceConfiguration == true)
        } else {
            #expect(launched == nil)
        }
    }

    @Test("Quick Fork adopts its right terminal without reselecting the detached workspace", arguments: [nil, "host"] as [String?], [false, true])
    func detachedForkPreservesSource(hostID: String?, sourceOnRight: Bool) throws {
        let manager = DetachedTerminalWindows()
        let earlier = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@1"))
        let source = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@2"))
        let fork = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@3"))
        manager.reserve(earlier)
        let workspace = try #require(manager.workspace(containing: earlier))
        try #require(manager.merge(source, into: workspace.id, session: { _ in "work" }))
        let tabs = workspace.tabs.tabs(hostID: hostID, session: "work")
        if sourceOnRight {
            tabs.rightSide.insert(.window(source.windowID))
            tabs.selectedRight = .window(source.windowID)
        }
        let revision = workspace.selectionRevision

        try #require(manager.merge(fork, into: workspace.id, select: false, session: { _ in "work" }))
        tabs.showForkSplit(sourceWindowID: source.windowID, forkWindowID: fork.windowID)

        #expect(manager.workspace(containing: fork) === workspace)
        #expect(Set(workspace.members) == [earlier, source, fork])
        #expect(workspace.selection == .window(source.windowID))
        #expect(workspace.selectionRevision == revision)
        #expect(!tabs.rightSide.contains(.window(source.windowID)))
        #expect(tabs.selectedRight == .window(fork.windowID))
        #expect(tabs.splitRatio == 0.5 && tabs.isRightPaneFocused)
    }

    @Test("The native workbench renders source and Fork side by side at 1:1")
    func nativeSplitGeometry() async throws {
        _ = NSApplication.shared
        let tabs = SessionFileTabsState()
        tabs.showForkSplit(sourceWindowID: "@1", forkWindowID: "@2")
        var frames: [String: CGRect] = [:]
        let view = SplitDetailContent(sessionTabs: tabs) {
            Text("Source").frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames["source"] = $0 }
        } right: {
            Text("Fork").frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames["fork"] = $0 }
        }
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        let source = try #require(frames["source"])
        let fork = try #require(frames["fork"])
        #expect(abs(source.width - fork.width) < 1)
        #expect(abs(source.width - 448) < 1)
        #expect(source.maxX <= fork.minX && source.height == fork.height)
    }

    @Test("Quick Fork names the new tab from its source and keeps all destinations unchanged")
    func request() throws {
        let source = try #require(AgentForkSource(pane: .init(paneId: "%1", sessionName: "work", tmuxWindowId: "@1", currentPath: "/source", agentSession: .init(paneId: "%1", pluginID: "codex"), claudeSessionID: UUID().uuidString)))
        let request = try AgentForkShortcut.request(source: source, tabName: "我的 tab", date: Date(timeIntervalSince1970: 0), timeZone: #require(TimeZone(secondsFromGMT: 0)))
        #expect(request.windowName == "我的 tab-19700101-000000-000")
        #expect(request.source == source && request.inheritsSourceConfiguration == true)
        #expect(request.workingDirectory == nil && request.worktree == nil && request.targetProviderID == nil)
        try request.validateName()
    }

    @Test("Fork displays source left and new tab right at equal width, including a right-side source", arguments: [false, true])
    func split(sourceOnRight: Bool) throws {
        let tabs = SessionFileTabsState()
        let browser = UUID()
        tabs.rightSide = [.browser(browser), .window("@3")]
        if sourceOnRight {
            tabs.rightSide.insert(.window("@1"))
        }
        tabs.splitRatio = 0.73
        let shared = SharedTerminalLayout(leftWindowId: "@2", rightWindowIds: sourceOnRight ? ["@1", "@3"] : ["@3"], selectedRightWindowId: "@3", splitRatio: 0.73, revision: 1)
        tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2", "@3", "@4"])
        tabs.placeRemoteTerminal("@1", onRight: false, sessionWindowIDs: ["@1", "@2", "@3", "@4"])
        tabs.placeRemoteTerminal("@4", onRight: true, sessionWindowIDs: ["@1", "@2", "@3", "@4"])
        tabs.showForkSplit(sourceWindowID: "@1", forkWindowID: "@4")
        tabs.recordRemoteLeftTerminalSelection("@1")
        tabs.recordRemoteSplitRatio(0.5)
        let request = try #require(tabs.remoteTerminalLayoutRequest(sessionName: "work", sessionWindowIDs: ["@1", "@2", "@3", "@4"], visibleWindowIDs: ["@1", "@2", "@3", "@4"], selectedLeftWindowID: "@1", shared: shared))
        #expect(request.leftWindowId == "@1" && request.rightWindowIds.contains("@4"))
        #expect(request.selectedRightWindowId == "@4" && request.splitRatio == 0.5)
        #expect(tabs.selectedRight == .window("@4") && tabs.isRightPaneFocused)
        #expect(!tabs.rightSide.contains(.window("@1")))
        #expect(tabs.rightSide.contains(.browser(browser)))
    }
}
