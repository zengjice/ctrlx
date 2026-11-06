#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct DirectorySessionFormTests {
        private static let codex = SessionLaunchAgent(
            id: "codex", name: "Codex",
            providers: [.init(id: "openai", name: "OpenAI"), .init(id: "custom", name: "Custom")],
            defaultProviderID: "custom"
        )

        @Test("Directory launches default to OpenAI even when Host agents arrive after the form appears", arguments: [false, true])
        func defaultProvider(agentsArriveLate: Bool) async throws {
            let fixture = Fixture(agents: agentsArriveLate ? [] : [Self.codex])
            defer { fixture.window.close() }
            try await fixture.wait { fixture.state.appeared }
            if agentsArriveLate {
                fixture.state.agents = [Self.codex]
            }
            _ = try await fixture.element("new-session-provider")
            try await fixture.submit()
            let request = try #require(fixture.state.requests.first)
            #expect(request.project?.pluginID == "codex")
            #expect(request.providerID == "openai")
        }

        @Observable @MainActor
        final class State {
            var agents: [SessionLaunchAgent]
            var appeared = false
            var requests: [SessionLaunchRequest] = []

            init(agents: [SessionLaunchAgent]) {
                self.agents = agents
            }
        }

        private struct Surface: View {
            @Bindable var state: State

            var body: some View {
                DirectorySessionForm(
                    agents: state.agents,
                    directorySource: .init(id: "host", unavailableReason: "Directory browsing is disabled in this fixture.") { _ in
                        Issue.record("This fixture must not access the Host filesystem")
                        throw CancellationError()
                    },
                    isCreating: false,
                    onStart: { state.requests.append($0) }, onCancel: { }
                )
                .id("host")
                .padding()
                .onAppear { state.appeared = true }
            }
        }

        @MainActor
        final private class Fixture {
            let state: State
            let window: NSWindow

            init(agents: [SessionLaunchAgent]) {
                _ = NSApplication.shared
                NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
                self.state = State(agents: agents)
                self.window = NSWindow(
                    contentRect: .init(x: -10_000, y: -10_000, width: 600, height: 600),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: Surface(state: state))
                window.orderBack(nil)
            }

            func wait(_ condition: () -> Bool) async throws {
                for _ in 0..<100 {
                    if condition() {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(condition(), "Timed out waiting for the directory form")
            }

            func element(_ identifier: String) async throws -> NSObject {
                try await wait { self.find(identifier, in: self.window.contentView) != nil }
                return try #require(find(identifier, in: window.contentView))
            }

            func submit() async throws {
                let button = try await element("start-directory-session")
                let selector = NSSelectorFromString("accessibilityPerformPress")
                try #require(button.responds(to: selector))
                let implementation = try #require(button.method(for: selector))
                let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
                #expect(press(button, selector))
                try await wait { !self.state.requests.isEmpty }
            }

            private func attribute(_ name: String, from node: NSObject) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }

            private func find(_ identifier: String, in root: Any?) -> NSObject? {
                guard let node = root as? NSObject else { return nil }
                if attribute("accessibilityIdentifier", from: node) as? String == identifier {
                    return node
                }
                for child in attribute("accessibilityChildren", from: node) as? [Any] ?? [] {
                    if let found = find(identifier, in: child) {
                        return found
                    }
                }
                for child in (node as? NSView)?.subviews ?? [] {
                    if let found = find(identifier, in: child) {
                        return found
                    }
                }
                return nil
            }
        }
    }
#endif
