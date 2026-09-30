import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentForkConfigurationTests {
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
