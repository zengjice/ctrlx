import Dependencies
import DependenciesMacros
import Foundation
import UserNotifications

@DependencyClient
public struct DashboardNotificationClient: Sendable {
    public var notify: @Sendable (_ alert: DashboardQuotaAlert) async throws -> Void
    public static let userInfoKey = "ctrlxDashboard"
    public static let openNotification = Notification.Name("ctrlxOpenDashboard")
}

extension DashboardNotificationClient: DependencyKey {
    public static let testValue = Self(notify: { _ in })
    public static let liveValue = Self(notify: { alert in
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Agent quota is running low"
        content.body = alert.body
        content.userInfo = [userInfoKey: true]
        try await center.add(UNNotificationRequest(identifier: "dashboard-quota-\(UUID())", content: content, trigger: nil))
    })
}
