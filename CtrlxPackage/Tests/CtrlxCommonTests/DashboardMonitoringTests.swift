import Clocks
import ConcurrencyExtras
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct DashboardMonitoringTests {
    @Test("Initial quota reads catch up in five seconds, then return to thirty seconds", arguments: [false, true])
    func initialReadAndNormalCadence(emptyAccounts: Bool) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies {
                $0.continuousClock = clock
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let store = DashboardStore(), source = Source()
                source.omitAccounts = emptyAccounts
                let task = Task { await store.monitor { [source.endpoint] } }
                await Task.megaYield()
                #expect(source.reads == 1)
                await clock.advance(by: .seconds(4))
                #expect(source.reads == 1)
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(source.reads == 2)
                source.availability = .available
                source.omitAccounts = false
                await clock.advance(by: .seconds(5))
                await Task.megaYield()
                #expect(source.reads == 3)
                #expect(store.quotaSummaries().first?.isLow == true)
                await clock.advance(by: .seconds(29))
                #expect(source.reads == 3)
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(source.reads == 4)
                task.cancel()
                await task.value
                await clock.advance(by: .seconds(60))
                #expect(source.reads == 4)
            }
        }
    }

    @Test("An old Host cache gets a short follow-up without treating it as a fresh quota")
    func oldCachedQuota() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies {
                $0.continuousClock = clock
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let store = DashboardStore(), source = Source()
                source.availability = .available
                source.age = 301
                let task = Task { await store.monitor { [source.endpoint] } }
                await Task.megaYield()
                #expect(store.quotaSummaries().first?.isLow == false)
                source.age = 0
                await clock.advance(by: .seconds(5))
                await Task.megaYield()
                #expect(source.reads == 2)
                #expect(store.quotaSummaries().first?.isLow == true)
                task.cancel()
                await task.value
            }
        }
    }

    @Test("Initial polling stops accelerating after one minute")
    func boundedInitialPolling() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies {
                $0.continuousClock = clock
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let store = DashboardStore(), source = Source()
                let task = Task { await store.monitor { [source.endpoint] } }
                await Task.megaYield()
                for _ in 0..<12 {
                    await clock.advance(by: .seconds(5))
                    await Task.megaYield()
                }
                #expect(source.reads == 13)
                await clock.advance(by: .seconds(29))
                #expect(source.reads == 13)
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(source.reads == 14)
                task.cancel()
                await task.value
            }
        }
    }

    @Test("Unavailable accounts and failed requests stop short polling", arguments: ["failed", "unsupported", "signedOut", "transport"])
    func unavailableResultEndsInitialPolling(_ result: String) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies {
                $0.continuousClock = clock
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let store = DashboardStore(), source = Source()
                let task = Task { await store.monitor { [source.endpoint] } }
                await Task.megaYield()
                switch result {
                case "failed": source.availability = .failed
                case "unsupported": source.availability = .unsupported
                case "signedOut":
                    source.availability = .available
                    source.authentication = .signedOut
                default: source.fail = true
                }
                await clock.advance(by: .seconds(5))
                await Task.megaYield()
                #expect(source.reads == 2)
                #expect(store.quotaSummaries().first?.isLow == false)
                await clock.advance(by: .seconds(29))
                #expect(source.reads == 2)
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(source.reads == 3)
                task.cancel()
                await task.value
            }
        }
    }

    @Test("A restarted monitor waits for the cancelled read instead of losing its first refresh")
    func reconnectDuringInFlightRead() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies {
                $0.continuousClock = clock
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let store = DashboardStore(), old = Source(), current = Source(), abandoned = Source()
                current.availability = .available
                var release: CheckedContinuation<Void, Never>?
                let oldTask = Task {
                    await store.monitor {
                        [.init(host: old.endpoint.host) {
                            await withCheckedContinuation { release = $0 }
                            return try await old.endpoint.read()
                        }]
                    }
                }
                await Task.megaYield()
                oldTask.cancel()
                let replacement = Task { await store.monitor { [current.endpoint] } }
                let cancelledWaiter = Task { await store.monitor { [abandoned.endpoint] } }
                await Task.megaYield()
                #expect(current.reads == 0)
                cancelledWaiter.cancel()
                release?.resume()
                await oldTask.value
                await cancelledWaiter.value
                await Task.megaYield()
                // No clock advancement: the reconnect read starts as soon as the old request drains.
                #expect(current.reads == 1)
                #expect(abandoned.reads == 0)
                #expect(store.quotaSummaries().first?.isLow == true)
                replacement.cancel()
                await replacement.value
            }
        }
    }

    @MainActor
    final private class Source {
        let id = UUID()
        var reads = 0
        var availability: DashboardAccount.Availability = .waiting
        var authentication: DashboardAccount.Authentication = .signedIn
        var age: TimeInterval = 0
        var fail = false
        var omitAccounts = false

        var endpoint: DashboardEndpoint {
            .init(host: .init(id: "host", name: "Host", isConnected: true, isSupported: true)) {
                self.reads += 1
                if self.fail {
                    throw CocoaError(.fileReadUnknown)
                }
                let now = Date()
                return .init(hostID: self.id, generatedAt: now, timeZoneIdentifier: "UTC", accounts: self.omitAccounts ? [] : [
                    .init(
                        id: "default", pluginID: "codex", providerName: "Codex", label: "Personal", configurationLabel: "Default",
                        identity: .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex"),
                        authentication: self.authentication, availability: self.availability,
                        quotaObservedAt: now.addingTimeInterval(-self.age), windows: [.init(id: "week", title: "Week", usedPercent: 95)]
                    ),
                ])
            }
        }
    }
}
