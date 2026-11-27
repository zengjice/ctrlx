import AppKit
import CtrlxNetworking
import Foundation
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentForkShortcutTests {
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
