import AppKit
import Testing
@testable import CtrlxServerFeature

struct SessionSwitcherTests {
    @Test("Search matches display titles and hosts without merging same-named sessions")
    func search() {
        let local = SessionSwitcherItem(id: .local(sessionName: "work"), name: "work", title: "Local project", host: "This Mac")
        let remote = SessionSwitcherItem(id: .remote(hostID: "office", sessionName: "work"), name: "work", title: "服务器开发", host: "Office")
        #expect(SessionSwitcherItem.matching([local, remote], query: " work ").map(\.id) == [local.id, remote.id])
        #expect(SessionSwitcherItem.matching([local, remote], query: "OFFICE 开发").map(\.id) == [remote.id])
        #expect(SessionSwitcherItem.matching([local, remote], query: "missing").isEmpty)
        #expect(SessionSwitcherItem.matching([remote, local], query: "  ") == [remote, local])
    }
}

@MainActor
@Suite(.serialized)
struct WorkbenchSplitFocusTests {
    @Test("Native clicks only select a split in their own visible workbench")
    func clickRouting() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkbenchSplitFocusView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let tabs = SessionFileTabsState()
        tabs.rightSide = [.window("@2")]
        tabs.splitRatio = 0.85
        view.tabs = tabs
        window.contentView = view
        defer { view.stop()
            window.close()
        }

        func click(_ x: CGFloat, number: Int) throws {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.record(event)
        }
        try click(850, number: window.windowNumber)
        #expect(tabs.isRightPaneFocused)
        try click(20, number: 0)
        #expect(tabs.isRightPaneFocused)
        try click(200, number: window.windowNumber)
        #expect(!tabs.isRightPaneFocused)
        view.isHidden = true
        try click(850, number: window.windowNumber)
        #expect(!tabs.isRightPaneFocused)
        view.isHidden = false
        tabs.rightSide = []
        try click(850, number: window.windowNumber)
        #expect(!tabs.isRightPaneFocused)
        #expect(view.hitTest(NSPoint(x: 30, y: 30)) == nil)
    }
}
