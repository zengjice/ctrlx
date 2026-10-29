import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func newAgentModelShortcuts(pluginID: String, providerID: String?) -> AgentModelShortcuts {
        let data = pluginSettingsData(id: pluginID)
        switch pluginID {
        case CodexPluginCore.pluginID:
            let settings = CodexSettings.decode(from: data)
            return settings.modelShortcutDefaults[(providerID ?? settings.resolvedDefaultProviderID) ?? ""] ?? .init()
        case ClaudeCodePluginCore.pluginID:
            let settings = ClaudeCodeSettings.decode(from: data)
            return settings.modelShortcutDefaults[(providerID ?? settings.resolvedDefaultProviderID) ?? ""] ?? .init()
        default:
            return .init()
        }
    }

    /// Export only metadata through the same native catalog reader as the status bar.
    func agentProviderModels(pluginID: String, providerID: String?) async throws -> [AgentModelOption] {
        guard
            let agent = InstallableAgentCLI(rawValue: pluginID),
            let core = pluginRegistry?.core(pluginID),
            let models = core as? any AgentModelProviding else {
            throw AgentModelError("Model shortcuts are not available for this Agent.")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.path
        let launch: LaunchCommand
        if let providerID {
            guard
                let selecting = core as? any AgentProviderSelecting,
                let command = try await selecting.commandForLaunch(projectPath: directory, providerID: providerID) else {
                throw AgentModelError("The Provider could not be loaded. Check its launch settings.")
            }
            launch = command
        } else {
            // This row means the CLI configuration, independently of the chosen launch default.
            launch = LaunchCommand(command: AgentCLICommandSettings.command(in: pluginSettingsData(id: pluginID), agent: agent))
        }
        @Dependency(AgentCLIClient.self) var cli
        guard case let .available(path, version, _) = await cli.inspect(agent, launch.command) else {
            throw AgentModelError("The Agent CLI is unavailable. Check Agent Setup before refreshing models.")
        }
        @Dependency(LoginShellPath.self) var loginPath
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessRunner.effectivePath(resolved: loginPath.resolve(), inherited: environment["PATH"])
        for key in launch.unsetEnvironment {
            environment.removeValue(forKey: key)
        }
        environment.merge(launch.env) { _, override in override }
        let context = AgentModelContext(
            invocation: .init(executable: path, arguments: launch.args, version: version),
            environment: environment, directory: directory
        )
        if let issue = models.modelRuntimeIssue(context) {
            throw AgentModelError(issue)
        }
        return try await models.modelOptions(context)
    }
}
