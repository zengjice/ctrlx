import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieConversationTests {
    @Test
    func displayAnswerRemovesCandidatesWithoutChangingMarkdownIndentation() {
        let agent = "\(UUID())/\(UUID())", workflow = UUID()
        let markdown = "    <div>HTML code example</div>\n\n```html\n<button>Interactive</button>\n```\n"
        #expect(OrbieAgentCatalog.displayAnswer(markdown) == markdown)
        let withCandidates = markdown + "[CtrlX Agent: \(agent)]\n[CtrlX Workflow: \(workflow)]"
        #expect(OrbieAgentCatalog.displayAnswer(withCandidates) == markdown + "\n")
        #expect(OrbieAgentCatalog.candidates(in: withCandidates) == [agent])
        #expect(OrbieAgentCatalog.workflowCandidates(in: withCandidates) == [workflow])
    }

    @Test
    func newFilesTabRoutesToSourceOwnerWithIdentityAndCompleteRequest() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            var pane = PaneState(paneId: "%51", currentPath: "/repo", agentSession: .init(paneId: "%51", pluginID: "codex"))
            pane.tmuxWindowId = "@51"
            pane.workspaceIdentity = .init(serverID: "isolated", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            pane.claudeSessionID = "original"
            pane.agentSession?.detectedProjectPath = "/repo"
            coordinator.windowManager.setPaneStatesForPreview([pane])
            let context = try #require(RepositoryFileContext(pane: pane))
            let link = TerminalFileLinkRequest(path: "docs/report.md", paneID: pane.paneId, hostID: nil, prefersPreview: false, opensNewTab: true)
            #expect(try coordinator.queueOrbieFileTab(link, context: context, pane: pane) == nil)
            let request = try #require(coordinator.detachedWindows.mainRequest)
            #expect(request.target.windowID == "@51" && request.target.hostID == nil)
            #expect(try request.action == .fileLink(link, context: context, workspacePane: #require(pane.workspaceIdentity)))
            let target = request.target
            coordinator.detachedWindows.reserve(target)
            let owner = coordinator.detachedWindows.owner(hostID: nil, windowID: "@51")
            #expect(try coordinator.queueOrbieFileTab(link, context: context, pane: pane) == owner && owner != nil)
            var replaced = pane
            replaced.workspaceIdentity = .init(serverID: "other", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            coordinator.windowManager.setPaneStatesForPreview([replaced])
            #expect(throws: AgentWorkflowError.self) { try coordinator.queueOrbieFileTab(link, context: context, pane: pane) }
        }
    }

    @Test
    func fileContextUsesVerifiedConversationAcrossResumeAndRejectsReplacement() async throws {
        let fixture = try await AgentInteractionTestSupport()
        let service = await fixture.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        let saved = try #require(service.instance)
        var resumed = saved
        resumed.workspacePane = .init(serverID: "resumed", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        resumed.paneID = "%202"
        var pane = PaneState(paneId: resumed.paneID, currentPath: resumed.workingDirectory, agentSession: .init(paneId: resumed.paneID, pluginID: resumed.pluginID))
        pane.workspaceIdentity = resumed.workspacePane
        pane.claudeSessionID = resumed.conversationID
        pane.agentSession?.detectedProjectPath = resumed.workingDirectory
        #expect(try OrbieConversationView.fileContext(saved: saved, current: resumed, pane: pane).projectDirectory == saved.workingDirectory)
        var replaced = resumed
        replaced.conversationID = "another-conversation"
        #expect(throws: AgentWorkflowError.self) { try OrbieConversationView.fileContext(saved: saved, current: replaced, pane: pane) }
        replaced = resumed
        replaced.workingDirectory = "/another/worktree"
        #expect(throws: AgentWorkflowError.self) { try OrbieConversationView.fileContext(saved: saved, current: replaced, pane: pane) }
        replaced = AgentWorkflowInstance(
            hostID: UUID(), pluginID: resumed.pluginID, processID: resumed.processID,
            processRuntimeID: resumed.processRuntimeID, workspacePane: resumed.workspacePane,
            paneID: resumed.paneID, conversationID: resumed.conversationID,
            displayName: resumed.displayName, workingDirectory: resumed.workingDirectory,
            capabilities: resumed.capabilities, readiness: resumed.readiness
        )
        #expect(throws: AgentWorkflowError.self) { try OrbieConversationView.fileContext(saved: saved, current: replaced, pane: pane) }
        pane.workspaceIdentity = saved.workspacePane
        #expect(throws: AgentWorkflowError.self) { try OrbieConversationView.fileContext(saved: saved, current: resumed, pane: pane) }
        try await fixture.cleanup()
    }
}
