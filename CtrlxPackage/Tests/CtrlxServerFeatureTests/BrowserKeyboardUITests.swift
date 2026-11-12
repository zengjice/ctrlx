import AppKit
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxCommon
@testable import CtrlxServerFeature

@MainActor @Suite(.serialized)
struct BrowserKeyboardUITests {
    final class Window: NSWindow {
        override var isKeyWindow: Bool {
            true
        }
    }

    @Test("Host shortcuts use the current tab; Command-L selects the address on every invocation")
    func hostNavigationAndAddress() async throws {
        try await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let (service, runtime, descriptor) = try await RemoteBrowserControlTests().fixture()
            _ = service.bookmarks
            let state = try #require(service.tabs[descriptor.id.uuidString])
            state.requestsInitialAddressFocus = false
            state.url = "https://example.com/path?q=中文"
            let window = mount(AgentBrowserTabContentView(state: state, workspaceID: state.workspaceID))
            defer { window.close()
                service.browserTabClosed(state.identifier)
            }
            let root = try #require(window.contentView)
            try await wait { self.anchors(in: root).count == 1 }
            let anchor = try #require(anchors(in: root).first)
            try await wait { anchor.isEnabled }
            for key in ["r", "[", "]"] {
                #expect(try anchor.handle(event(key, in: window)) == nil)
            }
            #expect(runtime.navigations.map(\.0) == Array(repeating: state.identifier, count: 3))
            #expect(runtime.navigations.map(\.1) == ["reload", "back", "forward"])
            #expect(try anchor.handle(event("l", in: window)) == nil)
            try await wait("initial address selection") {
                guard let editor = window.firstResponder as? NSTextView else { return false }
                return editor.string == state.url && editor.selectedRange() == NSRange(location: 0, length: (state.url as NSString).length)
            }
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            try await Task.sleep(for: .milliseconds(50))
            #expect(try anchor.handle(event("l", in: window)) == nil)
            try await wait("repeat address selection") { editor.selectedRange().length == (state.url as NSString).length }
            state.isRemotelyControlled = true
            #expect(try anchor.handle(event("r", in: window)) == nil)
            #expect(runtime.navigations.count == 3)
            try await wait { !anchor.isEnabled }
            #expect(try anchor.handle(event("r", in: window)) == nil)
            #expect(runtime.navigations.count == 3)
        }
    }

    @Test("Changing the focused split updates the mounted shortcut scope without remounting pages")
    func splitScope() async throws {
        let tabs = SessionFileTabsState()
        tabs.rightSide = [.browser(UUID())]
        var left = 0, right = 0
        let view = SplitDetailContent(sessionTabs: tabs, left: {
            Text("Left Browser").browserKeyboardShortcuts(isEnabled: true) { _ in left += 1 }
        }, right: {
            Text("Right Browser").browserKeyboardShortcuts(isEnabled: true) { _ in right += 1 }
        })
        let window = mount(view)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await wait { self.anchors(in: root).count == 2 }
        let mounted = anchors(in: root)
        let first = try #require(mounted.first { $0.isActive })
        let key = try event("r", in: window)
        for anchor in mounted {
            _ = anchor.handle(key)
        }
        #expect(left == 1 && right == 0)
        tabs.isRightPaneFocused = true
        try await wait { !first.isActive && mounted.filter(\.isActive).count == 1 }
        for anchor in mounted {
            _ = anchor.handle(key)
        }
        #expect(left == 1 && right == 1)
        #expect(Set(anchors(in: root).map(ObjectIdentifier.init)) == Set(mounted.map(ObjectIdentifier.init)))
    }

    private func mount(_ view: some View) -> Window {
        _ = NSApplication.shared
        let window = Window(contentRect: .init(x: -10_000, y: -10_000, width: 1_200, height: 700), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    private func anchors(in view: NSView) -> [BrowserKeyboardShortcutView] {
        (view as? BrowserKeyboardShortcutView).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
    }

    private func event(_ key: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 15))
    }

    private func wait(_ message: String = "Browser UI did not settle", _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "\(message)")
    }
}
