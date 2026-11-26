import Foundation

/// Shared notification presentation and routing rules.
public enum NotificationDelivery {
    public static let workflowCompletionEventType = "workflow.completed"

    public static let workflowAttentionEventType = "workflow.attention"

    public static func isWorkflow(userInfo: [AnyHashable: Any]) -> Bool {
        let type = userInfo["eventType"] as? String
        return type == workflowCompletionEventType || type == workflowAttentionEventType
    }

    public static func isWorkflowCompletion(userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["eventType"] as? String == workflowCompletionEventType
    }

    /// Workflow transitions and open questions/approvals alert in foreground.
    /// Ordinary remote Agent completion remains in the session UI.
    public static func shouldPresentInForeground(isRemote: Bool, userInfo: [AnyHashable: Any]) -> Bool {
        if !isRemote || isWorkflow(userInfo: userInfo) || userInfo["eventType"] as? String == "agent.question" {
            return true
        }
        // Older Hosts identify structured questions only through their action context.
        guard
            let json = userInfo[NotificationUserInfoKey.actionContext] as? String,
            let _ = try? JSONDecoder().decode(NotificationActionContext.self, from: Data(json.utf8))
        else { return false }
        // Every validated open form requires a human decision now, including
        // permission and plan approval. Ordinary completion remains quiet.
        return true
    }

    public static func matchesAgent(userInfo: [AnyHashable: Any], pairId: String, agentID: AgentID) -> Bool {
        userInfo["pairId"] as? String == pairId && AgentID(notificationUserInfo: userInfo) == agentID
    }
}
