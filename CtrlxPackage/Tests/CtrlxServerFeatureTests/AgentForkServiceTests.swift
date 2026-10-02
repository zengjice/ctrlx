import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import CtrlxPluginProtocol
import Testing
@testable import CtrlxServerFeature

private actor ForkTestCore: AgentSessionForking {
    func commandForFork(sessionID: String, projectPath: String) async throws -> AgentForkLaunch {
        AgentForkLaunch(command: LaunchCommand(command: "codex", args: ["fork", sessionID, "-C", projectPath], env: ["CODEX_HOME": "/config"]))
    }
    func commandForLaunch(projectPath _: String) async -> LaunchCommand? { nil }
    func initialize(_: PluginEnv, host _: any PluginHost) async throws { }
    func handleIngress(_: IngressFrame) async -> PluginEvent? { nil }
    func deliverResponse(sessionID _: String, requestID _: String, _: AgentResponse) async { }
    func refreshProjects() async { }
    func install(configRoot _: String?) async throws -> InstallResult { .alreadyInstalled }
    func uninstall(configRoot _: String?) async throws { }
    func installStatus(configRoot _: String?) async -> PluginInstallStatus { .installed(version: "1") }
    func applySettings(_: Data) async -> SettingsResult { .applied }
    func shutdown() async { }
}

@MainActor
private final class ForkFixture {
    let original: AgentForkSource
    var current: AgentForkSource?
    var launches: [(session: String, name: String, preparation: SessionLaunchPreparation)] = []
    var refreshes = 0

    init() throws {
        original = try #require(AgentForkSource(pane: PaneState(
            paneId: "%1", sessionName: "source", tmuxWindowId: "@7", currentPath: "/repo 'quoted'/src",
            agentSession: .init(paneId: "%1", pluginID: "codex"), claudeSessionID: UUID().uuidString
        )))
        current = original
    }

    func service(failsLaunch: Bool = false) -> AgentForkService {
        let core = ForkTestCore()
        return AgentForkService(
            source: {
                MainActor.preconditionIsolated()
                return $0 == self.current?.paneID ? self.current : nil
            },
            core: { _ in
                MainActor.preconditionIsolated()
                return core
            },
            refresh: {
                MainActor.preconditionIsolated()
                await Task.detached {}.value
                MainActor.preconditionIsolated()
                self.refreshes += 1
            },
            launch: { session, name, preparation in
                MainActor.preconditionIsolated()
                await Task.detached {}.value
                MainActor.preconditionIsolated()
                self.launches.append((session, name, preparation))
                if failsLaunch { throw AgentForkError("Window created (%99), but Agent launch failed. Check that tab before retrying.") }
                return "%99"
            }
        )
    }
}

private actor ForkBackgroundCaller {
    func run(service: AgentForkService, source: AgentForkSource, usingWorktree: Bool) async throws -> String {
        let prepared = try await service.prepare(source)
        return try await service.fork(.init(source: source, worktree: usingWorktree ? .init(name: "new", expectedHead: prepared.worktree?.head ?? "") : nil))
    }
}

@MainActor
struct AgentForkServiceTests {
    @Test("Viewer background requests keep all Host callbacks on MainActor across suspension", arguments: [false, true])
    func callbackIsolation(usingWorktree: Bool) async throws {
        let fixture = try ForkFixture()
        let service = fixture.service()
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[AgentForkWorktreeClient.self].inspect = { path in
                .init(repositoryRoot: path, primaryRoot: path, head: "abc", relativeDirectory: "", hasUncommittedChanges: false)
            }
            $0[AgentForkWorktreeClient.self].create = { _, _ in "/repo/.worktrees/new" }
        } operation: {
            let paneID = try await ForkBackgroundCaller().run(service: service, source: fixture.original, usingWorktree: usingWorktree)
            #expect(paneID == "%99")
            #expect(fixture.refreshes == 3)
            #expect(fixture.launches.count == 1)
        }
    }

    @Test("Concurrent/repeated Viewer retries produce exactly one new pane, without modifying source state")
    func idempotency() async throws {
        let fixture = try ForkFixture()
        let service = fixture.service()
        let request = ForkAgentSession(source: fixture.original, windowName: "我的 Fork")
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
        } operation: {
            async let first = service.fork(request)
            async let second = service.fork(request)
            let pair = try await (first, second)
            #expect(pair.0 == "%99" && pair.1 == "%99")
            #expect(try await service.fork(request) == "%99")
            #expect(fixture.launches.count == 1)
            #expect(fixture.current == fixture.original)
            let (session, name, launch) = try #require(fixture.launches.first)
            #expect(session == "source")
            #expect(name == "我的 Fork")
            #expect(launch.workingDirectory == fixture.original.workingDirectory)
            #expect(launch.runCommand?.contains(fixture.original.sessionID) == true)
            #expect(launch.extraEnvironment.isEmpty)
            #expect(launch.launch?.env["CODEX_HOME"] == "/config")
            #expect(try launch.forkRunCommand(shell: "/bin/zsh")?.contains("export 'CODEX_HOME=/config'") == true)
            let changed = ForkAgentSession(requestID: request.requestID, source: fixture.original, worktree: .init(name: "another", expectedHead: "abc"))
            await #expect(throws: AgentForkError.self) { try await service.fork(changed) }
            let renamed = ForkAgentSession(requestID: request.requestID, source: fixture.original, windowName: "another name")
            await #expect(throws: AgentForkError.self) { try await service.fork(renamed) }
            #expect(fixture.launches.count == 1)
        }
    }

    @Test("Closed/switched source is rejected before directory or tmux mutations")
    func staleSource() async throws {
        let fixture = try ForkFixture()
        fixture.current = nil
        let service = fixture.service()
        await #expect(throws: AgentForkError.self) { try await service.fork(.init(source: fixture.original)) }
        #expect(fixture.launches.isEmpty)
    }

    @Test("Non-Git directories can fork normally, but preparation explains why worktree is unavailable")
    func nonGit() async throws {
        let fixture = try ForkFixture()
        let service = fixture.service()
        try await withDependencies {
            $0[AgentForkWorktreeClient.self].inspect = { _ in throw AgentForkError("Not a Git repository") }
            $0[SessionDirectoryClient.self].resolve = { $0 }
        } operation: {
            let prepared = try await service.prepare(fixture.original)
            #expect(prepared.worktree == nil)
            #expect(prepared.worktreeUnavailableReason == "Not a Git repository")
            #expect(try await service.fork(.init(source: fixture.original)) == "%99")
        }
    }

    @Test("Worktree launch uses the new cwd; source switches after checkout leave a reported worktree, not a wrong Agent")
    func revalidateAfterCheckout() async throws {
        for switchSource in [false, true] {
            let fixture = try ForkFixture()
            let service = fixture.service()
            let path = "/repo/.worktrees/new/src"
            try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { $0 }
                $0[AgentForkWorktreeClient.self].create = { _, _ in
                    if switchSource { await MainActor.run { fixture.current = nil } }
                    return path
                }
            } operation: {
                let request = ForkAgentSession(source: fixture.original, windowName: "new", worktree: .init(name: "new", expectedHead: "abc"))
                if switchSource {
                    do {
                        _ = try await service.fork(request)
                        Issue.record("A switched source must not launch")
                    } catch { #expect(error.localizedDescription.contains(path)) }
                    #expect(fixture.launches.isEmpty)
                } else {
                    let paneID = try await service.fork(request)
                    #expect(paneID == "%99")
                    #expect(fixture.launches.first?.name == "new")
                    #expect(fixture.launches.first?.preparation.workingDirectory == path)
                    #expect(fixture.launches.first?.preparation.launch?.args.suffix(2) == ["-C", path])
                }
            }
        }
    }

    @Test("Invalid or mismatched names are rejected before Host I/O or window creation")
    func invalidNames() async throws {
        let fixture = try ForkFixture()
        let service = fixture.service()
        for name in ["", " \t ", "line\nbreak"] {
            await #expect(throws: AgentForkError.self) {
                try await service.fork(.init(source: fixture.original, windowName: name))
            }
        }
        await #expect(throws: AgentForkError.self) {
            try await service.fork(.init(source: fixture.original, windowName: "other", worktree: .init(name: "new", expectedHead: "abc")))
        }
        #expect(fixture.refreshes == 0)
        #expect(fixture.launches.isEmpty)
    }

    @Test("Worktree conflicts create no pane; a corrected name and fresh request can succeed")
    func nameConflictRetry() async throws {
        let fixture = try ForkFixture()
        let service = fixture.service()
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[AgentForkWorktreeClient.self].create = { _, request in
                if request.name == "existing" { throw AgentForkError("Branch already exists: existing. Choose a different name.") }
                return "/repo/.worktrees/\(request.name)/src"
            }
        } operation: {
            let request = ForkAgentSession(source: fixture.original, windowName: "existing", worktree: .init(name: "existing", expectedHead: "abc"))
            for _ in 0..<2 {
                await #expect(throws: AgentForkError.self) { try await service.fork(request) }
            }
            #expect(fixture.launches.isEmpty)
            let corrected = ForkAgentSession(source: fixture.original, windowName: "available", worktree: .init(name: "available", expectedHead: "abc"))
            let paneID = try await service.fork(corrected)
            #expect(paneID == "%99")
            #expect(fixture.launches.count == 1)
            #expect(fixture.launches.first?.name == "available")
            #expect(fixture.launches.first?.preparation.workingDirectory == "/repo/.worktrees/available/src")
        }
    }

    @Test("A partial tmux launch failure is cached too, so retry never creates another pane")
    func partialLaunchFailure() async throws {
        let fixture = try ForkFixture()
        let service = fixture.service(failsLaunch: true)
        let request = ForkAgentSession(source: fixture.original)
        await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
        } operation: {
            for _ in 0..<2 {
                await #expect(throws: AgentForkError.self) { try await service.fork(request) }
            }
            #expect(fixture.launches.count == 1)
        }
    }
}
