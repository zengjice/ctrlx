import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Logging

extension AppCoordinator {
    func checkAgentMessageOccupancy(_ id: AgentID) async throws {
        if try await agentMessages?.store.pending().contains(where: { $0.agentID == id }) == true {
            throw AgentWorkflowError("This Agent has an unfinished ordinary message. Check its terminal before starting a Workflow.")
        }
    }

    /// Set up input and replies before opening the optional workflow ledger.
    func setupAgentInteraction(hostID: UUID, paths: CtrlxPaths, gate: AgentWorkflowInputGate) async throws {
        let directory = paths.stateRoot.appendingPathComponent("AgentInteraction")
        let catalog = AgentRuntimeCatalog(hostID: hostID, bridgeFile: directory.appendingPathComponent("bridges.json")) { [weak self] previous in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            return try await scanWorkflowInstances(previous: previous, hostID: hostID)
        }
        agentRuntimeCatalog = catalog
        try await catalog.loadBridges()
        tmuxService.workflowInputGate = gate
        controlClientManager.workflowInputGate = gate
        let writer = AgentInputWriter(gate: gate, inspect: { [weak self] instance in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            return try await inspectWorkflowInput(instance)
        }, submit: { [weak self] instance, file, images, beforeWrite, imagesReady in
            guard let self, let provider = pluginRegistry?.core(instance.pluginID) as? any AgentWorkflowProviding else {
                throw AgentWorkflowError("The Agent plugin is unavailable.")
            }
            try await tmuxService.submitWorkflowInput(instance, file: file, images: images, composer: provider.workflowComposer, imagesReady: imagesReady) { launch in
                @Dependency(AgentSessionIdentityClient.self) var identities
                guard identities.runtimeID(String(instance.processID)) == instance.processRuntimeID else {
                    throw AgentWorkflowError("The Agent process exited before submission. Nothing was sent.")
                }
                try beforeWrite(launch)
            }
        })
        let messages = AgentMessageService(
            store: AgentMessageStore(directory: directory.appendingPathComponent("messages")),
            catalog: catalog,
            writer: writer,
            temporaryDirectory: directory.appendingPathComponent("input"),
            inspect: { [weak self] instance in
                guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
                return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
            },
            occupied: { [weak self] agentID in
                guard let store = await self?.agentWorkflowStore else { return nil }
                let occupied = try await store.snapshot().runs.contains {
                    !$0.status.isTerminal && $0.instances.contains { $0.agentID == agentID }
                }
                return occupied ? "This Agent is participating in a Workflow. Open Workflows or use its terminal to take over." : nil
            },
            provider: { [weak self] pluginID in
                await self?.pluginRegistry?.core(pluginID) as? any AgentWorkflowProviding
            },
            onFailure: { Logger(label: "com.jicezeng.ctrlx.agent-messages").error("\($0)") }
        )
        agentMessages = messages
    }

    func activateAgentInteraction(hostID: UUID, paths: CtrlxPaths, messages: AgentMessageService) async throws {
        try await messages.start()
        setupAgentRoleRecovery(hostID: hostID, paths: paths)
        setupOrbie(hostID: hostID, paths: paths, interaction: messages)
        setupOrbiters(hostID: hostID, paths: paths, interaction: messages)
        orbieQueries = OrbieQueryService(orbie: OrbieStore(paths: paths, hostID: hostID), orbiters: OrbiterStore(paths: paths, hostID: hostID), interaction: messages, workflows: { [weak self] in
            try await self?.agentWorkflowService?.snapshot()
        }, inspect: { [weak self] instance in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            return try await inspectWorkflowInstance(instance, verifyNativeWriter: true)
        })
        await orbie?.refresh(inspect: false)
    }
}
