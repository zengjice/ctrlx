import CtrlxCommon
import Foundation

enum WindowTabAction: Equatable, Sendable {
    enum WindowOperation: Equatable, Sendable {
        case select
        case openFiles
        case fork(usingWorktree: Bool)
        case rename
        case close
    }

    case window(stableID: String, operation: WindowOperation)
    case selectFiles(UUID)
    case closeFiles(UUID)
    case newTerminal
    case newAgent

    func targetWindow(in windows: [TmuxWindow]) -> TmuxWindow? {
        guard case let .window(stableID, _) = self else { return nil }
        return windows.first { $0.stableId == stableID }
    }
}
