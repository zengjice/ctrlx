#if os(macOS)
    import CtrlxCommon
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent update reminder dismissals") @MainActor
    struct AgentUpdateReminderStoreTests {
        final private class TestClock {
            var now: Date

            init(_ now: Date) {
                self.now = now
            }
        }

        @Test("A dismissed update stays hidden until the configured interval expires")
        func expiration() {
            let clock = TestClock(Date(timeIntervalSinceReferenceDate: 1_000_000))
            let store = AgentUpdateReminderStore(
                channel: .cli,
                preferences: .inMemory(),
                now: { clock.now }
            )
            let reminder = AgentUpdateReminderKey.cli(agentID: "codex", version: "1.1.0")

            store.dismiss(reminder)
            #expect(!store.shouldShow(reminder))

            clock.now += TimeInterval(AgentUpdateReminderInterval.oneDay.rawValue - 1)
            #expect(!store.shouldShow(reminder))

            clock.now += 1
            #expect(store.shouldShow(reminder))
        }

        @Test("Dismissals and the selected interval survive a new store instance")
        func persistence() {
            let preferences = PreferencesService.inMemory()
            let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
            let reminder = AgentUpdateReminderKey.plugin(
                pluginID: "codex",
                configRoot: "/tmp/codex",
                version: "1.2.0"
            )

            let first = AgentUpdateReminderStore(
                channel: .plugin,
                preferences: preferences,
                now: { start }
            )
            first.interval = .sixHours
            first.dismiss(reminder)

            let second = AgentUpdateReminderStore(
                channel: .plugin,
                preferences: preferences,
                now: { start.addingTimeInterval(3_600) }
            )
            #expect(second.interval == .sixHours)
            #expect(!second.shouldShow(reminder))
        }

        @Test("Plugin and CLI stores keep independent dismissals")
        func independentChannels() {
            let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
            let preferences = PreferencesService.inMemory()
            let pluginStore = AgentUpdateReminderStore(
                channel: .plugin,
                preferences: preferences,
                now: { now }
            )
            let cliStore = AgentUpdateReminderStore(
                channel: .cli,
                preferences: preferences,
                now: { now }
            )
            let plugin = AgentUpdateReminderKey.plugin(pluginID: "codex", configRoot: nil, version: "1.1.0")
            let cli = AgentUpdateReminderKey.cli(agentID: "codex", version: "1.1.0")

            pluginStore.dismiss(plugin)
            #expect(!pluginStore.shouldShow(plugin))
            #expect(pluginStore.shouldShow(plugin.withVersion("1.2.0")))
            #expect(cliStore.shouldShow(cli))

            cliStore.dismiss(cli)
            #expect(!cliStore.shouldShow(cli))
            #expect(!pluginStore.shouldShow(plugin))
        }

        @Test("Shortening the interval makes an already expired dismissal visible")
        func intervalChange() {
            let clock = TestClock(Date(timeIntervalSinceReferenceDate: 4_000_000))
            let store = AgentUpdateReminderStore(
                channel: .cli,
                preferences: .inMemory(),
                now: { clock.now }
            )
            let reminder = AgentUpdateReminderKey.cli(agentID: "claude-code", version: "2.0.0")

            store.dismiss(reminder)
            clock.now += 7_200
            #expect(!store.shouldShow(reminder))

            store.interval = .oneHour
            #expect(store.shouldShow(reminder))
        }
    }

    private extension AgentUpdateReminderKey {
        func withVersion(_ version: String) -> Self {
            Self(targetID: targetID, configRoot: configRoot, version: version)
        }
    }
#endif
