import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct WindowTabActionTests {
    private func windows(_ index: Int = 2) -> [TmuxWindow] {
        TmuxWindow.groupPanes([
            PaneState(paneId: "%1", sessionName: "work", windowIndex: 1, tmuxWindowId: "@1",
                      currentPath: "/host/A", isActive: true, isWindowActive: true),
            PaneState(paneId: "%2", sessionName: "work", windowIndex: index, tmuxWindowId: "@2",
                      currentPath: "/host/B", isActive: true),
            PaneState(paneId: "%3", sessionName: "work", windowIndex: index, tmuxWindowId: "@2", paneIndex: 1,
                      currentPath: "/host/C", agentSession: .init(paneId: "%3", pluginID: "codex"), claudeSessionID: UUID().uuidString),
        ])
    }

    @Test("Window actions keep their stable target after reorder", arguments: [
        WindowTabAction.WindowOperation.select, .openFiles, .openAnotherFiles, .openBrowser, .openSimulator, .openNewSimulator, .fork(usingWorktree: false), .fork(usingWorktree: true), .rename, .close,
    ])
    func targetAfterReorder(operation: WindowTabAction.WindowOperation) throws {
        let action = WindowTabAction.window(stableID: "@2", operation: operation)
        let target = try #require(action.targetWindow(in: windows(5)))
        #expect(target.id == "work:5")
        #expect(target.panes.map(\.paneId) == ["%2", "%3"])
        #expect(action.targetWindow(in: windows().filter { $0.stableId == "@1" }) == nil)
    }

    @Test("Files and Fork use only the chosen window even if focus remains elsewhere")
    func sourcesStayInTarget() throws {
        let action = WindowTabAction.window(stableID: "@2", operation: .openFiles)
        let target = try #require(action.targetWindow(in: windows()))
        #expect(FileBrowserTab.sourcePaneID(in: target.panes.map(\.paneId), focusedPaneID: "%1", activePaneID: target.activePane?.paneId) == "%2")
        #expect(FileBrowserTab.sourcePaneID(in: target.panes.map(\.paneId), focusedPaneID: "%3", activePaneID: target.activePane?.paneId) == "%3")
        #expect(AgentForkConfiguration.orderedSources(panes: target.panes, focusedPaneID: "%1").map(\.paneID) == ["%3"])
    }

    @Test("Linked tab actions never resolve to a terminal window")
    func filesHaveNoWindowTarget() {
        let id = UUID()
        #expect(WindowTabAction.selectFiles(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.closeFiles(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.selectBrowser(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.closeBrowser(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.selectSimulator(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.closeSimulator(id).targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.newAgent.targetWindow(in: windows()) == nil)
        #expect(WindowTabAction.newTerminal.targetWindow(in: windows()) == nil)
    }

    @Test("Only the active linked tab creates its own kind")
    func shortcutModes() {
        #expect(WindowTabKind.terminal.shortcutMode(whenActive: .terminal) == .create)
        #expect(WindowTabKind.files.shortcutMode(whenActive: .terminal) == .reuseOrCreate)
        #expect(WindowTabKind.browser.shortcutMode(whenActive: .terminal) == .reuseOrCreate)
        #expect(WindowTabKind.simulator.shortcutMode(whenActive: .terminal) == .reuseOrCreate)
        #expect(WindowTabKind.files.shortcutMode(whenActive: .files) == .create)
        #expect(WindowTabKind.files.shortcutMode(whenActive: .browser) == .reuseOrCreate)
        #expect(WindowTabKind.browser.shortcutMode(whenActive: .browser) == .create)
        #expect(WindowTabKind.simulator.shortcutMode(whenActive: .simulator) == .create)
        #expect(WindowTabKind.simulator.shortcutMode(whenActive: .simulator, canCreate: false) == .unavailable)
        #expect(WindowTabKind.simulator.shortcutMode(whenActive: .files, canCreate: false) == .reuseOrCreate)
    }
}
