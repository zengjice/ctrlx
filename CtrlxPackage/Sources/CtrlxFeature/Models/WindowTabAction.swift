import CtrlxCommon
import CtrlxNetworking
import Foundation

enum WindowTabAction: Equatable, Sendable {
    enum WindowOperation: Equatable, Sendable {
        case select
        case openFiles
        case openAnotherFiles
        case openBrowser
        case openSimulator
        case openNewSimulator
        case fork(destination: AgentForkDestination)
        case rename
        case close
    }

    case window(stableID: String, operation: WindowOperation)
    case selectFiles(UUID)
    case closeFiles(UUID)
    case selectSimulator(UUID)
    case closeSimulator(UUID)
    case selectBrowser(UUID)
    case closeBrowser(UUID)
    case newResource(ResourceTabKind)
    case newTerminal
    case newAgent

    func targetWindow(in windows: [TmuxWindow]) -> TmuxWindow? {
        guard case let .window(stableID, _) = self else { return nil }
        return windows.first { $0.stableId == stableID }
    }

    @MainActor
    static func simulatorCreation(
        window: TmuxWindow?,
        preferredPaneID: String?,
        simulators: [RemoteSimulatorTab],
        supportsIndependentResources: Bool,
        supportsPaneSimulator: Bool,
        supportsNewSimulator: Bool
    ) -> Self? {
        if supportsIndependentResources {
            return .newResource(.simulator)
        }
        guard
            supportsPaneSimulator, let window,
            let paneID = FileBrowserTab.sourcePaneID(
                in: window.panes.map(\.paneId),
                focusedPaneID: preferredPaneID,
                activePaneID: window.activePane?.paneId
            ) else { return nil }
        if supportsNewSimulator {
            return .window(stableID: window.stableId, operation: .openNewSimulator)
        }
        guard !simulators.contains(where: { $0.sourcePaneID == paneID && $0.isPrimary }) else { return nil }
        return .window(stableID: window.stableId, operation: .openSimulator)
    }
}
