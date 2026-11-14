import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbiterTests {
    @MainActor
    final private class Backend {
        var observations: [AgentWorkflowObservation] = []
        var launches: [OrbiterTask] = []
        var schedules: [UUID] = []
        var lostReply = false
        var replaceCreationServer = false
        var enabled = true
        var forkReady = true
        var beforeLaunch: (() async -> Void)?
        var beforeScan: (@Sendable () async -> Void)?
        var beforeSchedule: (() -> Void)?
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let paths: CtrlxPaths
        let hostID: UUID
        let store: OrbiterStore
        let ledger: AgentWorkflowStore
        let workflows: AgentWorkflowService
        let backend: Backend
        let source: AgentWorkflowInstance
        let service: OrbiterService

        func reopened() -> OrbiterService {
            OrbiterService(store: store, workflows: workflows, enabled: { backend.enabled }, forkSource: { source }, launch: { _ in
                Issue.record("Reopening must not launch an Agent")
                throw CancellationError()
            }, locateCreation: { id in
                guard !backend.replaceCreationServer else { return nil }
                return backend.observations.first { $0.workspacePane.paneID == id }?.workspacePane
            })
        }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbiter-\(UUID())")
        let paths = CtrlxPaths(stateRootOverride: root.appendingPathComponent("state"))
        let hostID = UUID()
        let backend = Backend()
        let ledger = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let workflows = AgentWorkflowService(store: ledger, scan: { _ in
            let beforeScan = await MainActor.run { backend.beforeScan }
            await beforeScan?()
            return await MainActor.run { backend.observations }
        }, schedule: { id in await MainActor.run {
            backend.schedules.append(id)
            backend.beforeSchedule?()
        } })
        let store = OrbiterStore(paths: paths, hostID: hostID)
        let source = AgentWorkflowInstance(hostID: hostID, pluginID: "codex", processID: 9, processRuntimeID: "orbie-start", workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%9", conversationID: UUID().uuidString, displayName: "Orbie", workingDirectory: root.path, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)
        let service = OrbiterService(store: store, workflows: workflows, enabled: { backend.enabled }, forkSource: {
            guard backend.forkReady else { throw AgentWorkflowError("Orbie busy") }
            return source
        }, launch: { task in
            backend.launches.append(task)
            await backend.beforeLaunch?()
            let pane = WorkspacePaneIdentity(serverID: backend.replaceCreationServer ? "replacement-server" : "server", sessionID: UUID(), windowID: UUID(), paneID: task.id)
            backend.observations.append(.init(pluginID: task.pluginID, processID: Int32(100 + backend.launches.count), processRuntimeID: task.id.uuidString, workspacePane: pane, paneID: "%\(100 + backend.launches.count)", conversationID: UUID().uuidString, displayName: task.title, workingDirectory: task.directory, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready))
            if backend.lostReply {
                throw AgentWorkflowError("Reply lost")
            }
            let created = AgentWorkflowCreatedAgent(paneID: "%\(100 + backend.launches.count)", scope: .init(hostID: hostID, serverID: task.forkSource?.workspacePane.serverID ?? "server"), pluginID: task.pluginID)
            return try AppCoordinator.orbiterCreatedPane(created, panes: [.init(
                paneId: created.paneID, target: "task:0.0", sessionName: "task", windowIndex: 0,
                paneIndex: 0, command: task.pluginID, currentPath: task.directory, width: 120, height: 40,
                isActive: true, workspaceIdentity: pane
            )])
        }, locateCreation: { id in
            guard !backend.replaceCreationServer else { return nil }
            return backend.observations.first { $0.workspacePane.paneID == id }?.workspacePane
        })
        await service.refresh()
        service.draft = .init(title: "Audio", goal: "Check the selected audio issue", source: "User supplied source", materials: "Only this selected excerpt", directory: root.path)
        return .init(root: root, paths: paths, hostID: hostID, store: store, ledger: ledger, workflows: workflows, backend: backend, source: source, service: service)
    }

    @Test
    func navigationRereadsTaskAssociationAndNeverUsesTheCachedDeletedTask() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.service.create(pluginID: "codex", providerID: nil)
        let task = try #require(f.service.tasks.first)
        #expect(try await f.service.taskForNavigation(task.id).id == task.id)
        var index = try await f.store.load()
        index.tasks.removeAll()
        try await f.store.save(index)
        #expect(f.service.tasks.contains { $0.id == task.id })
        await #expect(throws: AgentWorkflowError.self) { try await f.service.taskForNavigation(task.id) }
    }

    private func complete(_ f: Fixture, runID: UUID, text: String) async throws {
        let run = try #require(try await f.ledger.snapshot().runs.first { $0.id == runID })
        let instance = try #require(run.instances.first)
        _ = try await f.ledger.update(runID: run.id) { execution in
            let invocation = try execution.prepareInvocation(nodeID: run.definition.entryNodeID, now: Date())
            try execution.beginWriting(invocationID: invocation.id, instance: instance, now: Date())
            try execution.didWrite(invocationID: invocation.id)
            try execution.accept(invocationID: invocation.id, instance: instance, nativeTurnID: "turn-\(run.id)")
            _ = try execution.succeed(.init(invocationID: invocation.id, nativeTurnID: "turn-\(run.id)", text: text, completedAt: Date()), instance: instance, now: Date())
        }
    }

    @Test(arguments: ["codex", "claude-code"])
    func newUsesOnlySelectedContextAndProviderAndKeepsRealProject(plugin: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: plugin, providerID: "custom")
        let task = try #require(f.service.tasks.first)
        let run = try #require(f.service.runs.first)
        #expect(task.id == id && task.pluginID == plugin && task.providerID == "custom")
        #expect(task.directory == f.root.path && task.directory != f.service.materialDirectory(task).path)
        #expect(task.forkSource == nil && task.origin == .newAgent)
        #expect(run.definition.initialInput.text.contains("Only this selected excerpt"))
        #expect(!run.definition.initialInput.text.contains(f.source.conversationID))
        #expect(f.backend.launches.count == 1 && f.backend.schedules.count == 1)
        #expect(f.service.taskDrafts[id] == "")
        #expect(try String(contentsOf: f.paths.orbiterDirectory(id).appendingPathComponent("TASK.md"), encoding: .utf8).contains(f.root.path))
    }

    @Test
    func forkRequiresReadySameAgentNativeConversationAndKeepsProvenance() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.backend.forkReady = false
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil, fork: true) }
        f.backend.forkReady = true
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "claude-code", providerID: nil, fork: true) }
        #expect(f.backend.launches.isEmpty)
        _ = try await f.service.create(pluginID: "codex", providerID: "other", fork: true)
        #expect(f.service.tasks.first?.forkSource?.matchesBinding(f.source) == true)
        #expect(f.backend.launches.first?.providerID == "other")
    }

    @Test
    func duplicateClickAndLostCreateReceiptNeverLaunchAgain() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var release: CheckedContinuation<Void, Never>?
        f.backend.beforeLaunch = { await withCheckedContinuation { release = $0 } }
        f.backend.lostReply = true
        let creating = Task { try await f.service.create(pluginID: "codex", providerID: nil) }
        for _ in 0..<1_000 where release == nil {
            await Task.yield()
        }
        let continuation = try #require(release)
        #expect(f.service.isOperating)
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        continuation.resume()
        await #expect(throws: AgentWorkflowError.self) { try await creating.value }
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(reopened.tasks.count == 1 && reopened.tasks.first?.binding != nil)
        #expect(f.backend.launches.count == 1 && f.backend.schedules.isEmpty)
        await #expect(throws: AgentWorkflowError.self) { try await reopened.create(pluginID: "codex", providerID: nil) }
        #expect(f.backend.launches.count == 1)
    }

    @Test
    func twoActiveLimitKeepsThirdDraftWithoutQueueAndSameNamesStayDistinct() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = f.service.draft
        _ = try await f.service.create(pluginID: "codex", providerID: nil)
        f.service.draft = draft
        f.service.draft.id = UUID()
        _ = try await f.service.create(pluginID: "codex", providerID: nil)
        #expect(f.service.tasks.map(\.title) == ["Audio", "Audio 2"])
        #expect(f.service.tasks[0].binding?.workspacePane.paneID != f.service.tasks[1].binding?.workspacePane.paneID)
        f.service.draft = draft
        f.service.draft.id = UUID()
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        await f.service.saveDrafts()
        #expect(try await f.store.load().draft.goal == draft.goal)
        #expect(f.backend.launches.count == 2 && f.backend.schedules.count == 2)
        let run = try #require(f.service.runs.first)
        try await f.service.end(run)
        #expect(f.backend.launches.count == 2)
    }

    @Test
    func reportsPersistOffscreenFollowupsKeepDirectoryAndReferencedRunsCannotBeDeleted() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.service.startObserving()
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        let task = try #require(f.service.tasks.first)
        let run = try #require(f.service.runs.first)
        let reportURL = f.paths.orbiterDirectory(id).appendingPathComponent("RESULT.md")
        #expect(!FileManager.default.fileExists(atPath: reportURL.path))
        try await complete(f, runID: run.id, text: "Summary: partial\nEvidence: checked\nArtifacts: /project/report.txt\nNext steps: continue")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: reportURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(report.contains("Agent report") && report.contains("Next steps: continue"))
        #expect(report.contains(run.id.uuidString))
        let completed = try #require(try await f.ledger.snapshot().runs.first)
        await #expect(throws: AgentWorkflowError.self) { try await f.workflows.deleteRun(id: completed.id, expectedRevision: completed.revision) }
        try await f.ledger.deleteDefinition(id: completed.definition.id, expectedRevision: completed.definition.revision)
        let reloadedLedger = AgentWorkflowStore(fileURL: f.root.appendingPathComponent("ledger.json"), hostID: f.hostID)
        #expect(try await reloadedLedger.snapshot().runs.first?.invocations.first?.result?.text.contains("Next steps") == true)
        await #expect(throws: AgentWorkflowError.self) { try await reloadedLedger.deleteRun(id: completed.id, expectedRevision: completed.revision) }
        f.service.taskDrafts[id] = "Continue the unfinished checks"
        await f.service.saveDrafts()
        // Wait for any ledger-triggered refresh before the explicit action.
        while f.service.isBusy {
            await Task.yield()
        }
        try await f.service.send(id)
        #expect(f.service.tasks.first?.runIDs.count == 2)
        #expect(f.service.materialDirectory(task) == f.paths.orbiterDirectory(id))
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(reopened.tasks.first?.runIDs.count == 2)
        #expect(f.backend.schedules.count == 2)
        await f.service.shutdown()
    }

    @Test
    func anotherWorkflowReservationAndReplacedConversationRejectWithoutLosingDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        let original = try #require(f.service.runs.first)
        try await f.service.end(original)
        let instance = try #require(f.service.tasks.first?.binding)
        let node = AgentWorkflowNode(name: "Other", agentInstanceID: instance.id)
        let definition = try await f.workflows.save(.init(name: "Other workflow", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Other")), expectedRevision: nil)
        _ = try await f.workflows.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), authorizationExpiresAt: Date().addingTimeInterval(600))
        f.service.taskDrafts[id] = "Keep this follow-up"
        await #expect(throws: AgentWorkflowStartRejection.self) { try await f.service.send(id) }
        #expect(f.service.taskDrafts[id] == "Keep this follow-up")
        #expect(f.service.tasks.first?.pendingRunID == nil)
        f.backend.observations[0].conversationID = UUID().uuidString
        await #expect(throws: AgentWorkflowStartRejection.self) { try await f.service.send(id) }
        #expect(f.backend.schedules.count == 2)
    }

    @Test
    func moveAndRuntimeChangeKeepTaskAssociation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        let run = try #require(f.service.runs.first)
        try await f.service.end(run)
        let old = f.backend.observations[0].workspacePane
        let moved = WorkspacePaneIdentity(serverID: old.serverID, sessionID: UUID(), windowID: UUID(), paneID: old.paneID)
        f.backend.observations[0].workspacePane = moved
        await f.service.refresh()
        #expect(f.service.tasks.first?.binding?.workspacePane == moved)
        f.backend.observations[0].processRuntimeID = "replacement"
        await f.service.refresh()
        let task = try #require(f.service.tasks.first)
        #expect(f.service.availability(task) == nil)
        #expect(f.service.tasks.first?.binding?.processRuntimeID == "replacement")
        f.backend.observations[0].workspacePane.serverID = "recovered-server"
        f.backend.observations[0].workspacePane.windowID = UUID()
        f.backend.observations[0].paneID = "%99"
        f.backend.observations[0].processID = 999
        f.backend.observations[0].conversationID = UUID().uuidString
        await f.service.refresh()
        let recovered = try #require(f.service.tasks.first)
        #expect(f.service.currentInstance(recovered)?.paneID == "%99")
        #expect(f.service.availability(recovered) == nil)
        #expect(recovered.runIDs == task.runIDs)
        #expect(recovered.binding?.agentID == task.binding?.agentID)
        #expect(f.backend.schedules.count == 1)
    }

    @Test
    func diskFailureStopsLaunchAndCorruptIndexIsPreserved() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.paths.orbieStateRoot, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: f.paths.orbiterIndex)
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(reopened.index == nil && reopened.issue != nil)
        await #expect(throws: (any Error).self) { try await reopened.create(pluginID: "codex", providerID: nil) }
        #expect(f.backend.launches.isEmpty)
        #expect(try String(contentsOf: f.paths.orbiterIndex, encoding: .utf8) == "broken")
    }

    @Test
    func handoffPreservesExistingDraftWhileOrbieHasAnActiveMessage() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = OrbieStore(paths: f.paths, hostID: f.hostID)
        let orbie = OrbieService(store: store, workflows: f.workflows, launch: { _ in
            f.backend.observations.append(.init(f.source))
            return f.source.workspacePane
        }, locateCreation: { _ in nil })
        await orbie.refresh()
        try await orbie.create(pluginID: "codex", providerID: nil)
        orbie.draft = "A message already in progress"
        await orbie.send()
        #expect(orbie.hasActiveRun)
        orbie.draft = "Existing draft"
        try await orbie.stageReport("Task report for explicit summary")
        #expect(orbie.draft.hasPrefix("Existing draft\n\n"))
        #expect(try await store.load().draft == orbie.draft)
        #expect(f.backend.schedules.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func uncertainSubmissionReconcilesWithoutLosingNewDraftOrReplaying(newDraft: Bool, restart: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let backup = f.root.appendingPathComponent("saved-index")
        f.backend.beforeSchedule = {
            do {
                try FileManager.default.moveItem(at: f.paths.orbieStateRoot, to: backup)
                try Data("blocked".utf8).write(to: f.paths.orbieStateRoot)
            } catch { Issue.record(error) }
        }
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil) }
        #expect(f.backend.schedules.count == 1)
        try FileManager.default.removeItem(at: f.paths.orbieStateRoot)
        try FileManager.default.moveItem(at: backup, to: f.paths.orbieStateRoot)
        let id = try #require(f.service.tasks.first?.id)
        let expectedDraft = newDraft ? "New follow-up that has never been sent" : ""
        if newDraft {
            f.service.taskDrafts[id] = expectedDraft
            await f.service.saveDrafts()
            #expect(try await f.store.load().tasks.first?.draft == expectedDraft)
        }
        let reopened = restart ? f.reopened() : f.service
        await reopened.refresh()
        #expect(reopened.tasks.first?.pendingRunID == nil)
        #expect(reopened.tasks.first?.draft == expectedDraft)
        #expect(reopened.taskDrafts[id] == expectedDraft)
        #expect(try await f.store.load().tasks.first?.draft == expectedDraft)
        #expect(reopened.runs.count == 1 && f.backend.schedules.count == 1)
    }

    @Test(arguments: [false, true])
    func createdPaneCannotBindAReplacementServerOrDeliverToIt(fork: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.backend.replaceCreationServer = true
        await #expect(throws: AgentWorkflowError.self) { try await f.service.create(pluginID: "codex", providerID: nil, fork: fork) }
        #expect(f.service.tasks.count == 1)
        #expect(f.service.tasks.first?.pane == nil && f.service.tasks.first?.binding == nil)
        #expect(f.service.tasks.first?.draft.contains("Check the selected audio issue") == true)
        #expect(f.backend.launches.count == 1 && f.backend.schedules.isEmpty)
        #expect(try await f.workflows.snapshot().runs.isEmpty)
        await f.service.refresh()
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(reopened.tasks.first?.pane == nil && reopened.tasks.first?.binding == nil)
        #expect(f.backend.launches.count == 1 && f.backend.schedules.isEmpty)
    }

    @Test(arguments: [AgentWorkflowReadiness.busy, .draft, .awaitingHuman, .unavailable])
    func humanOwnedInputKeepsFollowup(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        try await f.service.end(#require(f.service.runs.first))
        f.backend.observations[0].readiness = readiness
        f.service.taskDrafts[id] = "Do not overwrite terminal input"
        await #expect(throws: AgentWorkflowError.self) { try await f.service.send(id) }
        #expect(f.service.taskDrafts[id] == "Do not overwrite terminal input")
        #expect(f.backend.schedules.count == 1)
    }

    @Test
    func archivedTaskIsRetainedAndDoesNotReplayOrConsumeCreationSlots() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        try await complete(f, runID: #require(f.service.runs.first).id, text: "Partial work with next steps")
        await f.service.refresh()
        try await f.service.setArchived(id, true)
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(reopened.tasks.first?.archived == true && reopened.activeCount == 0)
        #expect(reopened.runs.count == 1 && f.backend.schedules.count == 1)
        await #expect(throws: AgentWorkflowError.self) { try await reopened.send(id) }
        try await reopened.setArchived(id, false)
        #expect(f.backend.schedules.count == 1)
    }

    @Test
    func backgroundInspectionKeepsDraftEditingEnabled() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        f.backend.beforeScan = { for await _ in stream {
            break
        } }
        let refreshing = Task { await f.service.refresh() }
        for _ in 0..<1_000 where !f.service.isBusy {
            await Task.yield()
        }
        #expect(f.service.isBusy && !f.service.isOperating)
        f.service.draft.directory = f.root.path
        continuation.yield(())
        continuation.finish()
        await refreshing.value
        #expect(f.service.draft.directory == f.root.path)
        #expect(try await f.store.load().draft.directory == f.root.path)
    }

    @Test
    func lateResultCannotSettleTheFollowupInvocation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.service.create(pluginID: "codex", providerID: nil)
        let first = try #require(f.service.runs.first)
        try await complete(f, runID: first.id, text: "First verified report")
        await f.service.refresh()
        let result = try #require(f.service.runs.first?.invocations.first?.result)
        f.service.taskDrafts[id] = "Continue"
        try await f.service.send(id)
        let next = try #require(f.service.runs.last)
        let current = try #require(next.instances.first)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.ledger.update(runID: next.id) { execution in
                _ = try execution.succeed(result, instance: current, now: Date())
            }
        }
        await f.service.refresh(inspect: false)
        #expect(f.service.runs.last?.invocations.allSatisfy { $0.result == nil } == true)
        #expect(f.backend.schedules.count == 2)
    }

    @Test
    func associatingAnExistingAgentKeepsMaterialsAndRequiresExplicitSend() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.backend.observations = [.init(f.source)]
        await f.service.refresh()
        let candidate = try #require(f.service.instances.first)
        let id = try await f.service.associate(candidate)
        #expect(f.service.tasks.first?.origin == .associated)
        #expect(f.service.tasks.first?.binding?.matchesBinding(candidate) == true)
        #expect(f.service.taskDrafts[id]?.contains("Only this selected excerpt") == true)
        #expect(f.backend.launches.isEmpty && f.backend.schedules.isEmpty)
        let reopened = f.reopened()
        await reopened.refresh()
        #expect(f.backend.schedules.isEmpty)
        try await reopened.send(id)
        #expect(f.backend.schedules.count == 1 && f.backend.launches.isEmpty)
        #expect(reopened.tasks.first?.runIDs.count == 1)
    }
}
