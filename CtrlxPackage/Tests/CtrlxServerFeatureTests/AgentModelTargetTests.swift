import AppKit
import CtrlxCommon
import CtrlxEncryption
import Dependencies
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelTargetTests {
    private func endpoint(hostID: String? = nil, paneID: String = "%7") -> TerminalQuickActionEndpoint {
        TerminalQuickActionEndpoint(hostID: hostID, paneID: paneID, isVisible: { true }, enqueue: { _ in
            Issue.record("Resolving a model target must not send terminal input.")
        })
    }

    @Test("Model controls follow native focus even before tmux reports the new active pane", arguments: [nil, "office"] as [String?])
    func focusedPane(hostID: String?) {
        let router = TerminalQuickActionRouter()
        router.focus(endpoint(hostID: hostID))
        let target = TerminalWindowStatusBar.modelTarget(hostID: hostID, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)
        #expect(target == PaneKey(pairId: hostID ?? "local", paneId: "%7"))
    }

    @Test("Other tabs and Hosts cannot redirect the model controls")
    func targetScope() {
        let router = TerminalQuickActionRouter()
        router.focus(endpoint(hostID: "office"))
        #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.paneId == "%0")
        #expect(TerminalWindowStatusBar.modelTarget(hostID: "home", paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.pairId == "home")
        #expect(TerminalWindowStatusBar.modelTarget(hostID: "home", paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.paneId == "%0")
        #expect(TerminalWindowStatusBar.modelTarget(hostID: "office", paneIDs: ["%1", "%2"], activePaneID: "%2", focused: router.active)?.paneId == "%2")
    }

    @Test("Fallback uses only a current member and never silently selects the first pane")
    func activePaneFallback() {
        #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: ["%0", "%7"], activePaneID: "%7", focused: nil)?.paneId == "%7")
        #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: ["%0", "%7"], activePaneID: nil, focused: nil) == nil)
        #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: ["%0", "%7"], activePaneID: "%8", focused: nil) == nil)
        #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: [], activePaneID: "%7", focused: endpoint()) == nil)
    }

    @Test("Hidden and unmounted terminals cannot retain the model target")
    func targetLifecycle() {
        let hidden = TerminalQuickActionEndpoint(hostID: nil, paneID: "%7", isVisible: { false }, enqueue: { _ in })
        let retired = endpoint()
        retired.invalidate()
        for focused in [hidden, retired] {
            #expect(TerminalWindowStatusBar.modelTarget(hostID: nil, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: focused)?.paneId == "%0")
        }
    }

    @Test("Native terminal focus updates the target and toolbar focus retains it", arguments: [nil, "office"] as [String?])
    func nativeFocus(hostID: String?) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
        } operation: {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = try #require(window.contentView)
            let router = TerminalQuickActionRouter()
            let first = InteractiveTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 360))
            let second = InteractiveTerminalView(frame: CGRect(x: 400, y: 0, width: 400, height: 360))
            defer {
                first.stopQuestionChecks()
                second.stopQuestionChecks()
                window.close()
            }
            first.autoFocusEnabled = false
            second.autoFocusEnabled = false
            content.addSubview(first)
            content.addSubview(second)
            let firstEndpoint = endpoint(hostID: hostID, paneID: "%0")
            let secondEndpoint = endpoint(hostID: hostID, paneID: "%7")
            first.onBecomeFirstResponder = { router.focus(firstEndpoint) }
            second.onBecomeFirstResponder = { router.focus(secondEndpoint) }

            #expect(first.focusTerminal(source: .mouse))
            #expect(TerminalWindowStatusBar.modelTarget(hostID: hostID, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.paneId == "%0")
            #expect(second.focusTerminal(source: .mouse))
            #expect(TerminalWindowStatusBar.modelTarget(hostID: hostID, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.paneId == "%7")

            let toolbarField = NSTextField(frame: CGRect(x: 0, y: 360, width: 200, height: 30))
            content.addSubview(toolbarField)
            #expect(window.makeFirstResponder(toolbarField))
            #expect(TerminalWindowStatusBar.modelTarget(hostID: hostID, paneIDs: ["%0", "%7"], activePaneID: "%0", focused: router.active)?.paneId == "%7")
        }
    }
}
