import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Logging

private let workflowLogger = Logger(label: "com.jicezeng.ctrlx.workflows")

extension AppCoordinator {
    func localWorkflowEndpoint() -> AgentWorkflowEndpoint {
        AgentWorkflowEndpoint(
            id: "local", name: "This Mac", connected: { true },
            supported: { true }
        ) { [weak self] request in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            return try await handleAgentWorkflowRequest(request)
        }
    }

    func handleAgentWorkflowRequest(_ request: ManageAgentWorkflows) async throws -> AgentWorkflowResponse {
        guard let agentWorkflowService else {
            throw AgentWorkflowError(agentWorkflowStartupError ?? "Workflows are still starting on this Mac. Try again shortly.")
        }
        return try await agentWorkflowService.handle(request)
    }

    func setupAgentWorkflows() async {
        agentWorkflowStartupError = nil
        guard let paths = ctrlxPaths else { return }
        do {
            @Dependency(HostIdentityClient.self) var identity
            let hostID = try await identity.load()
            let gate = AgentWorkflowInputGate()
            try await setupAgentInteraction(hostID: hostID, paths: paths, gate: gate)
            let store = AgentWorkflowStore(
                fileURL: paths.stateRoot.appendingPathComponent("Workflows/ledger.json"), hostID: hostID,
                onNotificationPending: { [weak self] in
                    Task { @MainActor [weak self] in await self?.flushWorkflowNotifications() }
                }
            )
            let original = try await store.snapshot()
            try await agentRuntimeCatalog?.seedBridges(original.bridgeEvidence ?? [])
            if let messages = agentMessages {
                try await OrbieInteractionMigration.migrate(orbie: OrbieStore(paths: paths, hostID: hostID), orbiters: OrbiterStore(paths: paths, hostID: hostID), workflows: store, messages: messages.store)
            }
            try await store.recoverAttachmentStorage()
            agentWorkflowStore = store
            let notifications = AgentWorkflowNotificationDelivery(store: store, destinations: { [weak self] in
                await self?.workflowNotificationDestinations() ?? []
            }, send: { [weak self] event, destination in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                try await submitWorkflowNotification(event, destination: destination)
            })
            agentWorkflowNotifications = notifications
            agentWorkflowAgentService = AgentWorkflowAgentService(store: store, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
            }, synchronizeEvents: { [weak self] invocationID in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                try await synchronizeWorkflowEvents(invocationID)
            }, refreshInstances: { [weak self] in
                guard let service = await self?.agentWorkflowService else { throw AgentWorkflowError("The Host's workflow service is unavailable.") }
                _ = try await service.refreshInstancesCatalog()
            }, provider: { [weak self] pluginID in
                await self?.pluginRegistry?.core(pluginID) as? any AgentWorkflowProviding
            })
            let delivery = AgentWorkflowTerminalTransport(
                store: store, gate: gate,
                temporaryDirectory: paths.stateRoot.appendingPathComponent("Workflows/input"),
                inspect: { [weak self] instance in
                    guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                    return try await inspectWorkflowInput(instance)
                },
                checkInputOwner: { [weak self] id in try await self?.checkAgentMessageOccupancy(id) },
                loadModels: { [weak self] instance in
                    guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                    _ = try await inspectWorkflowInstance(instance)
                    _ = try await handleAgentModels(.init(workspacePane: instance.workspacePane), paneID: instance.paneID)
                },
                configureModel: { [weak self] instance, selection, input in
                    guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                    _ = try await inspectWorkflowInstance(instance)
                    _ = try await handleAgentModels(.init(workspacePane: instance.workspacePane, runtimeID: instance.processRuntimeID, selection: selection), paneID: instance.paneID, workflowInput: input)
                },
                submit: { [weak self] instance, file, images, beforeWrite, imagesReady in
                    guard
                        let self,
                        let provider = pluginRegistry?.core(instance.pluginID) as? any AgentWorkflowProviding else {
                        throw AgentWorkflowError("The workflow Agent plugin is unavailable.")
                    }
                    try await tmuxService.submitWorkflowInput(instance, file: file, images: images, composer: provider.workflowComposer, imagesReady: imagesReady) { launch in
                        @Dependency(AgentSessionIdentityClient.self) var identities
                        guard identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else {
                            throw AgentWorkflowError("The Agent process exited before submission. Nothing was sent.")
                        }
                        try beforeWrite(launch)
                    }
                },
                onFailure: { workflowLogger.error("\($0)") }
            )
            let runner = AgentWorkflowRunner(store: store, transport: delivery.transport, onFailure: { workflowLogger.error("\($0)") })
            agentWorkflowRunner = runner
            let recoveryTranscripts = CodexProcessSessionReader()
            let recovery = AgentWorkflowResultRecovery(store: store, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
            }, provider: { [weak self] pluginID in
                await self?.pluginRegistry?.core(pluginID) as? any AgentWorkflowProviding
            }, synchronizeIngress: { [weak self] in
                guard let self else { throw AgentWorkflowInspectionUnavailable() }
                try await synchronizeAgentIngress()
            }, transcriptPath: { instance in
                await recoveryTranscripts.transcriptPath(processID: String(instance.processID), runtimeID: instance.processRuntimeID, conversationID: instance.conversationID)
            })
            agentWorkflowService = AgentWorkflowService(store: store, scan: { [weak self] _ in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                guard let catalog = await self.agentRuntimeCatalog else { throw AgentWorkflowError("The Agent directory is unavailable.") }
                return try await catalog.snapshot(refresh: true).map(AgentWorkflowObservation.init)
            }, schedule: { await runner.schedule(runID: $0) }, checkInputOwner: { [weak self] id in try await self?.checkAgentMessageOccupancy(id) }, synchronizeEvents: { [weak self] id in
                guard let self else { throw AgentWorkflowInspectionUnavailable() }
                try await synchronizeWorkflowEvents(id, allowingStoppedReplay: true)
            }, resumeStep: { invocation, instance in
                try await delivery.resumeStep(invocation, instance: instance)
            }, recoverResults: { [weak self] original in
                let recovered = try await recovery.recover(original)
                await self?.agentWorkflowEvents?.discardRecoveredSubmissions(in: recovered)
                return recovered
            }, models: { [weak self] instance, refresh in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                _ = try await inspectWorkflowInstance(instance)
                let snapshot = try await handleAgentModels(.init(workspacePane: instance.workspacePane, refresh: refresh), paneID: instance.paneID)
                guard snapshot.runtimeID == instance.processRuntimeID else { throw AgentWorkflowError("The Agent restarted. Refresh the Agent list.") }
                return snapshot
            }, flushNotifications: { try await notifications.flush() }, onFailure: { workflowLogger.error("\($0)") })
            await agentWorkflowService?.startMonitoring()
            agentWorkflowEvents = AgentWorkflowEventRouter(store: store, runner: runner, catalog: agentRuntimeCatalog, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
            }, recheckConversation: { [weak self] event, peer, admit in
                guard let self else { return .superseded }
                if admit, await withCurrentPluginEvent(event, peer: peer, operation: { }) {
                    return .ready
                }
                return await windowManager.rejectsConversationReplay(event, peer: peer) ? .superseded : .deferred
            }, provider: { [weak self] pluginID in
                await self?.pluginRegistry?.core(pluginID) as? any AgentWorkflowProviding
            }, onVerified: { [weak self] context in
                await self?.verifyAgentWorkflowContext(context)
            }, onFailure: { workflowLogger.error("\($0)") })
            agentWorkflowCompletion = AgentWorkflowCompletionMonitor(store: store, runner: runner, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
            }, synchronizeIngress: { [weak self] in
                guard let self else { throw AgentWorkflowInspectionUnavailable() }
                try await synchronizeAgentIngress()
            }, onFailure: { workflowLogger.error("\($0)") })
            tmuxService.workflowInputGate = gate
            controlClientManager.workflowInputGate = gate
            agentWorkflowPresentationTask?.cancel()
            agentWorkflowPresentationTask = Task { @MainActor [weak self] in
                for await _ in await store.changes() {
                    guard !Task.isCancelled, let self else { return }
                    do {
                        let archive = try await store.snapshot()
                        await publishWorkflowPresentation(archive)
                    } catch { workflowLogger.error("Could not update workflow presentation: \(error)") }
                }
            }

        } catch {
            agentWorkflowStartupError = "Could not load workflows on this Mac: \(error.localizedDescription)"
            workflowLogger.error("Could not load workflow storage: \(error)")
        }
        if let messages = agentMessages, let hostID = await agentRuntimeCatalog?.hostID {
            do { try await activateAgentInteraction(hostID: hostID, paths: paths, messages: messages) }
            catch {
                agentWorkflowStartupError = "Could not load saved conversations: \(error.localizedDescription)"
                workflowLogger.error("Could not load Agent conversations: \(error)")
            }
        }
    }

    func stopAgentWorkflows() async {
        agentWorkflowPresentationTask?.cancel()
        agentWorkflowPresentationTask = nil
        _ = windowManager.applyWorkflowPresentation([:])
        await agentMessages?.shutdown()
        agentMessages = nil
        agentRuntimeCatalog = nil
        agentRoleRecovery = nil
        await orbiters?.shutdown()
        orbiters = nil
        orbieQueries = nil
        await orbie?.saveDraft()
        orbie = nil
        await agentWorkflowService?.shutdown()
        await agentWorkflowEvents?.shutdown()
        await agentWorkflowRunner?.shutdown()
        await agentWorkflowCompletion?.shutdown()
        agentWorkflowEvents = nil
        agentWorkflowCompletion = nil
        agentWorkflowRunner = nil
        agentWorkflowService = nil
        agentWorkflowAgentService = nil
        agentWorkflowStore = nil
        agentWorkflowNotifications = nil
        tmuxService.workflowInputGate = nil
        controlClientManager.workflowInputGate = nil
    }

    func handleAgentWorkflowEvent(_ event: PluginEvent, peer: PluginIngressPeer, unconfirmedSubmission: Bool = false) async {
        do {
            if !unconfirmedSubmission {
                try await recordWorkflowBridge(event, peer: peer)
            }
            try await agentMessages?.receive(event, peer: peer)
            if unconfirmedSubmission {
                try await agentWorkflowEvents?.receiveUnconfirmedSubmission(event, peer: peer)
                return
            }
            if event.workflow?.kind != .submitted, try await agentWorkflowEvents?.bufferPendingCompletion(event, peer: peer) == true {
                return
            }
            if
                event.workflow != nil, let store = agentWorkflowStore,
                try await !store.snapshot().instances.contains(where: {
                    $0.pluginID == event.pluginID && $0.paneID == event.tmuxPane
                        && peer.contains(processID: $0.processID, runtimeID: $0.processRuntimeID)
                }) {
                do { _ = try await agentWorkflowService?.refreshInstancesCatalog() }
                catch is AgentWorkflowInspectionUnavailable where event.workflow?.kind != .submitted {
                    // Results may still match a receipt already saved in the ledger.
                }
            }
            guard
                let context = try await agentWorkflowEvents?.receive(event, peer: peer) else { return }
            await verifyAgentWorkflowContext(context)
        } catch {
            workflowLogger.error("Could not process workflow evidence: \(error)")
            if let paneID = event.tmuxPane {
                await pauseAgentWorkflows(paneID: paneID, reason: "The Agent's workflow event could not be verified.")
            }
        }
    }

    func suppressesWorkflowAgentCompletion(_ event: PluginEvent, peer: PluginIngressPeer) async -> Bool {
        do { return try await agentWorkflowEvents?.suppressesAgentCompletion(event, peer: peer) ?? false }
        catch {
            workflowLogger.error("Could not check workflow notification preferences: \(error)")
            return false
        }
    }

    private func verifyAgentWorkflowContext(_ context: AgentWorkflowTurnContext) async {
        guard let provider = pluginRegistry?.core(context.instance.pluginID) as? any AgentWorkflowProviding else { return }
        await agentWorkflowCompletion?.verify(context, provider: provider)
    }

    func pauseAgentWorkflows(paneID: String, reason: String) async {
        do { try await pauseAgentWorkflowInput(paneID: paneID, reason: reason) }
        catch { workflowLogger.error("Could not pause a workflow: \(error)") }
    }

    private func pauseAgentWorkflowInput(paneID: String, reason: String) async throws {
        guard let store = agentWorkflowStore else { return }
        for run in try await store.snapshot().runs where (run.status == .running || run.status == .finishing) && run.instances.contains(where: { $0.paneID == paneID }) {
            try await store.update(runID: run.id) { $0.pause(reason: reason) }
        }
    }

    func inspectWorkflowInput(_ instance: AgentWorkflowInstance) async throws -> AgentWorkflowInstance {
        let live = try await inspectWorkflowInstance(instance)
        return try await inspectWorkflowReadiness(live)
    }

    func inspectWorkflowReadiness(_ instance: AgentWorkflowInstance) async throws -> AgentWorkflowInstance {
        var live = instance
        live.inputIssue = nil
        guard live.capabilityIssue == nil else { return live }
        guard
            let pane = windowManager.paneStates[instance.paneID],
            let provider = pluginRegistry?.core(instance.pluginID) as? any AgentWorkflowProviding else {
            throw AgentWorkflowError("The Agent is no longer available.")
        }
        if pane.agentSession?.state.openForm != nil {
            live.readiness = .awaitingHuman
        } else if try await agentWorkflowStore?.hasAskedQuestion(for: live) == true {
            live.readiness = .busy
        } else if try await agentWorkflowStore?.isStagingInput(for: live) == true {
            live.readiness = .busy
        } else if pane.agentSession?.state.isActiveWorking == true {
            live.readiness = .busy
        } else if pane.editorSession != nil || !recoveredWorkspaceDrafts.localDrafts(paneID: instance.paneID).isEmpty {
            live.readiness = .draft
        } else {
            @Dependency(AgentSessionIdentityClient.self) var identities
            let workflowAllowsBinding = try await agentWorkflowStore?.allowsInitialConversationBinding(for: live) == true
            let allowsInitialBinding = CodexProcessSessionReader.supports(pluginID: live.pluginID) && live.conversationID.isEmpty || workflowAllowsBinding
            let issue = await identities.workflowInputIssue(for: live, allowsInitialBinding: allowsInitialBinding)
            try Task.checkCancellation()
            if let issue {
                live.readiness = .unavailable
                live.capabilityIssue = issue
                return live
            }
            try AgentWorkflowComposerInspection.apply(
                await tmuxService.captureWorkflowTerminal(instance, composer: provider.workflowComposer), composer: provider.workflowComposer, to: &live
            )
        }
        return live
    }

    func handleWorkflowAgentCommand(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        guard let agentWorkflowAgentService else {
            return .internalError(id: request.id, "Workflow storage is not ready on this Host.")
        }
        return await agentWorkflowAgentService.handle(request, peer: peer)
    }

    /// Revalidate process, stable pane and native conversation at the operation
    /// boundary. A label, saved native ID or reused tmux pane alone is insufficient.
    func inspectWorkflowInstance(_ instance: AgentWorkflowInstance, verifyNativeWriter: Bool = false) async throws -> AgentWorkflowInstance {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard let registry = pluginRegistry, let provider = registry.core(instance.pluginID) as? any AgentWorkflowProviding else {
            throw AgentWorkflowError("The Agent's workflow plugin is no longer available.")
        }
        guard identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else {
            throw AgentWorkflowInspectionUnavailable()
        }
        guard let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true) else {
            try Task.checkCancellation()
            throw AgentWorkflowInspectionUnavailable()
        }
        guard
            let current = detected[instance.paneID] else {
            throw AgentWorkflowInspectionUnavailable()
        }
        let pane = try await captureAgentBinding(paneID: instance.paneID, detected: current)
        guard pane.binding.matches(instance) else {
            throw AgentWorkflowInspectionUnavailable()
        }
        if verifyNativeWriter, CodexProcessSessionReader.supports(pluginID: instance.pluginID) {
            // The first submission can precede SessionStart. Its actual CLI
            // writer verifies the thread independently of the old UI/cache ID.
            guard await identities.codexOwnsSession(String(instance.processID), instance.processRuntimeID, instance.conversationID) else {
                throw AgentWorkflowInspectionUnavailable()
            }
        } else if !instance.conversationID.isEmpty || !CodexProcessSessionReader.supports(pluginID: instance.pluginID) {
            guard let state = windowManager.paneStates[instance.paneID] else { throw AgentWorkflowInspectionUnavailable() }
            guard
                let native = await identities.currentIdentity(in: state, detected: current),
                pane.binding.matches(native), native.source.sessionID == instance.conversationID,
                windowManager.paneStates[instance.paneID].flatMap(AgentForkSource.init(pane:)) == native.source else {
                throw AgentWorkflowError("Cannot verify the Agent's current process and conversation.")
            }
        }
        guard identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else { throw AgentWorkflowInspectionUnavailable() }
        var live = instance
        live.workspacePane = pane.binding.workspacePane
        live.workingDirectory = pane.info.currentPath
        return try await inspectWorkflowCapabilities(live, provider: provider, allowsFirstSubmission: !verifyNativeWriter)
    }

    func inspectWorkflowCapabilities(
        _ instance: AgentWorkflowInstance, provider: any AgentWorkflowProviding, allowsFirstSubmission: Bool = true
    ) async throws -> AgentWorkflowInstance {
        @Dependency(WorkspaceAgentProcessClient.self) var processes
        var live = instance
        do {
            let invocation = try await processes.invocation(String(instance.processID), instance.processRuntimeID)
            live.capabilityIssue = provider.workflowRuntimeIssue(cliVersion: invocation.version)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            live.capabilityIssue = "Cannot inspect this Agent's CLI: \(error.localizedDescription)"
        }
        if live.capabilityIssue == nil {
            guard let catalog = agentRuntimeCatalog else { throw AgentWorkflowError("The Agent directory is not ready.") }
            live.capabilityIssue = await catalog.bridgeIssue(for: live, allowsFirstSubmission: allowsFirstSubmission)
        }
        live.capabilities = live.capabilityIssue == nil ? provider.workflowCapabilities : nil
        if live.capabilityIssue != nil {
            live.readiness = .unavailable
        }
        return live
    }
}

extension AppCoordinator {
    func flushWorkflowNotifications() async {
        do { try await agentWorkflowNotifications?.flush() }
        catch { workflowLogger.error("Workflow notification bookkeeping failed: \(error)") }
    }

    func workflowNotificationDestinations() -> [String] {
        ["local"] + settings.pairedViewers.flatMap { ["push:\($0.id)", "live:\($0.id)"] }
    }

    private func publishWorkflowPresentation(_ archive: AgentWorkflowArchive) async {
        let statuses = AgentWorkflowPaneStatus.presentations(
            runs: archive.runs, hostID: archive.hostID,
            attentionRunIDs: Set(archive.notifications?.values.filter { $0.kind == .attention }.map { $0.target.runID } ?? [])
        )
        if windowManager.applyWorkflowPresentation(statuses) {
            await connectedViewerManager?.pushSessionStateToAll()
        }
        await broadcastBadgeDecreaseIfNeeded()
    }

    func submitWorkflowNotification(_ event: AgentWorkflowNotification, destination: String) async throws {
        if let store = agentWorkflowStore {
            let archive = try await store.snapshot()
            await publishWorkflowPresentation(archive)
        }
        if destination == "local" {
            try await terminalNotificationService.submitWorkflowNotification(.init(
                title: event.title, body: event.body, paneState: nil,
                agentID: event.agentID, eventType: event.eventType, workflow: event.target
            ))
        } else {
            guard let manager = connectedViewerManager else { throw AgentWorkflowError("The Relay connection is not ready.") }
            try await manager.sendWorkflowNotification(event, destination: destination)
        }
    }
}
