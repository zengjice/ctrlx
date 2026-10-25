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

        @Test("App, plugin, and CLI stores keep independent dismissals")
        func independentChannels() {
            let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
            let preferences = PreferencesService.inMemory()
            #expect(
                Set([
                    AgentUpdateReminderChannel.plugin.dismissalsKey,
                    AgentUpdateReminderChannel.cli.dismissalsKey,
                    AgentUpdateReminderChannel.app.dismissalsKey,
                ]).count == 3
            )
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
            let appStore = AgentUpdateReminderStore(
                channel: .app,
                preferences: preferences,
                now: { now }
            )
            let plugin = AgentUpdateReminderKey.plugin(pluginID: "claude-code", configRoot: nil, version: "1.1.0")
            let cli = AgentUpdateReminderKey.cli(agentID: "codex", version: "1.1.0")
            let app = AgentUpdateReminderKey.ctrlXApp(version: "3.0.99", build: "32")

            pluginStore.dismiss(plugin)
            cliStore.dismiss(cli)
            appStore.dismiss(app)

            #expect(!pluginStore.shouldShow(plugin))
            #expect(pluginStore.shouldShow(plugin.withVersion("1.2.0")))
            #expect(!cliStore.shouldShow(cli))
            #expect(!appStore.shouldShow(app))
            #expect(appStore.shouldShow(.ctrlXApp(version: "3.0.99", build: "33")))
            #expect(appStore.shouldShow(.ctrlXApp(version: "3.0.100", build: "32")))

            #expect(cliStore.shouldShow(cli.withVersion("1.2.0")))
            #expect(!pluginStore.shouldShow(plugin))
            #expect(!cliStore.shouldShow(cli))

            let reloadedPluginStore = AgentUpdateReminderStore(
                channel: .plugin,
                preferences: preferences,
                now: { now }
            )
            let reloadedCLIStore = AgentUpdateReminderStore(
                channel: .cli,
                preferences: preferences,
                now: { now }
            )
            let reloadedAppStore = AgentUpdateReminderStore(
                channel: .app,
                preferences: preferences,
                now: { now }
            )
            #expect(!reloadedPluginStore.shouldShow(plugin))
            #expect(reloadedPluginStore.shouldShow(cli))
            #expect(reloadedPluginStore.shouldShow(app))
            #expect(!reloadedCLIStore.shouldShow(cli))
            #expect(reloadedCLIStore.shouldShow(plugin))
            #expect(reloadedCLIStore.shouldShow(app))
            #expect(!reloadedAppStore.shouldShow(app))
            #expect(reloadedAppStore.shouldShow(plugin))
            #expect(reloadedAppStore.shouldShow(cli))
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
