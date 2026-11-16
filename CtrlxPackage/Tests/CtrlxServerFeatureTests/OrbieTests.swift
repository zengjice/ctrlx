import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieTests {
    @Test(arguments: ["codex", "claude-code"])
    func twentyRepliesUseOneAgentAndNeverCreateWorkflows(plugin: String) async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: plugin, providerID: "custom")
        let target = service.record?.target?.agentID
        for i in 0..<20 {
            service.draft = "message \(i)"
            await service.send()
            let message = try #require(service.messages.last)
            #expect(!message.prompt.contains("workflow invocation"))
            #expect(!message.prompt.contains("complete-step"))
            try await f.complete(message, answer: "answer \(i)")
            await service.refresh()
            #expect(service.availability == nil)
            #expect(service.messages.last?.answer == "answer \(i)")
        }
        #expect(service.messages.count == 20 && f.writes.count == 20 && f.launches.count == 1)
        #expect(service.record?.target?.agentID == target)
        #expect(!FileManager.default.fileExists(atPath: f.paths.stateRoot.appendingPathComponent("Workflows").path))
        let reopened = await f.orbie()
        #expect(reopened.messages.count == 20 && reopened.record?.target == service.record?.target)
        try await f.cleanup()
    }

    @Test
    func lostCreationReplyDoesNotCreateAnotherTab() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        f.lostCreateReply = true
        await #expect(throws: AgentWorkflowError.self) { try await service.create(pluginID: "codex", providerID: nil) }
        await service.refresh()
        #expect(service.instance != nil && f.launches.count == 1)
        await #expect(throws: AgentWorkflowError.self) { try await service.create(pluginID: "codex", providerID: nil) }
        try await f.cleanup()
    }

    @Test(arguments: [AgentWorkflowReadiness.draft, .busy, .awaitingHuman, .unavailable])
    func humanInputAndTemporaryModesPreservePanelDraft(readiness: AgentWorkflowReadiness) async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        f.observations[0].readiness = readiness
        f.observations[0].inputIssue = "Exit copy mode."
        service.draft = "keep me"
        await service.send()
        #expect(f.writes.isEmpty && service.draft == "keep me")
        #expect(service.instance?.capabilityIssue == nil)
        try await f.cleanup()
    }

    @Test
    func uncertainWriteIsNotReplayedAndNewDraftSurvives() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        f.lostWriteReply = true
        service.draft = "old"
        f.beforeWrite = { service.draft = "new" }
        await service.send()
        #expect(service.messages.last?.status == .uncertain && service.draft == "new")
        await service.saveDraft()
        let reopened = await f.orbie()
        await reopened.send()
        #expect(reopened.draft == "new" && f.writes.count == 1)
        try await f.cleanup()
    }

    @Test
    func corruptWorkflowLedgerDoesNotAffectOrdinaryMessages() async throws {
        let f = try await AgentInteractionTestSupport()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("ledger.json")
        try Data("broken".utf8).write(to: file)
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        service.draft = "hello"
        await service.send()
        #expect(f.writes.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
        try await f.cleanup()
    }

    @Test
    func newRuntimeRetainsRoleButDoesNotAdoptOldReply() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        let agentID = service.instance?.agentID
        f.observations[0].processRuntimeID = "501:100:200:0"
        f.observations[0].conversationID = UUID().uuidString
        f.observations[0].workspacePane = .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: f.observations[0].workspacePane.paneID)
        await service.refresh()
        #expect(service.instance?.agentID == agentID)
        #expect(service.instance?.processRuntimeID == "501:100:200:0")
        try await f.cleanup()
    }

    @Test
    func explicitHandoffOnlyStagesSelectedText() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        service.draft = "existing"
        try await service.stageReport("selected reply")
        #expect(service.draft == "existing\n\nselected reply" && f.writes.isEmpty)
        try await f.cleanup()
    }
}
