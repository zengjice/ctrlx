#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Agent Browser background parent")
    struct AgentBrowserParkingWindowTests {
        enum Presentation: CaseIterable {
            case front
            case back
            case regardless
            case keyAndFront
            case above
            case below

            @MainActor
            func perform(on window: NSWindow) {
                switch self {
                case .front: window.orderFront(nil)
                case .back: window.orderBack(nil)
                case .regardless: window.orderFrontRegardless()
                case .keyAndFront: window.makeKeyAndOrderFront(nil)
                case .above: window.order(.above, relativeTo: 0)
                case .below: window.order(.below, relativeTo: 0)
                }
            }
        }

        @Test("Background parents refuse presentation and keyboard focus", arguments: Presentation.allCases)
        func refusesPresentation(_ presentation: Presentation) throws {
            let service = AgentBrowserService()
            let view = try #require(service.browserContainer(forRoute: ["session": "fixture"]))
            let window = try #require(view.window)
            defer { window.orderOut(nil) }

            presentation.perform(on: window)

            #expect(!window.isVisible)
            #expect(!window.isKeyWindow && !window.isMainWindow)
            #expect(!window.canBecomeKey && !window.canBecomeMain)
            #expect(window.isExcludedFromWindowsMenu)
            #expect(view.window === window)
            #expect(view.bounds.size == NSSize(width: 1_000, height: 700))
        }

        @Test("A late workspace registration reattaches an already mounted browser surface")
        func lateWorkspaceMove() async throws {
            _ = NSApplication.shared
            let service = AgentBrowserService()
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let id = UUID().uuidString
            let route = ["session": "fixture", "workspace": workspace.id.uuidString, "pane": "%1"]
            let view = try #require(service.browserContainer(forRoute: route))
            service.browserTabCreated(id, view: view, route: route, owner: "fixture", parent: nil)
            let tab = try #require(service.tabs[id])
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let destinationID = UUID()
            window.contentView = NSHostingView(rootView: AgentBrowserTabContentView(state: tab, workspaceID: destinationID))
            window.orderBack(nil)
            defer {
                window.close()
                service.browserTabClosed(id)
                service.unregister(workspace)
            }
            #expect(tab.view.window !== window)

            // The destination can mount before its workspace registration parks the old presentation.
            tab.workspaceID = destinationID
            service.park(tab)
            try await wait(window) { tab.view.window === window }
            #expect(!tab.isClosed)
        }

        @Test("An old browser surface cannot take the page back when its environment updates")
        func retiringSurfaceKeepsTheNewParent() async throws {
            _ = NSApplication.shared
            let service = AgentBrowserService()
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let route = ["session": "fixture", "workspace": workspace.id.uuidString, "pane": "%1"]
            let view = try #require(service.browserContainer(forRoute: route))
            let id = UUID().uuidString
            service.browserTabCreated(id, view: view, route: route, owner: "fixture", parent: nil)
            let tab = try #require(service.tabs[id])
            func surface(_ scheme: ColorScheme) -> some View {
                AgentBrowserTabContentView(state: tab, workspaceID: workspace.id).environment(\.colorScheme, scheme)
            }
            let source = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            let destination = NSWindow(contentRect: source.frame, styleMask: .borderless, backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false
            destination.isReleasedWhenClosed = false
            let sourceView = NSHostingView(rootView: surface(.dark))
            source.contentView = sourceView
            source.orderBack(nil)
            defer {
                source.close()
                destination.close()
                service.browserTabClosed(id)
                service.unregister(workspace)
            }
            try await wait(source) { view.window === source }
            let destinationID = UUID()
            destination.contentView = NSHostingView(rootView: AgentBrowserTabContentView(state: tab, workspaceID: destinationID))
            destination.orderBack(nil)
            destination.contentView?.layoutSubtreeIfNeeded()
            tab.workspaceID = destinationID
            service.park(tab)
            try await wait(destination) { view.window === destination }

            sourceView.rootView = surface(.light)
            sourceView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(view.window === destination)
            source.contentView = nil
            try await Task.sleep(for: .milliseconds(100))
            #expect(view.window === destination && !tab.isClosed)
        }

        private func wait(_ window: NSWindow, until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !predicate(), ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(predicate())
        }

        @Test("Parking a previously displayed page retains its native parent and size without revealing it")
        func parksExistingPage() throws {
            let service = AgentBrowserService()
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let route = ["session": "fixture", "workspace": workspace.id.uuidString, "pane": "%1"]
            let view = try #require(service.browserContainer(forRoute: route))
            let parkingWindow = try #require(view.window)
            let id = UUID().uuidString
            service.browserTabCreated(id, view: view, route: route, owner: "fixture", parent: nil)
            let tab = try #require(service.tabs[id])
            let foreground = NSView(frame: NSRect(x: 0, y: 0, width: 1_320, height: 876))
            foreground.addSubview(view)
            view.frame = foreground.bounds

            service.park(tab)

            #expect(view.window === parkingWindow)
            #expect(view.frame == foreground.bounds)
            #expect(!view.isHidden && !tab.isClosed)
            #expect(!parkingWindow.isVisible)
            service.browserTabClosed(id)
            service.unregister(workspace)
        }
    }
#endif
