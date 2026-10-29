#if os(macOS)
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @Suite("App shutdown installer deadline")
    @MainActor
    struct AppShutdownInstallerDeadlineTests {
        @Test("Cleanup may finish after the old fifteen-second installer limit")
        func cleanupPastOldInstallerDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                var replies = 0
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = AppShutdownDelegate()
                    delegate.replyHandler = { replies += 1 }
                    delegate.onShouldTerminate = { try? await clock.sleep(for: .seconds(20)) }
                    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
                    await Task.megaYield()
                    await clock.advance(by: .seconds(15))
                    #expect(replies == 0)
                    await clock.advance(by: .seconds(5))
                    #expect(replies == 1)
                    await clock.advance(by: .seconds(30))
                    #expect(replies == 1)
                }
            }
        }
    }
#endif
