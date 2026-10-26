#if os(macOS)
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    public enum AgentWorkflowMenu {
        public static func items(panes: [PaneState], isEnabled: Bool = true, open: ((PaneState) -> Void)?) -> [ContextMenuItem] {
            guard let open else { return [] }
            let agents = panes.filter { $0.agentSession != nil }
            guard !agents.isEmpty else { return [] }
            if let pane = agents.first, agents.count == 1 {
                return [.button(title: "View Workflow", symbol: .arrowTriangleBranch, isEnabled: isEnabled) { open(pane) }]
            }
            return [.submenu(title: "View Workflow", symbol: .arrowTriangleBranch, isEnabled: isEnabled, items: agents.map { pane in
                .button(title: "\(pane.windowName) · \(pane.paneId)") { open(pane) }
            })]
        }
    }
#endif
