#if os(macOS)
    import AppKit
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
