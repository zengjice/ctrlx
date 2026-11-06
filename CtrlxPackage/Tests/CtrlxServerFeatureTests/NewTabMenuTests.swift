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

        private func key(code: UInt16, characters: String, window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
    }
#endif
