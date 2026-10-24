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
            supported: { [weak self] in self?.agentWorkflowService != nil }
        ) { [weak self] request in
            guard let service = self?.agentWorkflowService else {
                throw AgentWorkflowError("Workflows are unavailable on this Host.")
            }
            return try await service.handle(request)
        }
    }

    func setupAgentWorkflows() async {
        guard let paths = ctrlxPaths else { return }
        do {
            @Dependency(HostIdentityClient.self) var identity
            let hostID = try await identity.load()
            let store = AgentWorkflowStore(
                fileURL: paths.stateRoot.appendingPathComponent("Workflows/ledger.json"), hostID: hostID
            )
            _ = try await store.snapshot()
            try await store.recoverAttachmentStorage()
            agentWorkflowStore = store
            agentWorkflowAgentService = AgentWorkflowAgentService(store: store, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance)
            })
            let gate = AgentWorkflowInputGate { [weak self] paneID in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                try await pauseAgentWorkflowInput(paneID: paneID, reason: "Human input took over the Agent. Continue the workflow when the terminal is ready.")
            }
            let delivery = AgentWorkflowTerminalTransport(
                store: store, gate: gate,
                temporaryDirectory: paths.stateRoot.appendingPathComponent("Workflows/input"),
                inspect: { [weak self] instance in
                    guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                    return try await inspectWorkflowInput(instance)
                },
                submit: { [weak self] instance, file, beforeWrite in
                    guard
                        let self,
                        let provider = pluginRegistry?.core(instance.pluginID) as? any AgentWorkflowProviding else {
                        throw AgentWorkflowError("The workflow Agent plugin is unavailable.")
                    }
                    try await tmuxService.submitWorkflowInput(instance, file: file, composer: provider.workflowComposer) { launch in
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
            agentWorkflowService = AgentWorkflowService(store: store, scan: { [weak self] previous in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await scanWorkflowInstances(previous: previous, hostID: hostID)
            }, schedule: { await runner.schedule(runID: $0) }, onFailure: { workflowLogger.error("\($0)") })
            await agentWorkflowService?.startMonitoring()
            agentWorkflowEvents = AgentWorkflowEventRouter(store: store, runner: runner, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance)
            }, onVerified: { [weak self] context in
                await self?.verifyAgentWorkflowContext(context)
            }, onFailure: { workflowLogger.error("\($0)") })
            agentWorkflowCompletion = AgentWorkflowCompletionMonitor(store: store, runner: runner, inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance)
            }, onFailure: { workflowLogger.error("\($0)") })
            tmuxService.workflowInputGate = gate
            controlClientManager.workflowInputGate = gate
        } catch {
            workflowLogger.error("Could not load workflow storage: \(error)")
        }
    }

    func stopAgentWorkflows() async {
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
        tmuxService.workflowInputGate = nil
        controlClientManager.workflowInputGate = nil
    }

    func handleAgentWorkflowEvent(_ event: PluginEvent, peer: PluginIngressPeer) async {
        do {
            try await recordWorkflowBridge(event, peer: peer)
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
        var live = try await inspectWorkflowInstance(instance)
        guard live.capabilityIssue == nil else { return live }
        guard
            let pane = windowManager.paneStates[instance.paneID],
            let provider = pluginRegistry?.core(instance.pluginID) as? any AgentWorkflowProviding else {
            throw AgentWorkflowError("The Agent is no longer available.")
        }
        if pane.agentSession?.state.openForm != nil {
            live.readiness = .awaitingHuman
        } else if pane.agentSession?.state.isActiveWorking == true {
            live.readiness = .busy
        } else if pane.editorSession != nil || !recoveredWorkspaceDrafts.localDrafts(paneID: instance.paneID).isEmpty {
            live.readiness = .draft
        } else {
            live.readiness = try AgentWorkflowComposerInspection.readiness(
                await tmuxService.captureWorkflowTerminal(instance), composer: provider.workflowComposer
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
    func inspectWorkflowInstance(_ instance: AgentWorkflowInstance) async throws -> AgentWorkflowInstance {
        @Dependency(AgentSessionIdentityClient.self) var identities
        @Dependency(WorkspaceAgentProcessClient.self) var processes
        guard let registry = pluginRegistry, let provider = registry.core(instance.pluginID) as? any AgentWorkflowProviding else {
            throw AgentWorkflowError("The Agent's workflow plugin is no longer available.")
        }
        guard identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else {
            throw AgentWorkflowError("The Agent process changed.")
        }
        let pane = try await tmuxService.captureWorkspacePane(target: instance.paneID, expectedServerID: instance.workspacePane.serverID)
        guard pane.identity.isSamePane(as: instance.workspacePane) else {
            throw AgentWorkflowError("The Agent's terminal was replaced.")
        }
        guard let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true) else {
            try Task.checkCancellation()
            throw AgentWorkflowInspectionUnavailable()
        }
        guard
            let current = detected[instance.paneID], current.pluginID == instance.pluginID,
            current.processIDs == [String(instance.processID)],
            let native = await identities.load(instance.paneID),
            native.processID == String(instance.processID), native.runtimeID == instance.processRuntimeID,
            native.source.pluginID == instance.pluginID, native.source.sessionID == instance.conversationID,
            windowManager.paneStates[instance.paneID]?.claudeSessionID == instance.conversationID,
            identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else {
            throw AgentWorkflowError("Cannot verify the Agent's current process and conversation.")
        }
        var live = instance
        live.workspacePane = pane.identity
        live.workingDirectory = pane.info.currentPath
        do {
            let invocation = try await processes.invocation(String(instance.processID), instance.processRuntimeID)
            live.capabilityIssue = provider.workflowRuntimeIssue(cliVersion: invocation.version)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            live.capabilityIssue = "Cannot inspect this Agent's CLI: \(error.localizedDescription)"
        }
        if live.capabilityIssue == nil {
            guard let store = agentWorkflowStore else { throw AgentWorkflowError("Workflow storage is not ready.") }
            live.capabilityIssue = try await store.bridgeIssue(for: live)
        }
        live.capabilities = live.capabilityIssue == nil ? provider.workflowCapabilities : nil
        if live.capabilityIssue != nil {
            live.readiness = .unavailable
        }
        return live
    }
}
