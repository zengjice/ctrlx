import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieTests {
    @MainActor
    final private class Backend {
        var observations: [AgentWorkflowObservation] = []
        var launches: [OrbieRecord.Creation] = []
        var schedules: [UUID] = []
        var loseCreationReply = false
        var beforeScan: (() -> Void)?
        var beforeLaunch: (() async -> Void)?
        var beforeSchedule: (() -> Void)?
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let paths: CtrlxPaths
        let hostID: UUID
        let pane: WorkspacePaneIdentity
        let storage: OrbieStore
        let ledger: AgentWorkflowStore
        let workflows: AgentWorkflowService
        let backend: Backend
        let service: OrbieService

        func freshService() -> OrbieService {
            OrbieService(store: OrbieStore(paths: paths, hostID: hostID), workflows: workflows) { _ in
                Issue.record("Reopening Orbie must not launch an Agent")
                return pane
            } locateCreation: { id in backend.launches.contains { $0.id == id } ? pane : nil }
        }
    }

    private func fixture(plugin: String = "codex", emptyConversation: Bool = false, queryCommand: String? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-\(UUID())")
        let paths = CtrlxPaths(stateRootOverride: root.appendingPathComponent("state"))
        let hostID = UUID()
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let storage = OrbieStore(paths: paths, hostID: hostID)
        let ledger = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let backend = Backend()
        let workflows = AgentWorkflowService(store: ledger, scan: { _ in
            await MainActor.run {
                backend.beforeScan?()
                return backend.observations
            }
        }, schedule: { id in await MainActor.run {
            backend.schedules.append(id)
            backend.beforeSchedule?()
        } })
        let service = OrbieService(store: storage, workflows: workflows, taskQueryCommand: queryCommand) { intent in
            backend.launches.append(intent)
            await backend.beforeLaunch?()
            backend.observations = [.init(
                pluginID: plugin, processID: 100, processRuntimeID: "start-1", workspacePane: pane,
                paneID: "%1", conversationID: emptyConversation ? "" : "conversation-1", displayName: "Orbie",
                workingDirectory: intent.directory, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
            )]
            if backend.loseCreationReply {
                throw AgentWorkflowError("Lost creation reply")
            }
            return pane
        } locateCreation: { id in backend.launches.contains { $0.id == id } ? pane : nil }
        await service.refresh()
        return Fixture(root: root, paths: paths, hostID: hostID, pane: pane, storage: storage, ledger: ledger, workflows: workflows, backend: backend, service: service)
    }

    @Test(arguments: ["codex", "claude-code"])
    func opensOneAgentAndReusesBindingAcrossAppRestart(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: plugin, providerID: "custom")
        #expect(f.backend.launches.count == 1)
        #expect(f.backend.launches[0].providerID == "custom")
        #expect(f.backend.launches[0].directory == f.paths.orbieDirectory.path)
        #expect(f.service.availability == nil)
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: plugin, providerID: nil) }
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.record?.binding == f.service.record?.binding)
        #expect(f.backend.launches.count == 1)
        #expect(f.backend.schedules.isEmpty)
        #expect(f.paths.orbieBinding.path.hasPrefix(f.root.path))
    }

    @Test
    func transientInputHintIsShownWithoutRevokingCapability() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.backend.observations[0].readiness = .unavailable
        f.backend.observations[0].inputIssue = "Exit tmux copy mode."
        await f.service.refresh()
        #expect(f.service.availability == "Exit tmux copy mode.")
        #expect(f.service.instance?.capabilityIssue == nil)
        #expect(f.service.instance?.capabilities != nil)
        f.backend.observations[0].readiness = .ready
        f.backend.observations[0].inputIssue = nil
        await f.service.refresh()
        #expect(f.service.availability == nil)
        #expect(f.backend.schedules.isEmpty)
    }

    @Test
    func taskLookupInstructionsUseTheExistingWorkflowAndKeepTheOriginalMessage() async throws {
        let f = try await fixture(queryCommand: "'/private/fixture/CtrlXCLI'")
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.service.draft = "继续昨天那个音频问题"
        await f.service.send()
        let run = try #require(try await f.ledger.snapshot().runs.first)
        #expect(run.definition.initialInput.text == "继续昨天那个音频问题")
        #expect(run.definition.nodes.first?.input.text.contains("'/private/fixture/CtrlXCLI' orbie tasks list") == true)
        #expect(run.definition.nodes.first?.input.text.contains("[CtrlX task: UUID]") == true)
        #expect(f.backend.schedules.count == 1)
    }

    @Test(arguments: ["codex", "claude-code"])
    func sendSnapshotsTheMessageBeforePreflightAndPreservesLaterEditing(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: plugin, providerID: nil)
        f.service.draft = "Message A selected for sending"
        f.backend.beforeScan = {
            #expect(f.service.isBusy)
            f.service.draft = "Message B edited during preflight"
            f.backend.beforeScan = nil
        }
        await f.service.send()
        let run = try #require(try await f.ledger.snapshot().runs.first)
        #expect(f.service.issue == nil)
        #expect(run.definition.initialInput.text == "Message A selected for sending")
        #expect(f.service.draft == "Message B edited during preflight")
        #expect(try await f.storage.load().draft == "Message B edited during preflight")
        #expect(f.backend.schedules.count == 1)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.draft == "Message B edited during preflight")
        #expect(f.backend.schedules.count == 1)
    }

    @Test
    func savedDraftSurvivesClosingAndPendingRunReconciliation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.service.draft = "First submitted message"
        await f.service.send()
        let run = try #require(try await f.ledger.snapshot().runs.first)
        var record = try await f.storage.load()
        record.pendingRunID = run.id
        record.draft = "New unsent draft after submission"
        try await f.storage.save(record)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.draft == "New unsent draft after submission")
        #expect(try await f.storage.load().draft == reopened.draft)
        reopened.draft = "Changed while the panel was open"
        await reopened.saveDraft()
        let again = f.freshService()
        await again.refresh()
        #expect(again.draft == "Changed while the panel was open")
        #expect(f.backend.schedules.count == 1)
    }

    @Test
    func lostCreationReplyIsReconciledByTokenWithoutAnotherLaunch() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.backend.loseCreationReply = true
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        #expect(try await f.storage.load().creation != nil)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.record?.binding?.workspacePane == f.pane)
        #expect(f.backend.launches.count == 1)
    }

    @Test
    func concurrentCreationIsRejectedWhileFirstLaunchAwaitsReply() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var release: CheckedContinuation<Void, Never>?
        f.backend.beforeLaunch = { await withCheckedContinuation { release = $0 } }
        let creating = Task { try await f.service.create(pluginID: "codex", providerID: nil) }
        for _ in 0..<1_000 where release == nil {
            await Task.yield()
        }
        let continuation = try #require(release)
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        #expect(f.backend.launches.count == 1)
        continuation.resume()
        try await creating.value
        #expect(f.service.record?.binding != nil)
    }

    @Test
    func lostSubmissionReplyFindsCommittedRunWithoutResending() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        let backup = f.paths.stateRoot.appendingPathComponent("saved-orbie")
        f.backend.beforeSchedule = {
            do {
                try FileManager.default.moveItem(at: f.paths.orbieStateRoot, to: backup)
                try Data("Write blocked".utf8).write(to: f.paths.orbieStateRoot)
            } catch { Issue.record(error) }
        }
        f.service.draft = "Sent but reply interrupted"
        await f.service.send()
        #expect(f.service.issue != nil)
        #expect(f.service.record?.pendingRunID != nil)
        try FileManager.default.removeItem(at: f.paths.orbieStateRoot)
        try FileManager.default.moveItem(at: backup, to: f.paths.orbieStateRoot)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.record?.pendingRunID == nil)
        #expect(reopened.runs.count == 1)
        #expect(reopened.draft.isEmpty)
        #expect(f.backend.schedules.count == 1)
    }

    @Test(arguments: [AgentWorkflowReadiness.busy, .draft, .awaitingHuman, .unavailable])
    func refusesNonemptyOrHumanOwnedInputAndKeepsPanelDraft(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.backend.observations[0].readiness = readiness
        f.service.draft = "Keep this draft"
        await f.service.send()
        #expect(f.service.draft == "Keep this draft")
        #expect(f.service.issue != nil)
        #expect(f.backend.schedules.isEmpty)
        #expect(try await f.ledger.snapshot().runs.isEmpty)
    }

    @Test(arguments: ["pane", "same-name"])
    func anotherTargetCannotInheritOrbie(change: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        switch change {
        case "pane": f.backend.observations[0].workspacePane.paneID = UUID()
        default:
            f.backend.observations[0].workspacePane.windowID = UUID()
            f.backend.observations[0].workspacePane.paneID = UUID()
        }
        f.service.draft = "Never send to replacement"
        await f.service.send()
        #expect(f.service.issue != nil)
        #expect(f.service.draft == "Never send to replacement")
        #expect(f.backend.schedules.isEmpty)
        #expect(try await f.ledger.snapshot().runs.isEmpty)
    }

    @Test(arguments: ["codex", "claude-code"], ["process", "conversation", "recovery", "plugin"])
    func sameTargetAutomaticallyUsesCurrentRuntime(plugin: String, change: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: plugin, providerID: nil)
        let original = try #require(f.service.record?.binding)
        switch change {
        case "process": f.backend.observations[0].processRuntimeID = "new-process"
        case "conversation": f.backend.observations[0].conversationID = "another-conversation"
        case "recovery":
            f.backend.observations[0].processID = 200
            f.backend.observations[0].processRuntimeID = "recovered-process"
            f.backend.observations[0].workspacePane.serverID = "restarted-server"
            f.backend.observations[0].workspacePane.sessionID = UUID()
            f.backend.observations[0].paneID = "%9"
        default:
            f.backend.observations[0].pluginID = plugin == "codex" ? "claude-code" : "codex"
            f.backend.observations[0].processRuntimeID = "switched-agent"
            f.backend.observations[0].conversationID = "switched-conversation"
        }
        f.service.draft = "Keep until explicitly sent"
        await f.service.saveDraft()
        let reopened = f.freshService()
        await reopened.refresh()
        let current = try #require(reopened.instance)
        #expect(current.target == original.target && !current.matchesBinding(original))
        #expect(reopened.record?.binding?.matchesBinding(current) == true)
        #expect(try await f.storage.load().target == original.target)
        #expect(reopened.availability == nil && reopened.draft == "Keep until explicitly sent")
        #expect(f.backend.schedules.isEmpty && f.backend.launches.count == 1)
        await reopened.send()
        let run = try #require(try await f.ledger.snapshot().runs.first)
        #expect(run.instances.first?.matchesBinding(current) == true)
        #expect(reopened.issue == nil && f.backend.schedules == [run.id])
    }

    @Test
    func runtimeRefreshDoesNotReassignAnAcceptedMessage() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.service.draft = "Old request"
        await f.service.send()
        let started = try #require(try await f.ledger.snapshot().runs.first)
        let original = try #require(started.instances.first)
        let accepted = try await f.ledger.update(runID: started.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: started.definition.entryNodeID, now: Date())
            try execution.beginWriting(invocationID: invocation.id, instance: original, now: Date())
            try execution.accept(invocationID: invocation.id, instance: original, nativeTurnID: "old-turn")
        }
        let invocation = try #require(accepted.invocations.first)
        f.backend.observations[0].processRuntimeID = "after-login"
        f.backend.observations[0].conversationID = "new-conversation"
        await f.service.refresh()
        let current = try #require(f.service.instance)
        #expect(f.service.record?.binding?.matchesBinding(current) == true)
        #expect(try await f.ledger.snapshot().runs[0].invocations.first == invocation)
        #expect(f.backend.schedules == [started.id])
        f.service.draft = "Next request"
        await f.service.send()
        #expect(f.service.draft == "Next request" && f.backend.schedules.count == 1)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.ledger.update(runID: started.id) {
                try $0.succeed(.init(invocationID: invocation.id, nativeTurnID: "old-turn", text: "Wrong reply", completedAt: Date()), instance: current, now: Date())
            }
        }
        let oldRun = try #require(f.service.runs.first)
        await f.service.endMessage(oldRun)
        await f.service.send()
        let runs = try await f.ledger.snapshot().runs
        #expect(runs.count == 2 && f.backend.schedules.count == 2)
        #expect(runs[0].invocations.first?.instance?.matchesBinding(original) == true)
        #expect(runs[0].invocations.first?.result == nil)
        #expect(runs[1].instances.first?.matchesBinding(current) == true)
    }

    @Test
    func replacementDuringStartScanIsRejectedAtomically() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        var scans = 0
        f.backend.beforeScan = {
            scans += 1
            if scans == 2 {
                f.backend.observations[0].processRuntimeID = "changed-during-start"
            }
        }
        f.service.draft = "Do not retarget"
        await f.service.send()
        #expect(scans == 2)
        #expect(f.service.issue != nil)
        #expect(f.service.draft == "Do not retarget")
        #expect(f.service.record?.pendingRunID == nil)
        #expect(try await f.ledger.snapshot().runs.isEmpty)
    }

    @Test(arguments: ["codex", "claude-code"])
    func movedPaneKeepsItsVerifiedBindingAndCurrentWindowRoute(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: plugin, providerID: nil)
        let original = try #require(f.service.record?.binding)
        f.backend.observations[0].workspacePane.windowID = UUID()
        f.backend.observations[0].workspacePane.sessionID = UUID()
        let movedPane = f.backend.observations[0].workspacePane

        await f.service.refresh()
        let current = try #require(f.service.instance)
        #expect(original.matchesBinding(current))
        #expect(f.service.availability == nil)
        #expect(f.service.record?.binding?.workspacePane == movedPane)
        #expect(try await f.storage.load().binding?.workspacePane == movedPane)

        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.record?.binding?.target == current.target)
        #expect(reopened.record?.binding?.workspacePane == movedPane)
        reopened.draft = "Continue in the moved Orbie pane"
        await reopened.send()
        #expect(reopened.issue == nil && reopened.draft.isEmpty)
        #expect(try await f.ledger.snapshot().runs.first?.instances.first?.workspacePane == movedPane)
        #expect(f.backend.launches.count == 1 && f.backend.schedules.count == 1)
    }

    @Test
    func movedLivePaneFollowsTheCurrentConversation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        f.backend.observations[0].workspacePane.windowID = UUID()
        f.backend.observations[0].conversationID = "changed-conversation"
        let movedPane = f.backend.observations[0].workspacePane

        await f.service.refresh()
        #expect(f.service.instance?.conversationID == "changed-conversation")
        #expect(f.service.record?.binding?.conversationID == "changed-conversation")
        #expect(f.service.record?.binding?.workspacePane == movedPane)
        #expect(f.service.availability == nil && f.backend.schedules.isEmpty)
        f.service.draft = "Continue in the moved tab"
        await f.service.send()
        #expect(f.service.issue == nil && f.backend.schedules.count == 1)
    }

    @Test(arguments: ["process", "pane", "server", "plugin"])
    func movedReplacementCannotInheritTheOriginalBinding(change: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        let original = try #require(f.service.record?.binding)
        f.backend.observations[0].workspacePane.windowID = UUID()
        switch change {
        case "process": f.backend.observations[0].processRuntimeID = "replacement-process"
        case "pane": f.backend.observations[0].workspacePane.paneID = UUID()
        case "server": f.backend.observations[0].workspacePane.serverID = "replacement-server"
        default: f.backend.observations[0].pluginID = "claude-code"
        }
        f.service.draft = "Do not send to a moved replacement"
        await f.service.send()
        await f.service.refresh()
        #expect(f.service.instance == nil)
        #expect(f.service.record?.binding == original)
        #expect(f.service.draft == "Do not send to a moved replacement")
        #expect(f.backend.schedules.isEmpty)
    }

    @Test
    func anotherWorkflowKeepsItsReservationAndOrbieKeepsItsDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        let instance = try #require(f.service.instance)
        let node = AgentWorkflowNode(name: "Other task", agentInstanceID: instance.id)
        let definition = try await f.workflows.save(.init(
            name: "Other workflow", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id
        ), expectedRevision: nil)
        _ = try await f.workflows.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), authorizationExpiresAt: Date().addingTimeInterval(600))
        f.service.draft = "Keep this Orbie question"
        await f.service.send()
        #expect(f.service.issue != nil)
        #expect(f.service.draft == "Keep this Orbie question")
        #expect(f.service.record?.pendingRunID == nil && f.service.record?.runIDs.isEmpty == true)
        #expect(f.backend.schedules.count == 1)
        #expect(try await f.ledger.snapshot().runs.count == 1)
    }

    @Test(arguments: ["codex", "claude-code"])
    func singleStepReplyAndNextMessageUseExistingLedger(plugin: String) async throws {
        let f = try await fixture(plugin: plugin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: plugin, providerID: "official")
        f.service.draft = "First question"
        await f.service.send()
        let run = try #require(try await f.ledger.snapshot().runs.first)
        #expect(run.definition.nodes.count == 1 && run.roundLimit == 1 && run.instances.count == 1)
        #expect(f.service.draft.isEmpty)
        #expect(f.service.record?.runIDs == [run.id])
        f.service.draft = "Next question"
        await f.service.send()
        #expect(f.service.draft == "Next question")
        #expect(f.backend.schedules.count == 1)
        let current = try #require(run.instances.first)
        _ = try await f.ledger.update(runID: run.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: run.definition.entryNodeID, now: Date())
            try execution.beginWriting(invocationID: invocation.id, instance: current, now: Date())
            try execution.didWrite(invocationID: invocation.id)
            try execution.accept(invocationID: invocation.id, instance: current, nativeTurnID: "native-turn")
            _ = try execution.succeed(.init(invocationID: invocation.id, nativeTurnID: "native-turn", text: "Verified reply", completedAt: Date()), instance: current, now: Date())
        }
        await f.service.refresh()
        #expect(f.service.runs.first?.invocations.first?.result?.text == "Verified reply")
        await f.service.send()
        #expect(f.backend.schedules.count == 2)
        let restarted = f.freshService()
        await restarted.refresh()
        #expect(restarted.runs.count == 2)
        #expect(f.backend.schedules.count == 2)
    }

    @Test
    func firstNativeConversationComesFromWorkflowCatalog() async throws {
        let f = try await fixture(emptyConversation: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        #expect(f.service.record?.binding?.conversationID == "")
        f.backend.observations[0].conversationID = "first-confirmed-conversation"
        await f.service.refresh()
        #expect(f.service.record?.binding?.conversationID == "first-confirmed-conversation")
        f.backend.observations[0].conversationID = "replacement-conversation"
        await f.service.refresh()
        #expect(f.service.record?.binding?.conversationID == "replacement-conversation")
        #expect(f.service.availability == nil)
    }

    @Test
    func persistedUnconfirmedMessageIsNotReplayedOnRestart() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        var record = try await f.storage.load()
        let id = UUID()
        record.draft = "Not confirmed"
        record.pendingRunID = id
        record.runIDs = [id]
        try await f.storage.save(record)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.draft == "Not confirmed")
        await reopened.send()
        #expect(f.backend.schedules.isEmpty)
        await reopened.reviewUnstartedRequest()
        #expect(reopened.record?.pendingRunID == nil)
        #expect(reopened.draft == "Not confirmed")
    }

    @Test
    func disableKeepsAgentBindingFilesAndDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.create(pluginID: "codex", providerID: nil)
        let binding = f.service.record?.binding
        f.service.draft = "Later"
        await f.service.setEnabled(false)
        await f.service.send()
        #expect(f.service.record?.binding == binding)
        #expect(f.service.draft == "Later")
        #expect(FileManager.default.fileExists(atPath: f.paths.orbieDirectory.path))
        #expect(f.backend.schedules.isEmpty)
        await f.service.setEnabled(true)
        #expect(f.service.availability == nil)
    }

    @Test
    func storageFailureNeverLaunchesOrOverwritesInstructions() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.storage.prepareDirectory()
        let instructions = f.paths.orbieDirectory.appendingPathComponent("AGENTS.md")
        try Data("User instructions".utf8).write(to: instructions)
        _ = try await f.storage.prepareDirectory()
        #expect(try String(contentsOf: instructions, encoding: .utf8) == "User instructions")
        try FileManager.default.createDirectory(at: f.paths.stateRoot, withIntermediateDirectories: true)
        try Data("Not a directory".utf8).write(to: f.paths.orbieStateRoot)
        await #expect(throws: (any Error).self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        #expect(f.backend.launches.isEmpty)
    }

    @Test(arguments: ["corrupt", "version", "host"])
    func invalidStorageIsVisibleAndPreserved(kind: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var record = OrbieRecord(hostID: kind == "host" ? UUID() : f.hostID)
        if kind == "version" {
            record.schemaVersion = 99
        }
        let data = kind == "corrupt" ? Data("bad json".utf8) : try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: f.paths.orbieStateRoot, withIntermediateDirectories: true)
        try data.write(to: f.paths.orbieBinding)
        let reopened = f.freshService()
        await reopened.refresh()
        #expect(reopened.record == nil && reopened.issue != nil)
        #expect(try Data(contentsOf: f.paths.orbieBinding) == data)
    }

    @Test
    func creationEvidenceIgnoresNamesAndDeduplicatesLinkedPanes() throws {
        let id = UUID(), pane = WorkspacePaneIdentity(serverID: "123:456", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let line = "\(id)\t\(pane.serverID)\t\(pane.sessionID)\t\(pane.windowID)\t\(pane.paneID)"
        #expect(try OrbieCreationEvidence.locate(id, output: "Orbie\tanything\n\(line)\n\(line)") == pane)
        #expect(try OrbieCreationEvidence.locate(UUID(), output: line) == nil)
        #expect(throws: AgentWorkflowError.self) { try OrbieCreationEvidence.locate(id, output: "\(id)\t123:456\t\t\t") }
        #expect(throws: AgentWorkflowError.self) { try OrbieCreationEvidence.locate(id, output: line + "\n\(id)\t123:456\t\(UUID())\t\(UUID())\t\(UUID())") }
    }
}
