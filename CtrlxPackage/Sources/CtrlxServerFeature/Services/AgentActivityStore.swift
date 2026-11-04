import CtrlxCommon
import Dependencies
import Foundation
import Logging

/// Task recency belongs to a durable pane, not its terminal output or runtime number.
@MainActor
final class AgentActivityStore {
    private static let storageKey = "agentTaskActivity.v1"
    @Dependency(PreferencesService.self) private var preferences
    private let logger = Logger(label: "com.jicezeng.ctrlx.agent-activity")
    private var activity: [UUID: Date] = [:]

    init() {
        guard let data = preferences.data(Self.storageKey) else { return }
        do {
            self.activity = try JSONDecoder().decode([UUID: Date].self, from: data)
        } catch {
            logger.warning("Could not load Agent task activity: \(error)")
        }
    }

    func lastActivity(for paneID: UUID) -> Date? {
        activity[paneID]
    }

    func record(_ date: Date, for paneID: UUID) {
        guard date > (activity[paneID] ?? .distantPast) else { return }
        activity[paneID] = date
        do {
            try preferences.setData(JSONEncoder().encode(activity), Self.storageKey)
        } catch {
            logger.warning("Could not save Agent task activity: \(error)")
        }
    }
}
