import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieRefreshTests {
    private actor Gate {
        var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentWorkflowError("The expected operation never reached its gate")
    }

    @Test(arguments: [false, true])
    func confirmedResetWaitsForRefreshWithoutLosingHistoryOrDraft(scanFails: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        service.draft = "Previous message"
        await service.send()
        let message = try #require(service.messages.last)
        try await f.complete(message)
        await service.refresh()
        let gate = Gate()
        f.beforeScan = {
            await gate.wait()
            if scanFails {
                throw AgentWorkflowInspectionUnavailable()
            }
        }
        // An inspected binding change would overwrite a reset that ran too early.
        f.observations[0].processRuntimeID = "501:100:200:0"
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        #expect(service.isRefreshing && !service.isBusy)
        service.draft = "Keep my draft"
        await service.saveDraft()
        #expect(!service.isBusy)
        let reset = Task { await service.resetBinding() }
        try await waitUntil { service.isBusy }
        let scans = f.scanCount
        await service.refresh()
        #expect(f.scanCount == scans && service.record?.creation != nil)
        await gate.release()
        await refresh.value
        await reset.value
        try await waitUntil { service.record?.draft == "Keep my draft" && !service.isBusy }
        #expect(service.record?.creation == nil && service.record?.binding == nil)
        #expect(service.instance == nil && !service.tabClosed && service.issue == nil)
        #expect(service.messages.last?.answer == "verified answer")
        let saved = try await OrbieStore(paths: f.paths, hostID: f.hostID).load()
        #expect(saved.creation == nil && saved.binding == nil && saved.messageIDs == [message.id])
        #expect(saved.draft == "Keep my draft")
        #expect(f.launches.count == 1 && f.writes.count == 1)
        #expect(FileManager.default.fileExists(atPath: service.directory))
        try await f.cleanup()
    }

    @Test
    func cancelledResetDoesNotDetachAndReleasesOperation() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        let before = service.record
        let gate = Gate()
        f.beforeScan = { await gate.wait() }
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        let reset = Task { await service.resetBinding() }
        try await waitUntil { service.isBusy }
        reset.cancel()
        await gate.release()
        await refresh.value
        await reset.value
        #expect(service.record == before && !service.isBusy && !service.isRefreshing)
        await service.resetBinding()
        #expect(service.record?.creation == nil)
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func restoreRechecksAvailabilityAfterWaitingForInspection(alreadyRunning: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { id in
            await f.observations.contains { $0.workspacePane.paneID == id.paneID }
        }, launch: { token, saved in
            try await MainActor.run {
                let pane = try f.create(token, pluginID: saved.pluginID, title: "Restored", directory: saved.projectPath)
                f.observations[0].conversationID = saved.sessionID
                return pane
            }
        }, locate: { await f.launches[$0] }, inspect: { pane, _ in
            try await f.catalog.snapshot(refresh: true).first { $0.workspacePane == pane }
        })
        let service = await f.orbie(recovery: recovery)
        try await service.create(pluginID: "codex", providerID: nil)
        let original = try #require(service.instance)
        let observation = try #require(f.observations.first)
        try await recovery.capture(original.agentID, descriptor: .init(pluginID: "codex", sessionID: original.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
        f.observations = []
        await service.refresh()
        let gate = Gate()
        f.beforeScan = { await gate.wait() }
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        let restore = Task { await service.restoreOriginalConversation() }
        try await waitUntil { service.isBusy }
        #expect(f.launches.count == 1 && service.tabClosed)
        if alreadyRunning {
            f.observations = [observation]
        }
        await gate.release()
        await refresh.value
        await restore.value
        #expect(f.launches.count == (alreadyRunning ? 1 : 2) && f.writes.isEmpty)
        #expect(service.instance?.conversationID == original.conversationID)
        #expect((service.instance?.agentID == original.agentID) == alreadyRunning)
        #expect(!service.isBusy && !service.tabClosed && service.issue == nil)
        try await f.cleanup()
    }

    @Test
    func restoringStateRemainsVisibleDuringRecoveryVerification() async throws {
        let f = try await AgentInteractionTestSupport()
        let gate = Gate()
        let delay = LockIsolated(false)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { token, saved in
            try await f.create(token, pluginID: saved.pluginID, title: "Starting", directory: saved.projectPath)
        }, locate: { await f.launches[$0] }, inspect: { _, _ in
            if delay.value {
                await gate.wait()
            }
            return nil
        })
        let service = await f.orbie(recovery: recovery)
        try await service.create(pluginID: "codex", providerID: nil)
        let original = try #require(service.instance)
        try await recovery.capture(original.agentID, descriptor: .init(pluginID: "codex", sessionID: original.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
        f.observations = []
        await service.refresh()
        await service.restoreOriginalConversation()
        #expect(service.isRestoring)
        delay.setValue(true)
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        #expect(service.isRestoring && !service.canRestore)
        #expect(service.availability == "Restoring the original conversation…")
        await gate.release()
        await refresh.value
        #expect(service.isRestoring && service.issue == nil)
        #expect(f.launches.count == 2 && f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func sendWaitsForRefreshAndChecksCurrentReadiness() async throws {
        let f = try await AgentInteractionTestSupport()
        let service = await f.orbie()
        try await service.create(pluginID: "codex", providerID: nil)
        let gate = Gate()
        f.beforeScan = { await gate.wait() }
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        service.draft = "Keep this until the Agent is ready"
        let send = Task { await service.send() }
        try await waitUntil { service.isBusy }
        f.observations[0].readiness = .awaitingHuman
        await gate.release()
        await refresh.value
        await send.value
        #expect(f.writes.isEmpty && service.draft == "Keep this until the Agent is ready")
        #expect(service.issue?.contains("answer or approval") == true)
        f.observations[0].readiness = .ready
        await service.send()
        #expect(f.writes.count == 1 && service.issue == nil)
        try await f.cleanup()
    }

    @Test(arguments: [false, true])
    func closedStateRemainsVisibleUntilInspectionFinishes(scanFails: Bool) async throws {
        let f = try await AgentInteractionTestSupport()
        let gate = Gate()
        let delay = LockIsolated(false)
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in
            if delay.value {
                await gate.wait()
                if scanFails {
                    throw AgentWorkflowInspectionUnavailable()
                }
            }
            return false
        }, launch: { _, _ in throw CancellationError() }, locate: { _ in nil }, inspect: { _, _ in nil })
        let service = await f.orbie(recovery: recovery)
        try await service.create(pluginID: "codex", providerID: nil)
        f.observations = []
        await service.refresh()
        let availability = service.availability
        delay.setValue(true)
        let refresh = Task { await service.refresh() }
        defer { Task { await gate.release()
            await refresh.value
        } }
        try await waitUntil { await gate.entered }
        #expect(service.tabClosed && service.availability == availability)
        #expect(!service.isBusy)
        await gate.release()
        await refresh.value
        #expect(service.tabClosed && service.availability == availability)
        #expect((service.issue != nil) == scanFails)
        delay.setValue(false)
        await service.refresh()
        #expect(service.issue == nil)
        try await f.cleanup()
    }

    @Test
    func missingConversationErrorSurvivesPollingUntilExplicitReset() async throws {
        let f = try await AgentInteractionTestSupport()
        let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in false }, launch: { _, _ in
            Issue.record("Missing evidence must not launch an Agent")
            throw CancellationError()
        }, locate: { _ in nil }, inspect: { _, _ in nil })
        let service = await f.orbie(recovery: recovery)
        try await service.create(pluginID: "codex", providerID: nil)
        f.observations = []
        await service.refresh()
        await service.restoreOriginalConversation()
        let issue = try #require(service.issue)
        #expect(issue.contains("No verified native conversation was retained"))
        await service.refresh(inspect: false)
        await service.refresh()
        #expect(service.issue == issue)
        f.beforeScan = { throw AgentWorkflowInspectionUnavailable() }
        await service.refresh()
        #expect(service.issue == issue)
        f.beforeScan = nil
        await service.refresh()
        #expect(service.issue == issue && service.tabClosed)
        await service.resetBinding()
        #expect(service.issue == nil && service.record?.creation == nil)
        #expect(f.launches.count == 1 && f.writes.isEmpty)
        try await f.cleanup()
    }
}
