import CtrlxNetworking
import Foundation

enum AgentBrowserRoutingError: Error, LocalizedError {
    case processNotInPane
    case ambiguousPane
    var errorDescription: String? {
        switch self {
        case .processNotInPane: "This Codex is not inside a local CtrlX tmux pane. No browser tab was opened."
        case .ambiguousPane: "This Codex belongs to multiple linked tmux sessions. Unlink the duplicate before opening a browser tab."
        }
    }
}

enum AgentBrowserRouting {
    static func resolve(panes: [PaneInfo], matchingPaneIDs: Set<String>) throws -> PaneInfo {
        let matches = panes.filter { matchingPaneIDs.contains($0.paneId) }
        guard !matches.isEmpty else { throw AgentBrowserRoutingError.processNotInPane }
        guard matches.count == 1 else { throw AgentBrowserRoutingError.ambiguousPane }
        return matches[0]
    }
}
