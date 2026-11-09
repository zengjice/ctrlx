#if os(macOS)
    import AppKit
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite(.serialized)
    struct NewTabMenuTests {
        private var configuration: NewAgentTabConfiguration {
            .init(
                id: .init(hostID: nil, sessionName: "work"), initialDirectory: "/repo", agents: [],
                directorySource: .init(id: "host", list: { _ in throw CancellationError() }),
                unavailableReason: nil, start: { _ in Issue.record("Opening the picker must not launch an Agent") }
            )
        }

        @Test("The shared picker starts with Agent and preserves Terminal, resource and Git actions")
        func localActions() {
            var presented = true
            var terminalCount = 0
            var resources: [ResourceTabKind] = []
            var gitCount = 0
            let menu = NewTabMenuButton(
                helpText: "New Tab", agentConfiguration: configuration,
                isPresented: .init(get: { presented }, set: { presented = $0 }),
                onNewTerminal: { terminalCount += 1 }, onOpenGit: { gitCount += 1 },
                onNewResource: { resources.append($0) }
            )
            let items = menu.items
            #expect(items.map(\.id) == [.agent, .terminal, .resource(.files), .resource(.browser), .resource(.simulator), .git])
            #expect(terminalCount == 0)
            #expect(resources.isEmpty)
            #expect(gitCount == 0)
            for item in items.dropFirst() {
                item.action()
            }
            #expect(!presented)
            #expect(terminalCount == 1)
            #expect(resources == [.files, .browser, .simulator])
            #expect(gitCount == 1)
        }

        @Test("Disconnected Viewer disables Terminal and does not invent unavailable actions")
        func disconnectedActions() {
            let menu = NewTabMenuButton(
                helpText: "New Tab", agentConfiguration: configuration, isPresented: .constant(true),
                isTerminalDisabled: true, onNewTerminal: { Issue.record("Unavailable Terminal action") }
            )
            #expect(menu.items.map(\.id) == [.agent, .terminal])
            #expect(menu.items.first?.isEnabled == true)
            #expect(menu.items.last?.isEnabled == false)
        }

        @Test("Content menus reuse creation actions without triggering them while opening")
        func sharedCreationActions() {
            var invoked: [NewTabMenuItem.ID] = []
            let items = NewTabMenuItem.creationItems(
                onNewAgent: { invoked.append(.agent) },
                onNewTerminal: { invoked.append(.terminal) },
                onNewResource: { invoked.append(.resource($0)) },
                onOpenGit: { invoked.append(.git) }
            )
            #expect(items.map(\.title) == ["New Agent…", "New Terminal", "New Files", "New Browser", "New iOS Simulator", "Open Git"])
            #expect(invoked.isEmpty)
            for item in items {
                item.action()
            }
            #expect(invoked == items.map(\.id))
            let remote = NewTabMenuItem.creationItems(onNewAgent: { }, onNewTerminal: { }, onNewResource: { _ in })
            #expect(remote.map(\.id) == Array(items.dropLast()).map(\.id))
        }

        @Test("Return opens Agent by default; arrows select other enabled entries", arguments: [0, 1, 2])
        func keyboardSelection(mode: Int) async throws {
            _ = NSApplication.shared
            var chosen: NewTabMenuItem.ID?
            let items: [NewTabMenuItem] = [
                .init(id: .agent, title: "New Agent…", image: Symbols.sparkles.image) { chosen = .agent },
                .init(id: .terminal, title: "New Terminal", image: Symbols.terminal.image, isEnabled: mode != 2) { chosen = .terminal },
                .init(id: .resource(.browser), title: "New Browser", image: Symbols.globe.image) { chosen = .resource(.browser) },
            ]
            let window = NSWindow(
                contentRect: .init(x: -10_000, y: -10_000, width: 230, height: 150),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NewTabPicker(items: items))
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            if mode != 0 {
                try window.sendEvent(key(code: 125, characters: "\u{f701}", window: window))
                try await Task.sleep(for: .milliseconds(50))
            }
            try window.sendEvent(key(code: 36, characters: "\r", window: window))
            try await Task.sleep(for: .milliseconds(50))
            #expect(chosen == (mode == 0 ? .agent : mode == 1 ? .terminal : .resource(.browser)))
        }

        @Test("New Agent shows two vertical cards and scrolls additional Agent types", arguments: [false, true])
        func agentPanelInitialLayout(hasAdditionalAgent: Bool) async throws {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let agents: [SessionLaunchAgent] = [
                .init(id: "codex", name: "Codex", providers: [.init(id: "openai", name: "OpenAI (official login)")]),
                .init(id: "claude-code", name: "Claude Code", providers: [.init(id: "anthropic", name: "Anthropic (official login)")]),
            ]
            let config = NewAgentTabConfiguration(
                id: .init(hostID: nil, sessionName: "work"), initialDirectory: "/Host/Projects/work",
                agents: agents + (hasAdditionalAgent ? [.init(id: "future", name: "Future Agent")] : []),
                directorySource: .init(id: "host", list: { _ in
                    Issue.record("Opening the panel must not browse directories")
                    throw CancellationError()
                }),
                unavailableReason: nil, start: { _ in Issue.record("Opening the panel must not launch an Agent") }
            )
            let hosting = NSHostingView(rootView: NewAgentTabPanel(configuration: config))
            let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: hosting.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let scroll = try #require(scrollView(in: hosting))
            let visible = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            var titleFrames: [CGRect] = []
            for agent in agents {
                for identifier in [agent.name, "\(agent.name) directory on Host", "Start \(agent.name)"] {
                    let control = try await element(identifier, in: window)
                    let frame = try frame(of: control)
                    #expect(frame.width > 0 && frame.height > 0 && visible.contains(frame), "\(identifier) must be fully visible: \(frame) inside \(visible)")
                    if identifier == agent.name {
                        titleFrames.append(frame)
                    }
                }
            }
            #expect(titleFrames[0].minY > titleFrames[1].maxY)
            #expect(abs(titleFrames[0].minX - titleFrames[1].minX) < 1)
            let document = try #require(scroll.documentView)
            if hasAdditionalAgent {
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                let y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                scroll.contentView.scroll(to: .init(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                let start = try await element("Start Future Agent", in: window)
                #expect(try visible.contains(frame(of: start)))
            } else {
                #expect(document.bounds.height <= scroll.contentView.bounds.height)
            }
        }

        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }

        private func frame(of node: NSObject) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            let implementation = try #require(node.method(for: selector))
            return unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(node, selector)
        }

        private func element(_ identifier: String, in window: NSWindow) async throws -> NSObject {
            for _ in 0..<100 {
                if let node = find(identifier, in: window.contentView) {
                    return node
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw MissingElement(identifier: identifier)
        }

        private struct MissingElement: Error { let identifier: String }

        private func find(_ identifier: String, in root: Any?) -> NSObject? {
            guard let node = root as? NSObject else { return nil }
            for name in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if node.responds(to: selector), node.perform(selector)?.takeUnretainedValue() as? String == identifier {
                    return node
                }
            }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: childrenSelector) {
                for child in node.perform(childrenSelector)?.takeUnretainedValue() as? [Any] ?? [] {
                    if let match = find(identifier, in: child) {
                        return match
                    }
                }
            }
            for child in (node as? NSView)?.subviews ?? [] {
                if let match = find(identifier, in: child) {
                    return match
                }
            }
            return nil
        }

        private func key(code: UInt16, characters: String, window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
    }
#endif
