import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct DashboardStoreTests {
    @Test
    func sharedStoreAlertsOnceAndToggleStartsWithSilentBaseline() async {
        let sink = AlertSink()
        await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { alert in await sink.append(alert) }
        } operation: {
            let store = DashboardStore()
            let hostID = UUID()
            @MainActor
            func endpoint(used: Double) -> DashboardEndpoint {
                .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
                    let now = Date()
                    return .init(hostID: hostID, generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                        .init(
                            id: "default",
                            pluginID: "codex",
                            providerName: "Codex",
                            label: "Personal",
                            configurationLabel: "Default",
                            identity: .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex"),
                            authentication: .signedIn,
                            availability: .available,
                            quotaObservedAt: now,
                            windows: [.init(id: "week", title: "7 days", usedPercent: used)]
                        ),
                    ])
                }
            }
            await store.refresh([endpoint(used: 80)])
            await store.refresh([endpoint(used: 95)])
            await store.refresh([endpoint(used: 95)])
            #expect(await sink.count == 1)
            #expect(store.quotaSummaries().first?.isLow == true)
            store.lowQuotaAlertsEnabled = false
            await store.refresh([endpoint(used: 80)])
            await store.refresh([endpoint(used: 95)])
            #expect(await sink.count == 1)
            store.lowQuotaAlertsEnabled = true
            await store.refresh([endpoint(used: 95)])
            #expect(await sink.count == 1)
        }
    }

    private actor AlertSink {
        var count = 0
        func append(_: DashboardQuotaAlert) {
            count += 1
        }
    }

    @Test
    func quotaRecoveryNoticePersistsUntilReadOrAccountRemoval() async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = preferences
        } operation: {
            let store = DashboardStore()
            let hostID = UUID()
            @MainActor
            func endpoint(used: Double, hasAccount: Bool = true) -> DashboardEndpoint {
                .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
                    let now = Date()
                    return .init(hostID: hostID, generatedAt: now, timeZoneIdentifier: "UTC", accounts: hasAccount ? [
                        .init(
                            id: "default",
                            pluginID: "codex",
                            providerName: "Codex",
                            label: "Personal",
                            configurationLabel: "Default",
                            identity: .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex"),
                            authentication: .signedIn,
                            availability: .available,
                            quotaObservedAt: now,
                            windows: [.init(id: "week", title: "7 days", usedPercent: used)]
                        ),
                    ] : [])
                }
            }

            await store.refresh([endpoint(used: 95)])
            #expect(store.quotaRecoveryNotices.isEmpty)
            await store.refresh([endpoint(used: 10)])
            let notice = try #require(store.quotaRecoveryNotices.first)
            #expect(notice.account == "Codex · Personal")
            #expect(notice.detail.contains("90% remaining"))

            await store.refresh([endpoint(used: 20)])
            #expect(store.quotaRecoveryNotices.count == 1)

            let restored = DashboardStore()
            #expect(restored.quotaRecoveryNotices == store.quotaRecoveryNotices)
            restored.markQuotaRecoveryRead(notice.id)
            #expect(restored.quotaRecoveryNotices.isEmpty)
            #expect(DashboardStore().quotaRecoveryNotices.isEmpty)

            await store.refresh([endpoint(used: 20, hasAccount: false)])
            #expect(store.quotaRecoveryNotices.isEmpty)
        }
    }

    @Test
    func quotaRecoveryNoticeSurvivesHostRestartWhileAccountIdentityLoads() async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = preferences
        } operation: {
            let hostID = UUID()
            @MainActor
            func endpoint(used: Double, availability: DashboardAccount.Availability, hasIdentity: Bool) -> DashboardEndpoint {
                .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
                    let now = Date()
                    return .init(hostID: hostID, generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                        .init(
                            id: "default",
                            pluginID: "codex",
                            providerName: "Codex",
                            label: "Personal",
                            configurationLabel: "Default",
                            identity: hasIdentity
                                ? .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex")
                                : nil,
                            authentication: hasIdentity ? .signedIn : .unknown,
                            availability: availability,
                            quotaObservedAt: hasIdentity ? now : nil,
                            windows: hasIdentity ? [.init(id: "week", title: "7 days", usedPercent: used)] : []
                        ),
                    ])
                }
            }

            let first = DashboardStore()
            await first.refresh([endpoint(used: 95, availability: .available, hasIdentity: true)])
            await first.refresh([endpoint(used: 10, availability: .available, hasIdentity: true)])
            let notice = try #require(first.quotaRecoveryNotices.first)

            let restarted = DashboardStore()
            await restarted.refresh([endpoint(used: 10, availability: .waiting, hasIdentity: false)])
            #expect(restarted.quotaRecoveryNotices == [notice])

            await restarted.refresh([endpoint(used: 10, availability: .available, hasIdentity: true)])
            #expect(restarted.quotaRecoveryNotices == [notice])
        }
    }

    @Test
    func quotaRecoveryNoticeSurvivesDisconnectWhileAccountIdentityLoads() async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = preferences
        } operation: {
            let hostID = UUID()
            @MainActor
            func accountEndpoint(_ availability: DashboardAccount.Availability, hasIdentity: Bool) -> DashboardEndpoint {
                .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
                    let now = Date()
                    return .init(hostID: hostID, generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                        .init(
                            id: "default",
                            pluginID: "codex",
                            providerName: "Codex",
                            label: "Personal",
                            configurationLabel: "Default",
                            identity: hasIdentity
                                ? .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex")
                                : nil,
                            authentication: hasIdentity ? .signedIn : .unknown,
                            availability: availability,
                            quotaObservedAt: hasIdentity ? now : nil,
                            windows: hasIdentity ? [.init(id: "week", title: "7 days", usedPercent: 10)] : []
                        ),
                    ])
                }
            }

            let first = DashboardStore()
            await first.refresh([
                .init(host: .init(id: "local", name: "This Mac", isConnected: true, isSupported: true)) {
                    let now = Date()
                    return .init(hostID: hostID, generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                        .init(
                            id: "default",
                            pluginID: "codex",
                            providerName: "Codex",
                            label: "Personal",
                            configurationLabel: "Default",
                            identity: .init(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex"),
                            authentication: .signedIn,
                            availability: .available,
                            quotaObservedAt: now,
                            windows: [.init(id: "week", title: "7 days", usedPercent: 95)]
                        ),
                    ])
                },
            ])
            await first.refresh([accountEndpoint(.available, hasIdentity: true)])
            let notice = try #require(first.quotaRecoveryNotices.first)

            let restarted = DashboardStore()
            await restarted.refresh([accountEndpoint(.waiting, hasIdentity: false)])
            #expect(restarted.quotaRecoveryNotices == [notice])

            await restarted.refresh([
                .init(host: .init(id: "local", name: "This Mac")) { throw CancellationError() },
            ])
            #expect(restarted.quotaRecoveryNotices == [notice])

            await restarted.refresh([accountEndpoint(.available, hasIdentity: true)])
            #expect(restarted.quotaRecoveryNotices == [notice])
        }
    }

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
