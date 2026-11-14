import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation

extension AppCoordinator {
    func setupOrbiters(hostID: UUID, paths: CtrlxPaths, workflows: AgentWorkflowService) {
        orbiters = OrbiterService(store: OrbiterStore(paths: paths, hostID: hostID), workflows: workflows, enabled: { [weak self] in
            self?.orbie?.record?.enabled == true
        }, forkSource: { [weak self] in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            return try await readyOrbieForkSource()
        }, launch: { [weak self] task in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            let created: AgentWorkflowCreatedAgent
            if task.origin == .fork {
                let current = try await readyOrbieForkSource()
                guard
                    task.forkSource?.matchesBinding(current) == true,
                    let pane = windowManager.paneStates[current.paneID], let source = AgentForkSource(pane: pane),
                    source.sessionID == current.conversationID, source.workspaceIdentity == current.workspacePane else {
                    throw AgentWorkflowError("The Orbie Fork source changed. Review its conversation first.")
                }
                _ = try await prepareAgentFork(source, expectedWorkspacePane: current.workspacePane)
                let verified = try await readyOrbieForkSource()
                guard current.matchesBinding(verified) else { throw AgentWorkflowError("The Orbie conversation changed during Fork preparation.") }
                let paneID = try await forkAgentSession(.init(
                    requestID: task.id, source: source, windowName: task.title,
                    workingDirectory: task.directory, targetProviderID: task.providerID
                ), expectedWorkspacePane: current.workspacePane, creationID: task.id)
                created = .init(paneID: paneID, scope: .init(hostID: hostID, serverID: current.workspacePane.serverID), pluginID: task.pluginID)
            } else {
                let creation = try await workflowAgentCreation(hostID: hostID, creationID: task.id, firstWindowName: task.title)
                created = try await creation.launch(nil, .init(sessionName: task.title, workingDirectory: task.directory, pluginID: task.pluginID, providerID: task.providerID))
            }
            let panes = await tmuxService.refreshPanes()
            windowManager.updatePaneStates(from: panes)
            return try Self.orbiterCreatedPane(created, panes: panes)
        }, locateCreation: { [weak self] id in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            _ = await tmuxService.refreshPanes()
            let result = try await tmuxService.runTmuxCommand(["list-panes", "-a", "-F", OrbieCreationEvidence.format])
            guard result.isSuccess else { throw AgentWorkflowError(result.stderrString) }
            return try OrbieCreationEvidence.locate(id, output: result.stdoutString)
        })
        orbiters?.startObserving()
    }

    static func orbiterCreatedPane(_ created: AgentWorkflowCreatedAgent, panes: [PaneInfo]) throws -> WorkspacePaneIdentity {
        guard
            let identity = panes.first(where: {
                $0.paneId == created.paneID && $0.workspaceIdentity?.serverID == created.scope.serverID
            })?.workspaceIdentity else {
            throw AgentWorkflowError("The task Agent may have started, but its persistent pane identity is not confirmed. Check the existing task.")
        }
        return identity
    }

    func validateOrbiterFork(_ creationID: UUID, source: AgentForkSource) async throws {
        let current = try await readyOrbieForkSource()
        guard
            let expected = orbiters?.tasks.first(where: { $0.id == creationID })?.forkSource,
            expected.matchesBinding(current), current.paneID == source.paneID,
            current.conversationID == source.sessionID, current.workspacePane == source.workspaceIdentity else {
            throw AgentWorkflowError("The Orbie process or conversation changed before Fork. The task draft is kept.")
        }
    }

    private func readyOrbieForkSource() async throws -> AgentWorkflowInstance {
        guard let orbie else { throw AgentWorkflowError("Create Orbie first, or choose New Agent.") }
        await orbie.refresh()
        guard
            !orbie.isBusy, orbie.availability == nil, let current = orbie.instance,
            orbie.record?.binding?.matchesBinding(current) == true, UUID(uuidString: current.conversationID) != nil else {
            throw AgentWorkflowError("Orbie must have a ready, verified native conversation before Fork. Wait or choose New Agent.")
        }
        return current
    }
}
