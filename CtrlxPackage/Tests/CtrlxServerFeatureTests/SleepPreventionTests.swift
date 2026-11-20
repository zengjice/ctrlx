import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import Dependencies
import Testing
@testable import CtrlxServerFeature

@MainActor
struct SleepPreventionTests {
    @Test("Sleep prevention starts without sessions and preserves an existing opt-out", arguments: [nil, false] as [Bool?])
    func appLifetime(savedPreference: Bool?) {
        let preferences = PreferencesService.inMemory()
        if let savedPreference {
            preferences.setBool(savedPreference, "preventSleepDuringSessions")
        }
        let updates = LockIsolated([Bool]())
        withDependencies {
            $0[PreferencesService.self] = preferences
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[SleepPreventionService.self] = SleepPreventionService(setEnabled: { enabled in
                updates.withValue { $0.append(enabled) }
            })
        } operation: {
            let settings = AppSettings()
            let coordinator = AppCoordinator(settings: settings)
            let initialEnabled = savedPreference ?? true
            #expect(coordinator.windowManager.activeSessionPaneIds.isEmpty)
            coordinator.startSleepPrevention()
            coordinator.startSleepPrevention()
            #expect(updates.value == [initialEnabled])

            settings.preventIdleSleep.toggle()
            #expect(updates.value == [initialEnabled, !initialEnabled])
            #expect(AppSettings().preventIdleSleep == !initialEnabled)

            coordinator.stopSleepPrevention()
            settings.preventIdleSleep.toggle()
            #expect(updates.value == [initialEnabled, !initialEnabled, false])
        }
    }
}
