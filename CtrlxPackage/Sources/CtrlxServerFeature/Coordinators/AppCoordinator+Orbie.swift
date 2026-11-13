import CtrlxCommon
import CtrlxNetworking
import Foundation

extension AppCoordinator {
    func setupOrbie(hostID: UUID, paths: CtrlxPaths, workflows: AgentWorkflowService) {
        orbie = OrbieService(store: OrbieStore(paths: paths, hostID: hostID), workflows: workflows) { [weak self] intent in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            let creation = try await workflowAgentCreation(hostID: hostID, creationID: intent.id)
            let created = try await creation.launch(nil, .init(
                sessionName: "Orbie", workingDirectory: intent.directory,
                pluginID: intent.pluginID, providerID: intent.providerID
            ))
            guard
                let pane = tmuxService.panes.first(where: {
                    $0.paneId == created.paneID && $0.workspaceIdentity?.serverID == created.scope.serverID
                })?.workspaceIdentity else {
                throw AgentWorkflowError("The Agent may have started, but its persistent terminal identity is not available yet.")
            }
            return pane
        } locateCreation: { [weak self] id in
            guard let self else { throw AgentWorkflowError("The Host is shutting down.") }
            _ = await tmuxService.refreshPanes()
            let result = try await tmuxService.runTmuxCommand([
                "list-panes", "-a", "-F", OrbieCreationEvidence.format,
            ])
            guard result.isSuccess else { throw AgentWorkflowError(result.stderrString) }
            return try OrbieCreationEvidence.locate(id, output: result.stdoutString)
        }
    }
}

/// A creation token is attached in the same tmux command as new-session,
/// before starting the Agent. A title is never creation evidence.
enum OrbieCreationEvidence {
    static var format: String {
        [
            "#{@ctrlx-creation-id}",
            "#{pid}:#{start_time}",
            "#{\(WorkspaceTmuxRecovery.sessionKey)}",
            "#{\(WorkspaceTmuxRecovery.windowKey)}",
            "#{\(WorkspaceTmuxRecovery.paneKey)}",
        ]
        .joined(separator: "\t")
    }

    static func locate(_ id: UUID, output: String) throws -> WorkspacePaneIdentity? {
        var matches: [WorkspacePaneIdentity] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.first == Substring(id.uuidString) else { continue }
            guard
                fields.count == 5, !fields[1].isEmpty,
                let sessionID = UUID(uuidString: String(fields[2])),
                let windowID = UUID(uuidString: String(fields[3])), let paneID = UUID(uuidString: String(fields[4])) else {
                throw AgentWorkflowError("The created Orbie terminal has not established its persistent identity. Check its terminal before rebuilding.")
            }
            let pane = WorkspacePaneIdentity(serverID: String(fields[1]), sessionID: sessionID, windowID: windowID, paneID: paneID)
            if !matches.contains(where: { $0.isSamePane(as: pane) }) {
                matches.append(pane)
            }
        }
        guard matches.count <= 1 else { throw AgentWorkflowError("Multiple terminals have the Orbie creation token. Resolve the ambiguity before continuing.") }
        return matches.first
    }
}
