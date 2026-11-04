import Foundation

/// Shared by the iOS notification delegate and its service extension.
public enum NotificationDelivery {
    /// Remote questions alert even while the app is open. Ordinary remote
    /// activity remains visible in the session UI. Local notifications are
    /// explicit follow-up questions, reply failures or on-device alerts.
    public static func shouldPresentInForeground(isRemote: Bool, userInfo: [AnyHashable: Any]) -> Bool {
        if !isRemote || userInfo["eventType"] as? String == "agent.question" {
            return true
        }
        // Older Hosts identify structured questions only through their action context.
        guard
            let json = userInfo[NotificationUserInfoKey.actionContext] as? String,
            let action = try? JSONDecoder().decode(NotificationActionContext.self, from: Data(json.utf8))
        else { return false }
        if case .askUserQuestion = action.form {
            return true
        }
        return false
    }

    /// Tmux pane IDs are only unique within one Host.
    public static func matchesPane(userInfo: [AnyHashable: Any], pairId: String, paneId: String) -> Bool {
        userInfo["pairId"] as? String == pairId && userInfo["paneId"] as? String == paneId
    }
}
