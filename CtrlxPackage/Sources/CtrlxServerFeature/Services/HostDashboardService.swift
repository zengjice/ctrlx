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
        private var queriedAt: Date?
        private var query: Task<Void, Never>?

        func snapshot(
            hostID: UUID, paths: [String], sources: [Source],
            usage: UsageOverview?, workingAgentCount: Int, at date: Date = Date()
        ) async -> DashboardSnapshot {
            let active = Set(sources.map(\.id))
            accounts = accounts.filter { active.contains($0.key) }
            let needsQuery = queriedAt.map { date.timeIntervalSince($0) >= 60 || date < $0 } ?? true
            if query == nil, needsQuery {
                queriedAt = date
                query = Task {
                    await withTaskGroup(of: (String, [DashboardAccount]).self) { group in
                        for source in sources {
                            group.addTask {
                                let result = await source.reporter?.dashboardAccounts() ?? [DashboardAccount(
                                    id: source.id, pluginID: source.id, providerName: source.name,
                                    label: source.name, configurationLabel: "Default",
                                    availability: .unsupported, detail: "This Agent does not provide account quotas."
                                )]
                                return (source.id, result)
                            }
                        }
                        for await (id, values) in group {
                            accounts[id] = values
                        }
                    }
                    query = nil
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
            query?.cancel()
            query = nil
        }
    }
#endif
