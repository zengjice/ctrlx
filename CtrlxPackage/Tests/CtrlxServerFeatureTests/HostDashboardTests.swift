#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct HostDashboardTests {
        @Test
        func stalledProviderDoesNotBlockOtherRefreshesOrDuplicateRequests() async throws {
            let stalled = SuspendedRead()
            try await withResources {
                let service = HostDashboardService()
                let date = Date()
                let slow = AccountCore { call in
                    if call == 2 {
                        await stalled.read()
                    }
                    return [.init(id: "slow", pluginID: "slow", providerName: "Slow", label: "Slow", configurationLabel: "Default", availability: .available, quotaObservedAt: date, windows: [.init(id: "weekly", title: "Week", usedPercent: 40)])]
                }
                let fast = AccountCore()
                let sources = [
                    HostDashboardService.Source(id: "slow", name: "Slow", reporter: slow),
                    HostDashboardService.Source(id: "fast", name: "Fast", reporter: fast),
                ]
                let id = UUID()
                for round in 0..<4 {
                    let now = date.addingTimeInterval(Double(round * 61))
                    var snapshot: DashboardSnapshot?
                    for _ in 0..<200 {
                        snapshot = await service.snapshot(hostID: id, paths: [], sources: sources, usage: nil, workingAgentCount: 0, at: now)
                        if snapshot?.accounts.last?.label == "Query \(round + 1)", snapshot?.accounts.first?.availability != .waiting {
                            break
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    #expect(snapshot?.accounts.last?.label == "Query \(round + 1)")
                    #expect(snapshot?.resources?.memory?.usedBytes == 40)
                    if round >= 2 {
                        let old = try #require(snapshot?.accounts.first)
                        #expect(old.availability == .failed)
                        #expect(old.quotaObservedAt == date)
                        #expect(old.windows.first?.usedPercent == 40)
                        #expect(old.detail?.contains("taking too long") == true)
                    }
                }
                #expect(await fast.calls == 4)
                #expect(await slow.calls == 2)
                #expect(await stalled.calls == 1)
                await service.stop()
                await stalled.release()
            }
        }

        @Test(arguments: [false, true])
        func stoppedOrRemovedQueryCannotOverwriteReplacement(stop: Bool) async throws {
            let stalled = SuspendedRead()
            try await withResources {
                let service = HostDashboardService()
                let old = AccountCore { _ in
                    await stalled.read()
                    return [.init(id: "old", pluginID: "fixture", providerName: "Old", label: "Old", configurationLabel: "Default", availability: .available)]
                }
                let id = UUID(), date = Date()
                let source = HostDashboardService.Source(id: "fixture", name: "Fixture", reporter: old)
                _ = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date)
                for _ in 0..<200 {
                    if await stalled.calls == 1 {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(await stalled.calls == 1)
                if stop {
                    await service.stop()
                } else {
                    _ = await service.snapshot(hostID: id, paths: [], sources: [], usage: nil, workingAgentCount: 0, at: date)
                }
                let replacement = AccountCore()
                let newSource = HostDashboardService.Source(id: "fixture", name: "Fixture", reporter: replacement)
                for _ in 0..<200 {
                    let snapshot = await service.snapshot(hostID: id, paths: [], sources: [newSource], usage: nil, workingAgentCount: 0, at: date)
                    if snapshot.accounts.first?.label == "Query 1" {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                await stalled.release()
                for _ in 0..<200 {
                    if await old.completed == 1 {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                for _ in 0..<10 {
                    let snapshot = await service.snapshot(hostID: id, paths: [], sources: [newSource], usage: nil, workingAgentCount: 0, at: date)
                    #expect(snapshot.accounts.first?.label == "Query 1")
                    await Task.yield()
                }
                #expect(await replacement.calls == 1)
                await service.stop()
            }
        }

        private func withResources(_ operation: () async throws -> Void) async rethrows {
            try await withDependencies {
                $0[HostResourceClient.self].cpuTicks = { [1, 2, 3, 4] }
                $0[HostResourceClient.self].memory = { .init(totalBytes: 100, usedBytes: 40, compressedBytes: 0, swapBytes: 0, pressure: .normal) }
                $0[HostResourceClient.self].disk = { _ in .init(id: "volume", name: "Disk", totalBytes: 100, availableBytes: 50) }
            } operation: { try await operation() }
        }

        @Test
        func stalledInitialDiskReadDoesNotBlockAccountsOrViewerResponses() async throws {
            let disk = SuspendedRead()
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await disk.release()
            }
            defer { watchdog.cancel() }
            try await withDependencies {
                $0[HostResourceClient.self].cpuTicks = { [1, 2, 3, 4] }
                $0[HostResourceClient.self].memory = { .init(totalBytes: 100, usedBytes: 40, compressedBytes: 0, swapBytes: 0, pressure: .normal) }
                $0[HostResourceClient.self].disk = { _ in
                    await disk.read()
                    return .init(id: "volume", name: "Disk", totalBytes: 100, availableBytes: 50)
                }
            } operation: {
                let service = HostDashboardService()
                let reporter = AccountCore()
                let source = HostDashboardService.Source(id: "fixture", name: "Fixture", reporter: reporter)
                let id = UUID()
                let date = Date()
                var ready = false
                for _ in 0..<100 {
                    let result = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date)
                    #expect(result.resources?.memory?.usedBytes == 40)
                    #expect(result.resources?.disks.isEmpty == true)
                    if result.accounts.first?.availability == .available, await disk.calls == 1 {
                        ready = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(ready)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            let result = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date)
                            #expect(result.accounts.first?.availability == .available)
                        }
                    }
                }
                #expect(await disk.released == false)
                #expect(await disk.calls == 1)
                await disk.release()
                await service.stop()
            }
        }

        @Test
        func multipleViewersShareQuotaQueryAndClosingStopsPolling() async {
            await withDependencies {
                $0[HostResourceClient.self].cpuTicks = { [1, 2, 3, 4] }
                $0[HostResourceClient.self].memory = { .init(totalBytes: 100, usedBytes: 40, compressedBytes: 0, swapBytes: 0, pressure: .normal) }
                $0[HostResourceClient.self].disk = { _ in .init(id: "volume", name: "Disk", totalBytes: 100, availableBytes: 50) }
            } operation: {
                let service = HostDashboardService()
                let reporter = AccountCore()
                let id = UUID()
                let date = Date()
                let source = HostDashboardService.Source(id: "fixture", name: "Fixture", reporter: reporter)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask { _ = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date) }
                    }
                }
                var ready = false
                for _ in 0..<100 {
                    let snapshot = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date)
                    if snapshot.accounts.first?.availability == .available {
                        ready = true
                        break
                    }
                    await Task.yield()
                }
                #expect(ready)
                #expect(await reporter.calls == 1)
                _ = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date.addingTimeInterval(30))
                #expect(await reporter.calls == 1)
                _ = await service.snapshot(hostID: id, paths: [], sources: [source], usage: nil, workingAgentCount: 0, at: date.addingTimeInterval(61))
                for _ in 0..<100 {
                    if await reporter.calls == 2 {
                        break
                    }
                    await Task.yield()
                }
                #expect(await reporter.calls == 2)
                await service.stop()
                let removed = await service.snapshot(hostID: id, paths: [], sources: [], usage: nil, workingAgentCount: 0, at: date.addingTimeInterval(62))
                #expect(removed.accounts.isEmpty)
            }
        }
    }

    private actor SuspendedRead {
        var calls = 0
        var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func read() async {
            calls += 1
            if !released {
                await withCheckedContinuation { continuation = $0 }
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor AccountCore: AgentAccountReporting {
        private(set) var calls = 0
        private(set) var completed = 0
        private let read: @Sendable (Int) async -> [DashboardAccount]

        init(read: @escaping @Sendable (Int) async -> [DashboardAccount] = { call in
            [.init(id: "source", pluginID: "fixture", providerName: "Fixture", label: "Query \(call)", configurationLabel: "Default", availability: .available)]
        }) {
            self.read = read
        }

        func dashboardAccounts() async -> [DashboardAccount] {
            calls += 1
            let result = await read(calls)
            completed += 1
            return result
        }

        func initialize(_: PluginEnv, host _: any PluginHost) async throws { }
        func handleIngress(_: IngressFrame) async -> PluginEvent? {
            nil
        }

        func deliverResponse(sessionID _: String, requestID _: String, _: AgentResponse) async { }
        func refreshProjects() async { }
        func commandForLaunch(projectPath _: String) async -> LaunchCommand? {
            nil
        }

        func install(configRoot _: String?) async throws -> InstallResult {
            .alreadyInstalled
        }

        func uninstall(configRoot _: String?) async throws { }
        func installStatus(configRoot _: String?) async -> PluginInstallStatus {
            .installed(version: "1")
        }

        func applySettings(_: Data) async -> SettingsResult {
            .applied
        }

        func shutdown() async { }
    }
#endif
