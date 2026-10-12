import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

private actor ForkPanelBackgroundCaller {
    func run(configuration: AgentForkConfiguration, source: AgentForkSource) async throws {
        _ = try await configuration.prepare(source)
        try await configuration.fork(.init(source: source))
    }
}

@MainActor
struct AgentForkConfigurationTests {
    @Test("Shared Mac/iOS panel callbacks retain MainActor isolation across suspension")
    func callbackIsolation() async throws {
        let source = try #require(AgentForkSource(pane: pane("%1", index: 1)))
        var calls = 0
        let config = AgentForkConfiguration(sources: [source], usingWorktree: true, prepare: { source in
            MainActor.preconditionIsolated()
            await Task.detached {}.value
            MainActor.preconditionIsolated()
            calls += 1
            return .init(source: source, worktree: nil)
        }, fork: { _ in
            MainActor.preconditionIsolated()
            await Task.detached {}.value
            MainActor.preconditionIsolated()
            calls += 1
        })
        try await ForkPanelBackgroundCaller().run(configuration: config, source: source)
        #expect(calls == 2)
    }

    private func pane(_ id: String, index: Int, agent: String = "codex", active: Bool = false) -> PaneState {
        PaneState(
            paneId: id, sessionName: "work", tmuxWindowId: "@4", paneIndex: index, currentPath: "/Host/repo", isActive: active,
            agentSession: .init(paneId: id, pluginID: agent), claudeSessionID: UUID().uuidString
        )
    }

    private func configuration(sources: [AgentForkSource], usingWorktree: Bool) -> AgentForkConfiguration {
        AgentForkConfiguration(sources: sources, usingWorktree: usingWorktree, prepare: { _ in
            Issue.record("Validating a draft must not send a preparation request")
            throw CancellationError()
        }, fork: { _ in Issue.record("Validating a draft must not create a window") })
    }

    @Test("Mac/iOS source choice prefers the controlled pane, then Host active pane, then pane order")
    func sources() {
        let panes = [pane("%3", index: 3), pane("%2", index: 2, agent: "claude-code"), pane("%1", index: 1, active: true)]
        #expect(AgentForkConfiguration.orderedSources(panes: panes, focusedPaneID: "%2").map(\.paneID) == ["%2", "%1", "%3"])
        #expect(AgentForkConfiguration.orderedSources(panes: panes, focusedPaneID: nil).map(\.paneID) == ["%1", "%2", "%3"])
        #expect(AgentForkConfiguration.orderedSources(panes: panes, focusedPaneID: "%removed").map(\.paneID) == ["%1", "%2", "%3"])
    }

    @Test("A focused shell, unknown Agent or missing native UUID cannot become the Fork source")
    func unrecognizedSources() {
        let valid = pane("%1", index: 1, agent: "claude-code")
        var shell = pane("%2", index: 2)
        shell.agentSession = nil
        var unidentified = pane("%3", index: 3)
        unidentified.claudeSessionID = nil
        let sources = AgentForkConfiguration.orderedSources(panes: [shell, unidentified, pane("%4", index: 4, agent: "pi"), valid], focusedPaneID: "%2")
        #expect(sources.map(\.paneID) == ["%1"])
    }

    @Test("Current-directory Fork needs no Git preparation or dirty-file approval")
    func currentDirectory() throws {
        let source = try #require(AgentForkSource(pane: pane("%1", index: 1)))
        let config = configuration(sources: [source], usingWorktree: false)
        #expect(try config.worktreeRequest(source: source, preparation: nil, name: "", allowUncommittedChanges: false) == nil)
    }

    @Test("Mac/iOS current-directory Fork uses the entered window name without needing Git", arguments: ["codex", "claude-code"])
    func currentDirectoryName(agent: String) throws {
        let source = try #require(AgentForkSource(pane: pane("%1", index: 1, agent: agent)))
        let config = configuration(sources: [source], usingWorktree: false)
        let request = try config.forkRequest(source: source, preparation: nil, name: "  我的 Fork  ", allowUncommittedChanges: false)
        #expect(request.windowName == "我的 Fork")
        #expect(request.worktree == nil)
        #expect(request.source.pluginID == agent)
        for name in ["", "  ", "line\nbreak"] {
            #expect(throws: AgentForkError.self) {
                try config.forkRequest(source: source, preparation: nil, name: name, allowUncommittedChanges: false)
            }
        }
    }

    @Test("Mac/iOS worktree drafts share one name; correcting a conflict gets a fresh retry identity", arguments: ["codex", "claude-code"])
    func namedWorktree(agent: String) throws {
        let source = try #require(AgentForkSource(pane: pane("%1", index: 1, agent: agent)))
        let config = configuration(sources: [source], usingWorktree: true)
        let preparation = AgentForkPreparation(source: source, worktree: .init(
            repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "source-head", relativeDirectory: "", hasUncommittedChanges: false
        ))
        let first = try config.forkRequest(source: source, preparation: preparation, name: "  feature  ", allowUncommittedChanges: false)
        #expect(first.windowName == "feature")
        #expect(first.worktree?.name == "feature")
        #expect(first.source.pluginID == agent)
        #expect(preparation.worktree?.directory(name: try #require(first.windowName)) == "/Host/repo/.worktrees/feature")
        let corrected = try config.forkRequest(source: source, preparation: preparation, name: "feature-2", allowUncommittedChanges: false)
        #expect(corrected.requestID != first.requestID)
        #expect(corrected.windowName == corrected.worktree?.name)
    }

    @Test("Worktree review preserves the selected source HEAD and requires dirty-file acknowledgement", arguments: [false, true])
    func worktree(hasChanges: Bool) throws {
        let source = try #require(AgentForkSource(pane: pane("%1", index: 1)))
        let config = configuration(sources: [source], usingWorktree: true)
        let preparation = AgentForkPreparation(source: source, worktree: .init(
            repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "source-head", relativeDirectory: "src", hasUncommittedChanges: hasChanges
        ))
        if hasChanges {
            #expect(throws: AgentForkError.self) { try config.worktreeRequest(source: source, preparation: preparation, name: "new", allowUncommittedChanges: false) }
        }
        let request = try #require(try config.worktreeRequest(source: source, preparation: preparation, name: "new", allowUncommittedChanges: hasChanges))
        #expect(request == .init(name: "new", expectedHead: "source-head", allowUncommittedChanges: hasChanges))
        #expect(throws: AgentForkError.self) { try config.worktreeRequest(source: source, preparation: preparation, name: "../escape", allowUncommittedChanges: true) }
    }

    @Test("Switching source requires its own preparation; failed checks never downgrade to current-directory Fork")
    func mismatchedPreparation() throws {
        let codex = try #require(AgentForkSource(pane: pane("%1", index: 1)))
        let claude = try #require(AgentForkSource(pane: pane("%2", index: 2, agent: "claude-code")))
        let config = configuration(sources: [codex, claude], usingWorktree: true)
        let wrongSource = AgentForkPreparation(source: codex, worktree: .init(
            repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "codex-head", relativeDirectory: "", hasUncommittedChanges: false
        ))
        let preparations: [AgentForkPreparation?] = [nil, wrongSource, .init(source: claude, worktree: nil, worktreeUnavailableReason: "Not a Git repository")]
        for preparation in preparations {
            #expect(throws: AgentForkError.self) {
                try config.worktreeRequest(source: claude, preparation: preparation, name: "new", allowUncommittedChanges: true)
            }
        }
        let differentWindow = try #require(AgentForkSource(pane: pane("%9", index: 9)))
        #expect(throws: AgentForkError.self) {
            try configuration(sources: [codex], usingWorktree: false).worktreeRequest(source: differentWindow, preparation: nil, name: "", allowUncommittedChanges: false)
        }
    }

    @Test("Fork capability is per Host and rechecked for offline, legacy and downgraded peers")
    func hostAvailability() {
        let store = SessionStore()
        store.handleStateUpdate(SessionStateMessage(pairId: "office", paneStates: [:], supportsAgentFork: true))
        #expect(store.agentForkUnavailableReason(hostID: "office", isConnected: true) == nil)
        #expect(store.agentForkUnavailableReason(hostID: "office", isConnected: false)?.contains("offline") == true)
        #expect(store.agentForkUnavailableReason(hostID: "home", isConnected: true)?.contains("Update") == true)
        store.handleStateUpdate(SessionStateMessage(pairId: "office", paneStates: [:]))
        #expect(store.agentForkUnavailableReason(hostID: "office", isConnected: true) != nil)
        store.handleStateUpdate(SessionStateMessage(pairId: "office", paneStates: [:], supportsAgentFork: true))
        store.clearSessions(for: "office")
        #expect(store.agentForkUnavailableReason(hostID: "office", isConnected: true) != nil)
    }
}
