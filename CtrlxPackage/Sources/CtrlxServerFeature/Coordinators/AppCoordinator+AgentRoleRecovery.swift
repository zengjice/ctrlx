import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

extension AppCoordinator {
    func setupAgentRoleRecovery(hostID: UUID, paths: CtrlxPaths) {
        agentRoleRecovery = AgentRoleRecovery(file: paths.orbieStateRoot.appendingPathComponent("resume.json"), paneExists: { [weak self] id in
            guard let self else { throw AgentWorkflowError("The Host is unavailable.") }
            return try await self.rolePaneExists(id)
        }, launch: { [weak self] creationID, descriptor in
            guard let self else { throw AgentWorkflowError("The Host is unavailable.") }
            return try await self.createRoleResume(creationID, descriptor: descriptor, hostID: hostID)
        }, locate: { [weak self] id in
            guard let self else { throw AgentWorkflowError("The Host is unavailable.") }
            let format = OrbieCreationEvidence.format.replacingOccurrences(of: "#{@ctrlx-creation-id}", with: "#{?\(AgentRoleRecovery.launchTokenOption),#{\(AgentRoleRecovery.launchTokenOption)},#{@ctrlx-creation-id}}")
            let result = try await self.tmuxService.runTmuxCommand(["list-panes", "-a", "-F", format])
            if await self.tmuxService.confirmedNoServer(result) {
                return nil
            }
            guard result.isSuccess else { throw AgentWorkflowError(result.stderrString) }
            return try OrbieCreationEvidence.locate(id, output: result.stdoutString)
        }, inspect: { [weak self] pane, _ in
            guard let self, let catalog = await self.agentRuntimeCatalog else { throw AgentWorkflowError("The Agent directory is unavailable.") }
            if let live = try await catalog.snapshot(refresh: true).first(where: { $0.workspacePane.isSamePane(as: pane) }) {
                return live
            }
            let result = try await self.tmuxService.runTmuxCommand(["list-panes", "-a", "-F", "#{\(WorkspaceTmuxRecovery.paneKey)} #{pane_dead}"])
            if await self.tmuxService.confirmedNoServer(result) {
                throw AgentWorkflowError("The recovery terminal was closed. Create a new Agent explicitly; the saved conversation and materials are kept.")
            }
            guard result.isSuccess else { throw AgentWorkflowError("Cannot inspect the recovery terminal. Reconnect and refresh.") }
            let row = result.stdoutString.split(separator: "\n").map { $0.split(separator: " ") }.first { $0.first.flatMap { UUID(uuidString: String($0)) } == pane.paneID }
            guard let row else { throw AgentWorkflowError("The recovery terminal was closed. Create a new Agent explicitly; the saved conversation and materials are kept.") }
            if row.last == "1" {
                throw AgentWorkflowError("The Agent exited before its original conversation could be verified. Open the recovery terminal to inspect the CLI error, or explicitly create a new Agent.")
            }
            return nil
        }, recoverDescriptor: { [weak self] id, identity in
            guard let self else { throw AgentWorkflowError("The Host is unavailable.") }
            return try await self.recoverRoleDescriptor(id, identity: identity, paths: paths)
        }, resumeExisting: { [weak self] intentID, id, descriptor in
            guard let self else { throw AgentRoleRecovery.NotLaunched(reason: "The Host is unavailable.") }
            return try await self.resumeExistingRole(intentID, id: id, descriptor: descriptor)
        })
    }

    private func resumeExistingRole(_ intentID: UUID, id: AgentID, descriptor: AgentResumeDescriptor) async throws -> WorkspacePaneIdentity {
        let command: AgentForkLaunch
        let pane: PaneInfo
        do {
            guard
                agentRuntimeCatalog?.hostID == id.hostID,
                let provider = pluginRegistry?.core(descriptor.pluginID) as? any AgentSessionResuming else { throw AgentWorkflowError("The Agent plugin or Host is unavailable.") }
            command = try await provider.commandForResume(descriptor)
            let panes = await tmuxService.refreshPanes()
            guard let current = panes.first(where: { $0.workspaceIdentity?.paneID == id.paneID }) else { throw AgentWorkflowError("The original terminal is unavailable. Refresh and try again.") }
            pane = current
        } catch { throw AgentRoleRecovery.NotLaunched(reason: error.localizedDescription) }
        try await tmuxService.resumeStoppedRole(pane, directory: descriptor.projectPath, command: command, intentID: intentID)
        guard let identity = pane.workspaceIdentity else { throw AgentWorkflowError("The terminal identity is unavailable.") }
        return identity
    }

    /// Only explicit recovery reaches this path. Rebuild a descriptor for the
    /// exact saved conversation; never search by folder, title or recency.
    func recoverRoleDescriptor(_ id: AgentID, identity: AgentSessionIdentity?, paths: CtrlxPaths) async throws -> AgentResumeDescriptor? {
        guard agentRuntimeCatalog?.hostID == id.hostID else { throw AgentWorkflowError("This Agent belongs to another Host.") }
        let main = try await OrbieStore(paths: paths, hostID: id.hostID).load()
        let orbiters = try await OrbiterStore(paths: paths, hostID: id.hostID).load()
        return try await AgentRoleRecovery.descriptorForSavedRole(id, identity: identity, main: main, orbiters: orbiters) { [weak self] pluginID in
            await self?.pluginRegistry?.core(pluginID) as? any AgentSessionResuming
        }
    }

    private func rolePaneExists(_ id: AgentID) async throws -> Bool {
        guard agentRuntimeCatalog?.hostID == id.hostID else { throw AgentWorkflowError("This Agent belongs to another Host.") }
        let result = try await tmuxService.runTmuxCommand(["list-panes", "-a", "-F", "#{\(WorkspaceTmuxRecovery.paneKey)}"])
        if tmuxService.confirmedNoServer(result) {
            return false
        }
        guard result.isSuccess else { throw AgentWorkflowError("Cannot inspect terminals. Recovery availability is unknown; reconnect and refresh.") }
        return result.stdoutString.split(separator: "\n").contains { UUID(uuidString: String($0)) == id.paneID }
    }

    private func createRoleResume(_ creationID: UUID, descriptor: AgentResumeDescriptor, hostID: UUID) async throws -> WorkspacePaneIdentity {
        let launch: SessionLaunchPreparation.AgentLaunch
        do {
            guard let provider = pluginRegistry?.core(descriptor.pluginID) as? any AgentSessionResuming else { throw AgentWorkflowError("The Agent plugin is unavailable.") }
            let command = try await provider.commandForResume(descriptor)
            let preparation = SessionLaunchPreparation(workingDirectory: descriptor.projectPath, fork: command)
            guard let prepared = try tmuxService.agentLaunch(preparation) else { throw AgentWorkflowError("The Agent did not provide a resume command.") }
            launch = prepared
        } catch { throw AgentRoleRecovery.NotLaunched(reason: error.localizedDescription) }
        let created = try await tmuxService.createSession(
            baseName: "Orbie",
            width: 120,
            height: 40,
            workingDirectory: descriptor.projectPath,
            runCommand: launch.command,
            launchPayload: launch.payload,
            firstWindowName: "Resume",
            creationID: creationID
        )
        let panes = await tmuxService.refreshPanes()
        windowManager.updatePaneStates(from: panes)
        let identity = try Self.orbiterCreatedPane(.init(paneID: created.paneId, scope: .init(hostID: hostID, serverID: created.serverID), pluginID: descriptor.pluginID), panes: panes)
        agentModelPreferences.initialize(.init(pane: identity, defaults: newAgentModelShortcuts(pluginID: descriptor.pluginID, providerID: descriptor.providerID)), hostID: "local")
        return identity
    }
}
