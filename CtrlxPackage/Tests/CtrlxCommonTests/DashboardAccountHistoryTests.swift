import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct DashboardAccountHistoryTests {
    private let one = UUID()
    private let two = UUID()
    private let reset = Date().addingTimeInterval(3_600)

    private func endpoint(_ id: String, account: String = "A", used: Double, age: Double = 0, connected: Bool = true, skew: Double = 0) -> DashboardEndpoint {
        let machine = id == "one" ? one : two
        let reset = reset
        return .init(host: .init(id: id, name: id, isConnected: connected, isSupported: true)) {
            let generated = Date().addingTimeInterval(skew)
            return .init(hostID: machine, generatedAt: generated, timeZoneIdentifier: "UTC", accounts: [
                .init(
                    id: "default", pluginID: "codex", providerName: "Codex", label: account, configurationLabel: "Default",
                    identity: .init(providerID: "codex", accountID: account, workspaceID: "personal", poolID: "codex"),
                    authentication: .signedIn, availability: .available, quotaObservedAt: generated.addingTimeInterval(-age),
                    windows: [.init(id: "week", title: "7 days", usedPercent: used, resetsAt: reset)]
                ),
            ])
        }
    }

    private func exhausted(_ store: DashboardStore) async {
        await store.refresh([endpoint("one", used: 40, age: 120), endpoint("two", used: 40)])
        await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", used: 100)])
    }

    private func group(_ account: String, in store: DashboardStore) throws -> DashboardAccountGroup {
        try #require(DashboardOverview.accounts(in: store.hosts).first {
            if case let .verified(identity) = $0.id {
                return identity.accountID == account
            }
            return false
        })
    }

    @Test("Page and Host detail keep history from a superseded route without duplicating current bindings", arguments: [false, true])
    func duplicateRoutesKeepPageAndSummaryInSync(reverse: Bool) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            var current = endpoint("new", account: "B", used: 20)
            current.host.isLocal = true
            let endpoints = [endpoint("one", used: 40, connected: false), endpoint("two", used: 100, connected: false), current]
            await store.refresh(reverse ? Array(endpoints.reversed()) : endpoints)

            let expected = try group("A", in: store)
            let summary = try #require(store.quotaSummaries().first { $0.id == expected.id })
            #expect(summary.remaining == 0)
            #expect(DashboardOverview.uniqueHosts(store.hosts).count == 2)

            let page = DashboardView(store: store, endpoints: { [] })
            let a = try #require(page.accountGroups.first { $0.id == expected.id })
            #expect(DashboardQuotaSummary(group: a, at: Date()).remaining == summary.remaining)
            #expect(a.sources.map(\.host.id) == ["one"])
            #expect(a.selection?.source.host.id == "two")
            #expect(a.selection?.source.isHistorical == true)
            #expect(!DashboardQuotaSummary(group: a, at: Date()).isCurrent)

            let detail = try #require(page.accountGroups.first { $0.sources.contains { $0.host.id == "one" } })
            #expect(DashboardQuotaSummary(group: detail, at: Date()).remaining == 0)
            let b = try #require(page.accountGroups.first { $0.id != expected.id })
            #expect(b.sources.map(\.host.id) == ["new"])
        }
    }

    @Test("Switching the online Host cannot restore an offline Host's old quota", arguments: [0.0, 86_400.0])
    func accountSwitchKeepsLastKnownQuota(skew: Double) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            let before = try group("A", in: store)
            #expect(DashboardQuotaSummary(group: before, at: Date()).remaining == 0)
            let observed = before.selection?.source.interval

            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 20, skew: skew)])
            let a = try group("A", in: store)
            let summary = DashboardQuotaSummary(group: a, at: Date())
            #expect(summary.remaining == 0)
            #expect(!summary.isCurrent)
            #expect(a.sources.map(\.host.id) == ["one"])
            #expect(a.selection?.source.host.id == "two")
            #expect(a.selection?.source.interval == observed)
            #expect(store.quotaRecoveryNotices.isEmpty)
            #expect(try group("B", in: store).selection?.source.account.windows.first?.remainingPercent(at: Date()) == 80)

            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 25)])
            #expect(try group("A", in: store).selection?.source.interval == observed)
            #expect(try group("A", in: store).selection?.source.account.windows.first?.remainingPercent(at: Date()) == 0)
        }
    }

    @Test("The retained quota survives reopening before the ordinary cache-save interval")
    func accountSwitchPersistsLastKnownQuota() async throws {
        let preferences = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = preferences
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 20)])

            let restored = DashboardStore()
            await restored.refresh([endpoint("one", used: 40, connected: false), endpoint("two", used: 20, connected: false)])
            let summary = try DashboardQuotaSummary(group: group("A", in: restored), at: Date())
            #expect(summary.remaining == 0)
            #expect(!summary.isCurrent)
        }
    }

    @Test("A fresh provider observation can increase quota after switching back")
    func freshQuotaSupersedesHistory() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 20)])
            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", used: 0)])
            let summary = try DashboardQuotaSummary(group: group("A", in: store), at: Date())
            #expect(summary.remaining == 100)
            #expect(summary.isCurrent)
        }
    }

    @Test("Previous observations cannot keep an account visible after all sources switch away")
    func inactiveAccountDisappears() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 20)])
            await store.refresh([endpoint("one", account: "B", used: 20), endpoint("two", account: "B", used: 20)])
            let groups = DashboardOverview.accounts(in: store.hosts)
            #expect(groups.count == 1)
            #expect(groups.first?.selection?.source.account.identity?.accountID == "B")
            #expect(!store.hosts.flatMap { $0.quotaObservations ?? [] }.contains { $0.account.identity?.accountID == "A" })
        }
    }

    @Test("Temporary identity loading cannot discard the last shared quota")
    func waitingAccountsKeepObservations() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            let waiting = ["one", "two"].map { id in
                let machine = id == "one" ? one : two
                return DashboardEndpoint(host: .init(id: id, name: id, isConnected: true, isSupported: true)) {
                    .init(hostID: machine, generatedAt: Date(), timeZoneIdentifier: "UTC", accounts: [
                        .init(id: "default", pluginID: "codex", providerName: "Codex", label: "Codex", configurationLabel: "Default"),
                    ])
                }
            }
            await store.refresh(waiting)
            await store.refresh([endpoint("one", used: 40, age: 120), endpoint("two", account: "B", used: 20)])
            let summary = try DashboardQuotaSummary(group: group("A", in: store), at: Date())
            #expect(summary.remaining == 0)
            #expect(!summary.isCurrent)
        }
    }

    @Test("History cannot cross workspaces or quota pools for the same account", arguments: ["workspace", "pool"])
    func historyUsesFullAccountIdentity(dimension: String) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            let a = try group("A", in: store)
            let original = try #require(a.selection).source
            var otherPool = try #require(store.hosts.first { $0.id == "one" })
            otherPool.quotaObservations = try [.init(account: original.account, interval: #require(original.interval))]
            if dimension == "workspace" {
                otherPool.snapshot?.accounts[0].identity?.workspaceID = "team"
            } else {
                otherPool.snapshot?.accounts[0].identity?.poolID = "other"
            }
            let groups = DashboardOverview.accounts(in: [otherPool])
            #expect(groups.count == 1)
            #expect(groups.first?.previousSources.isEmpty == true)
            #expect(groups.first?.selection?.source.account.windows.first?.remainingPercent(at: Date()) == 60)
        }
    }

    @Test("Historical quota does not put an unsupported current account back in the titlebar")
    func unsupportedSourcesStayOutOfTitlebar() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[DashboardNotificationClient.self].notify = { _ in }
        } operation: {
            let store = DashboardStore()
            await exhausted(store)
            await store.refresh([endpoint("one", used: 40, connected: false), endpoint("two", account: "B", used: 20)])
            var hosts = store.hosts
            let index = try #require(hosts.firstIndex { $0.id == "one" })
            hosts[index].snapshot?.accounts[0].availability = .unsupported
            hosts[index].snapshot?.accounts[0].windows = []
            #expect(DashboardOverview.accounts(in: hosts).count == 2)
            let toolbar = DashboardToolbarAccount.accounts(in: hosts, at: Date())
            #expect(toolbar.map(\.account.identity?.accountID) == ["B"])
        }
    }
}
