#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent plugin installation state") @MainActor
    struct AgentPluginInstallationsTests {
        private actor Core: AgentPluginMaintenance {
            var status: PluginInstallStatus = .installed(version: "1.0.0")
            var checks = 0
            var reinstalls = 0
            var checkedRoots: [String?] = []
            var reinstalledRoots: [String?] = []
            var failReinstall = false
            var blocked = false
            var resume: CheckedContinuation<Void, Never>?
            let checkStarted = AsyncStream<Void>.makeStream()
            func initialize(_: PluginEnv, host _: any PluginHost) { }
            func handleIngress(_: IngressFrame) -> PluginEvent? {
                nil
            }

            func deliverResponse(sessionID _: String, requestID _: String, _: AgentResponse) { }
            func refreshProjects() { }
            func commandForLaunch(projectPath _: String) -> LaunchCommand? {
                nil
            }

            func install(configRoot _: String?) -> InstallResult {
                .alreadyInstalled
            }

            func uninstall(configRoot _: String?) {
                status = .notInstalled
            }

            func applySettings(_: Data) -> SettingsResult {
                .applied
            }

            func shutdown() { }
            func bundledPluginVersion() -> String {
                "1.1.0"
            }

            func configure(_ status: PluginInstallStatus, fail: Bool = false, blocked: Bool = false) {
                self.status = status
                failReinstall = fail
                self.blocked = blocked
            }

            func unblock() {
                blocked = false
                resume?.resume()
                resume = nil
            }

            func installStatus(configRoot: String?) async -> PluginInstallStatus {
                checks += 1
                checkedRoots.append(configRoot)
                if blocked {
                    await withCheckedContinuation { resume = $0
                        checkStarted.continuation.yield(())
                    }
                }
                return status
            }

            func reinstall(configRoot: String?) throws -> PluginInstallStatus {
                reinstalls += 1
                reinstalledRoots.append(configRoot)
                status = .notInstalled
                if failReinstall {
                    throw AgentPluginInstallError("Install failed; retry")
                }
                status = .installed(version: "1.1.0")
                return status
            }
        }

        @Test("Startup checks all configured roots once and dismisses notices per root")
        func startup() async {
            let core = Core()
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { _ in core }
            let locations = [AgentPluginLocation(pluginID: "codex", configRoot: nil), .init(pluginID: "codex", configRoot: "/second")]
            await service.checkAtStartup(locations + locations)
            await service.checkAtStartup(locations)
            #expect(await core.checks == 2)
            #expect(Set(service.updates) == Set(locations))
            service.dismiss(locations[0])
            await service.refresh(locations[0])
            #expect(service.updates == [locations[1]])
        }

        @Test("Only a known older installed version produces a notice", arguments: ["codex", "claude-code"])
        func versions(pluginID: String) async {
            let core = Core()
            let location = AgentPluginLocation(pluginID: pluginID, configRoot: nil)
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { _ in core }
            for status: PluginInstallStatus in [.notInstalled, .agentUnavailable, .checkFailed(message: "offline"), .installed(version: nil), .installed(version: "unknown"), .installed(version: "1.1.0"), .installed(version: "2.0.0")] {
                await core.configure(status)
                await service.refresh(location)
                #expect(service.updates.isEmpty)
                #expect(service.installations[location]?.status == status)
            }
        }

        @Test("Failed reinstall shows actual remaining state and can be retried")
        func retry() async {
            let core = Core()
            let location = AgentPluginLocation(pluginID: "claude-code", configRoot: nil)
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { _ in core }
            await core.configure(.installed(version: "1.0.0"), fail: true)
            await service.reinstall(location)
            #expect(service.installations[location]?.status == .notInstalled)
            #expect(service.installations[location]?.error != nil)
            #expect(service.installations[location]?.lastChange == nil)
            await core.configure(.notInstalled)
            await service.reinstall(location)
            #expect(service.installations[location]?.error == nil)
            #expect(service.installations[location]?.lastChange == .installed)
            #expect(service.installations[location]?.status == .installed(version: "1.1.0"))
        }

        @Test("Post-change notices distinguish reinstall from uninstall and clear on a failed operation", arguments: ["codex", "claude-code"])
        func changeNotices(pluginID: String) async {
            let core = Core()
            let location = AgentPluginLocation(pluginID: pluginID, configRoot: nil)
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { _ in core }
            await service.reinstall(location)
            #expect(service.installations[location]?.lastChange == .installed)
            await service.uninstall(location)
            await service.refresh(location)
            #expect(service.installations[location]?.status == .notInstalled)
            #expect(service.installations[location]?.lastChange == .uninstalled)
            await core.configure(.notInstalled, fail: true)
            await service.reinstall(location)
            #expect(service.installations[location]?.lastChange == nil)
            #expect(service.installations[location]?.error != nil)
        }

        @Test("Overlapping checks and clicks do not launch a second operation")
        func serialization() async {
            let core = Core()
            let location = AgentPluginLocation(pluginID: "codex", configRoot: nil)
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { _ in core }
            await core.configure(.installed(version: "1.0.0"), blocked: true)
            let refresh = Task { await service.refresh(location) }
            var iterator = core.checkStarted.stream.makeAsyncIterator()
            _ = await iterator.next()
            await service.refresh(location)
            await service.reinstall(location)
            #expect(service.installations[location]?.isBusy == true)
            #expect(await core.reinstalls == 0)
            await core.unblock()
            await refresh.value
            await service.reinstall(location)
            #expect(await core.reinstalls == 1)
            #expect(service.installations[location]?.isBusy == false)
        }

        @Test("Default and explicit config roots share one operation identity")
        func configRoots() {
            let root = AgentPluginLocation(pluginID: "codex", configRoot: nil, environment: ["CODEX_HOME": "/custom/codex"])
            #expect(root.configRoot == "/custom/codex")
            #expect(root == AgentPluginLocation(pluginID: "codex", configRoot: "/custom/other/../codex"))
            let claude = AgentPluginLocation(pluginID: "claude-code", configRoot: nil, environment: [:], home: URL(fileURLWithPath: "/test"))
            #expect(claude.configRoot == "/test/.claude")
        }

        @Test("Checks and reinstall preserve both Agent and configuration-folder identity")
        func independentTargets() async {
            let codex = Core()
            let claude = Core()
            let service = AgentPluginInstallations(reminders: .inMemory(channel: .plugin)) { id in id == "codex" ? codex : claude }
            let codexDefault = AgentPluginLocation(pluginID: "codex", configRoot: "/isolated/shared")
            let codexOther = AgentPluginLocation(pluginID: "codex", configRoot: "/isolated/other")
            let claudeDefault = AgentPluginLocation(pluginID: "claude-code", configRoot: "/isolated/shared")

            await service.checkAtStartup([codexDefault, codexOther, claudeDefault])
            #expect(await codex.checkedRoots == ["/isolated/shared", "/isolated/other"])
            #expect(await claude.checkedRoots == ["/isolated/shared"])
            service.dismiss(codexDefault)
            #expect(Set(service.updates) == [codexOther, claudeDefault])

            await service.reinstall(codexOther)
            #expect(await codex.reinstalledRoots == ["/isolated/other"])
            #expect(await claude.reinstalledRoots.isEmpty)
            #expect(service.installations[codexOther]?.lastChange == .installed)
            #expect(service.installations[codexDefault]?.lastChange == nil)
            #expect(service.installations[claudeDefault]?.lastChange == nil)
            #expect(service.updates == [claudeDefault])
        }
    }
#endif
