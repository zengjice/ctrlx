import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct DashboardStoreTests {
    @Test
    func unsupportedAndOfflineHostsAreNeverQueried() async {
        await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let store = DashboardStore()
            await store.refresh([
                .init(host: .init(id: "old", name: "Old", isConnected: true)) { Issue.record("Old Host queried")
                    throw CancellationError()
                },
                .init(host: .init(id: "offline", name: "Offline", isSupported: true)) { Issue.record("Offline Host queried")
                    throw CancellationError()
                },
            ])
            #expect(store.hosts.count == 2)
            #expect(store.hosts.allSatisfy { $0.snapshot == nil })
        }
    }

    @Test
    func restoredOfflineDataDoesNotClaimToBeFreshAndUnpairedHostIsRemoved() async {
        let preferences = PreferencesService.inMemory()
        await withDependencies { $0[PreferencesService.self] = preferences } operation: {
            let snapshot = DashboardSnapshot(hostID: UUID(), generatedAt: Date(), timeZoneIdentifier: "UTC")
            let first = DashboardStore()
            await first.refresh([.init(host: .init(id: "a", name: "Host", isConnected: true, isSupported: true)) { snapshot }])
            let second = DashboardStore()
            await second.refresh([.init(host: .init(id: "a", name: "Host")) { throw CancellationError() }])
            #expect(second.hosts.first?.snapshot == snapshot)
            #expect(second.hosts.first?.isConnected == false)
            #expect(second.hosts.first?.receivedAt == first.hosts.first?.receivedAt)
            await second.refresh([])
            #expect(second.hosts.isEmpty)
        }
    }

    @Test
    func failedReadKeepsLastObservationButDoesNotAdvanceItsTime() async {
        await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let store = DashboardStore()
            let snapshot = DashboardSnapshot(hostID: UUID(), generatedAt: Date(), timeZoneIdentifier: "UTC")
            let host = DashboardHost(id: "a", name: "Host", isConnected: true, isSupported: true)
            await store.refresh([.init(host: host) { snapshot }])
            let received = store.hosts.first?.receivedAt
            await store.refresh([.init(host: host) { throw CancellationError() }])
            #expect(store.hosts.first?.snapshot == snapshot)
            #expect(store.hosts.first?.receivedAt == received)
            #expect(store.hosts.first?.error != nil)
        }
    }

    @Test
    func lateReplyAfterDismissalCannotBecomeFreshData() async {
        await withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
            let store = DashboardStore()
            let gate = Gate()
            let task = Task {
                await store.refresh([.init(host: .init(id: "a", name: "Host", isConnected: true, isSupported: true)) {
                    await gate.wait()
                    return .init(hostID: UUID(), generatedAt: Date(), timeZoneIdentifier: "UTC")
                }])
            }
            while !store.isRefreshing {
                await Task.yield()
            }
            task.cancel()
            await gate.release()
            await task.value
            #expect(store.hosts.first?.snapshot == nil)
            #expect(store.isRefreshing == false)
        }
    }

    private actor Gate {
        private var open = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if !open {
                await withCheckedContinuation { continuation = $0 }
            }
        }

        func release() {
            open = true
            continuation?.resume()
            continuation = nil
        }
    }
}
