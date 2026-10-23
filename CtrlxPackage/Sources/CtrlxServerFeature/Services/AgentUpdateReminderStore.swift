#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Observation

    enum AgentUpdateReminderChannel: String, Sendable {
        case plugin
        case cli

        var dismissalsKey: String {
            "agentUpdates.\(rawValue).dismissals.v1"
        }
    }

    struct AgentUpdateReminderKey: Hashable, Codable, Sendable {
        let targetID: String
        let configRoot: String?
        let version: String

        static func plugin(pluginID: String, configRoot: String?, version: String) -> Self {
            Self(targetID: pluginID, configRoot: configRoot, version: version)
        }

        static func cli(agentID: String, version: String) -> Self {
            Self(targetID: agentID, configRoot: nil, version: version)
        }
    }

    enum AgentUpdateReminderInterval: Int, CaseIterable, Identifiable, Sendable {
        case oneHour = 3_600
        case sixHours = 21_600
        case oneDay = 86_400
        case threeDays = 259_200
        case sevenDays = 604_800

        var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .oneHour: "1 hour"
            case .sixHours: "6 hours"
            case .oneDay: "1 day"
            case .threeDays: "3 days"
            case .sevenDays: "7 days"
            }
        }
    }

    /// Reusable, persisted dismissal state for one Agent update channel.
    /// Plugin and CLI reminders use separate instances and storage keys.
    @Observable @MainActor
    final class AgentUpdateReminderStore {
        private struct Record: Codable {
            let targetID: String
            let configRoot: String?
            let version: String
            let dismissedAt: Date

            var key: AgentUpdateReminderKey {
                AgentUpdateReminderKey(
                    targetID: targetID,
                    configRoot: configRoot,
                    version: version
                )
            }
        }

        static let intervalKey = "agentUpdates.reminderInterval"

        var interval: AgentUpdateReminderInterval {
            didSet {
                preferences.setInt(interval.rawValue, Self.intervalKey)
                expireDismissals()
                scheduleExpiration()
            }
        }

        @ObservationIgnored private let dismissalsKey: String
        @ObservationIgnored private let preferences: PreferencesService
        @ObservationIgnored private let now: () -> Date
        @ObservationIgnored private var expirationTask: Task<Void, Never>?
        private var dismissedAt: [AgentUpdateReminderKey: Date] = [:]

        init(
            channel: AgentUpdateReminderChannel,
            preferences: PreferencesService? = nil,
            now: @escaping () -> Date = { Date() }
        ) {
            @Dependency(PreferencesService.self) var environmentPreferences
            self.dismissalsKey = channel.dismissalsKey
            self.preferences = preferences ?? environmentPreferences
            self.now = now
            self.interval = self.preferences.optionalInt(Self.intervalKey)
                .flatMap(AgentUpdateReminderInterval.init(rawValue:))
                ?? .oneDay

            if
                let data = self.preferences.data(dismissalsKey),
                let records = try? JSONDecoder().decode([Record].self, from: data) {
                for record in records {
                    dismissedAt[record.key] = record.dismissedAt
                }
            }
            expireDismissals()
            scheduleExpiration()
        }

        static func inMemory(
            channel: AgentUpdateReminderChannel,
            now: @escaping () -> Date = { Date() }
        ) -> AgentUpdateReminderStore {
            AgentUpdateReminderStore(channel: channel, preferences: .inMemory(), now: now)
        }

        func shouldShow(_ reminder: AgentUpdateReminderKey) -> Bool {
            guard let dismissedAt = dismissedAt[reminder] else { return true }
            return now().timeIntervalSince(dismissedAt) >= TimeInterval(interval.rawValue)
        }

        func dismiss(_ reminder: AgentUpdateReminderKey) {
            dismissedAt[reminder] = now()
            saveDismissals()
            scheduleExpiration()
        }

        private func expireDismissals() {
            let cutoff = now().addingTimeInterval(-TimeInterval(interval.rawValue))
            let retained = dismissedAt.filter { $0.value > cutoff }
            guard retained.count != dismissedAt.count else { return }
            dismissedAt = retained
            saveDismissals()
        }

        private func saveDismissals() {
            let records = dismissedAt.map { key, date in
                Record(
                    targetID: key.targetID,
                    configRoot: key.configRoot,
                    version: key.version,
                    dismissedAt: date
                )
            }
            guard let data = try? JSONEncoder().encode(records) else { return }
            preferences.setData(data, dismissalsKey)
        }

        private func scheduleExpiration() {
            expirationTask?.cancel()
            guard
                let deadline = dismissedAt.values
                    .map({ $0.addingTimeInterval(TimeInterval(interval.rawValue)) })
                    .min()
            else {
                expirationTask = nil
                return
            }
            let delay = max(0, deadline.timeIntervalSince(now()))
            expirationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self else { return }
                expireDismissals()
                scheduleExpiration()
            }
        }
    }
#endif
