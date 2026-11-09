import AppKit
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct SettingsWindowDraftTests {
    @Test("Closing Settings discards only unapplied edits in its own window")
    func closeDiscardsDrafts() async throws {
        _ = NSApplication.shared
        let drafts = SettingsDrafts()
        drafts.agentCommands["codex"] = "/draft/codex"
        drafts.agentCommands["claude-code"] = "/draft/claude"
        drafts.tmux = .init(tmuxPath: "/draft/tmux", socketPath: "/tmp/draft.sock")
        let host = NSHostingView(rootView: Text("Settings fixture")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsWindowLifecycle { drafts.discard() }))
        let settingsWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = host
        settingsWindow.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let unrelatedWindow = NSWindow()
        unrelatedWindow.isReleasedWhenClosed = false
        unrelatedWindow.close()
        #expect(drafts.agentCommands.count == 2)
        #expect(drafts.tmux != nil)
        settingsWindow.close()
        #expect(drafts.agentCommands.isEmpty)
        #expect(drafts.tmux == nil)
    }
}
