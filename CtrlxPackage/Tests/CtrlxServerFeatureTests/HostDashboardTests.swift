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
        func stalledInitialDiskReadDoesNotBlockAccountsOrViewerResponses() async throws {
            let disk = StalledDisk()
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

    private actor StalledDisk {
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
        func dashboardAccounts() async -> [DashboardAccount] {
            calls += 1
            return [.init(id: "source", pluginID: "fixture", providerName: "Fixture", label: "Test", configurationLabel: "Default", availability: .available)]
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
