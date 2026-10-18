#if os(macOS)
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Foundation

    /// One cache per Host, shared by its local window and every paired Viewer.
    actor HostDashboardService {
        struct Source: Sendable {
            let id: String
            let name: String
            let reporter: (any AgentAccountReporting)?
        }

        private let resources = DashboardResourceSampler()
        private var accounts: [String: [DashboardAccount]] = [:]
        private var queriedAt: [String: Date] = [:]
        private var queries: [String: Task<Void, Never>] = [:]

        func snapshot(
            hostID: UUID, paths: [String], sources: [Source],
            usage: UsageOverview?, workingAgentCount: Int, at date: Date = Date()
        ) async -> DashboardSnapshot {
            let active = Set(sources.map(\.id))
            accounts = accounts.filter { active.contains($0.key) }
            for id in queries.keys where !active.contains(id) {
                queries.removeValue(forKey: id)?.cancel()
            }
            queriedAt = queriedAt.filter { active.contains($0.key) }
            for source in sources {
                let needsQuery = queriedAt[source.id].map { date.timeIntervalSince($0) >= 60 || date < $0 } ?? true
                if queries[source.id] != nil {
                    if needsQuery {
                        // Keep one in-flight call even if a provider ignores cancellation.
                        // Its old sample must not continue looking like a successful refresh.
                        let previous = accounts[source.id] ?? [DashboardAccount(
                            id: source.id, pluginID: source.id, providerName: source.name,
                            label: source.name, configurationLabel: "Default"
                        )]
                        accounts[source.id] = previous.map { account in
                            var account = account
                            account.availability = .failed
                            account.authentication = .unknown
                            account.detail = "Account refresh is taking too long. Showing the last observation, if available."
                            return account
                        }
                    }
                    continue
                }
                guard needsQuery else { continue }
                queriedAt[source.id] = date
                queries[source.id] = Task {
                    let result = await source.reporter?.dashboardAccounts() ?? [DashboardAccount(
                        id: source.id, pluginID: source.id, providerName: source.name,
                        label: source.name, configurationLabel: "Default",
                        availability: .unsupported, detail: "This Agent does not provide account quotas."
                    )]
                    // Removal/stop cancels this task; late responses cannot overwrite a replacement.
                    guard !Task.isCancelled else { return }
                    accounts[source.id] = result
                    queries[source.id] = nil
                }
            }
            let sampled = await resources.read(paths: paths, at: date)
            return DashboardSnapshot(
                hostID: hostID, generatedAt: Date(), timeZoneIdentifier: TimeZone.current.identifier,
                resources: sampled,
                accounts: sources.flatMap { source in
                    accounts[source.id] ?? [DashboardAccount(
                        id: source.id, pluginID: source.id, providerName: source.name,
                        label: source.name, configurationLabel: "Default", availability: .waiting,
                        detail: "Reading account information…"
                    )]
                },
                usage: usage, workingAgentCount: workingAgentCount
            )
        }

        func stop() {
            for query in queries.values {
                query.cancel()
            }
            queries.removeAll()
            queriedAt.removeAll()
        }
    }
#endif
