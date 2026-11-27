import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies

extension AppCoordinator {
    func inheritedAgentForkLaunch(_ source: AgentForkSource) async throws -> AgentForkLaunch {
        let identity = try await captureAgentForkIdentity(source)
        guard
            let agent = pluginRegistry?.core(source.pluginID) as? any AgentSessionForking,
            identity.source.workspaceIdentity != nil else {
            throw AgentForkError("This Agent cannot inherit its source configuration.")
        }
        @Dependency(WorkspaceAgentProcessClient.self) var processes
        let invocation = try await processes.invocation(identity.processID, identity.runtimeID)
        let launch = try await agent.commandForFork(sessionID: source.sessionID, projectPath: source.workingDirectory, inheriting: invocation)
        let current = try await captureAgentForkIdentity(source, runtimeID: identity.runtimeID)
        guard current.processID == identity.processID else {
            throw AgentForkError("The source Agent changed while preparing Fork.")
        }
        return launch
    }
}
