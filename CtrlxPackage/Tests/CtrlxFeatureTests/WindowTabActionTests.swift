import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct WindowTabActionTests {
    private func windows(_ index: Int = 2) -> [TmuxWindow] {
        TmuxWindow.groupPanes([
            PaneState(
                paneId: "%1",
                sessionName: "work",
                windowIndex: 1,
                tmuxWindowId: "@1",
                currentPath: "/host/A",
                isActive: true,
                isWindowActive: true
            ),
            PaneState(
                paneId: "%2",
                sessionName: "work",
                windowIndex: index,
                tmuxWindowId: "@2",
                currentPath: "/host/B",
                isActive: true
            ),
            PaneState(
                paneId: "%3",
                sessionName: "work",
                windowIndex: index,
                tmuxWindowId: "@2",
                paneIndex: 1,
                currentPath: "/host/C",
                agentSession: .init(paneId: "%3", pluginID: "codex"),
                claudeSessionID: UUID().uuidString
            ),
        ])
    }

    @Test("Window actions keep their stable target after reorder", arguments: [
        WindowTabAction.WindowOperation.select, .openFiles, .openAnotherFiles, .openBrowser, .openSimulator, .openNewSimulator,
        .fork(destination: .currentDirectory), .fork(destination: .otherDirectory), .fork(destination: .worktree), .rename, .close,
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

    @Test("A legacy Host can create the first default simulator but not a second", arguments: [false, true])
    func legacySimulatorCreation(hasDefault: Bool) {
        let existing = hasDefault ? [simulator(pane: "%3", primary: true)] : []
        let action = WindowTabAction.simulatorCreation(
            window: windows()[1], preferredPaneID: "%3", simulators: existing,
            supportsIndependentResources: false, supportsPaneSimulator: true, supportsNewSimulator: false
        )
        #expect(action == (hasDefault ? nil : .window(stableID: "@2", operation: .openSimulator)))
    }

    @Test("Other panes and non-primary devices do not block first creation", arguments: [false, true])
    func firstSimulatorUsesExactPane(otherPane: Bool) {
        let action = WindowTabAction.simulatorCreation(
            window: windows()[1], preferredPaneID: "%3",
            simulators: [simulator(pane: otherPane ? "%2" : "%3", primary: otherPane)],
            supportsIndependentResources: false, supportsPaneSimulator: true, supportsNewSimulator: false
        )
        #expect(action == .window(stableID: "@2", operation: .openSimulator))
    }

    @Test("A stale preferred pane uses the same active-pane fallback as dispatch")
    func legacySimulatorFallback() {
        let action = WindowTabAction.simulatorCreation(
            window: windows()[1], preferredPaneID: "%retired", simulators: [simulator(pane: "%2", primary: true)],
            supportsIndependentResources: false, supportsPaneSimulator: true, supportsNewSimulator: false
        )
        #expect(action == nil)
    }

    @Test("New simulator capability and independent resources keep explicit creation")
    func explicitSimulatorCreation() {
        #expect(WindowTabAction.simulatorCreation(
            window: windows()[1], preferredPaneID: "%3", simulators: [simulator(pane: "%3", primary: true)],
            supportsIndependentResources: false, supportsPaneSimulator: true, supportsNewSimulator: true
        ) == .window(stableID: "@2", operation: .openNewSimulator))
        #expect(WindowTabAction.simulatorCreation(
            window: nil, preferredPaneID: nil, simulators: [],
            supportsIndependentResources: true, supportsPaneSimulator: false, supportsNewSimulator: false
        ) == .newResource(.simulator))
    }

    @Test("Legacy creation needs a source window and pane-simulator capability", arguments: [false, true])
    func unavailableSimulatorCreation(missingWindow: Bool) {
        #expect(WindowTabAction.simulatorCreation(
            window: missingWindow ? nil : windows()[1], preferredPaneID: "%3", simulators: [],
            supportsIndependentResources: false, supportsPaneSimulator: missingWindow, supportsNewSimulator: true
        ) == nil)
    }

    private func simulator(pane: String, primary: Bool) -> RemoteSimulatorTab {
        .init(id: UUID(), sessionName: "work", sourcePaneID: pane, title: "iPhone", runtime: "iOS", isPrimary: primary)
    }
}
