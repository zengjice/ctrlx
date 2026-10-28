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
}

enum WindowTabKind: Equatable, Sendable {
    case terminal
    case files
    case browser
    case simulator

    enum ShortcutMode: Equatable, Sendable {
        case reuseOrCreate
        case create
        case unavailable
    }

    func shortcutMode(whenActive active: WindowTabKind, canCreate: Bool = true) -> ShortcutMode {
        guard self == active else { return .reuseOrCreate }
        return canCreate ? .create : .unavailable
    }
}
