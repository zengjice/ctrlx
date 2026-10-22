import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// The Claude Code agent, behind the agent-blind `PluginCore` contract (spec §4).
/// An in-process actor constructed from the compile-time registry.
///
/// All Claude-specific behavior lives here: project scanning, the host-agent
/// hook bridge install, the raw-hook → `PluginEvent` translation (the 30→5 event
/// mapping), keystroke building for response delivery, and notification copy.
/// The per-event behavioral contract is documented in `docs/plugins/claude-code.md`.
///
/// Defensive by mandate (spec §13): this core parses real-world on-disk data
/// (`~/.claude.json`, transcripts) and hook payloads, so it must never trap —
/// `do/try/catch` around every decode, no force-unwraps, skip-and-log malformed
/// entries.
public actor ClaudeCodePluginCore: AgentProviderSelecting, AgentProviderForking, AgentSessionResuming, AgentPluginMaintenance, AgentAccountReporting {
    public static let pluginID = "claude-code"

    private var host: (any PluginHost)?
    private var settings = ClaudeCodeSettings()

    private let scanner = ClaudeCodeScanner()
    private let accountReporter = ClaudeAccountReporter()

    @Dependency(ProcessRunner.self) private var processRunner
    @Dependency(SecretsService.self) private var secrets
    @Dependency(StopFinalityClassifier.self) private var stopFinalityClassifier

    private var marketplaceSource = URL(fileURLWithPath: "/")
    private var command = "claude"

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]

    #if os(macOS)
        private var watcher: ClaudeCodeProjectsWatcher?
    #endif

    public init() { }

    public func dashboardAccounts() async -> [DashboardAccount] {
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let paths = [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]].compactMap { $0 } + settings.additionalConfigFolders
        return await accountReporter.accounts(command: command, roots: [defaultRoot] + paths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Lifecycle

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        self.host = host
        // `env.settings` is the authoritative initial settings value (spec §11).
        settings = ClaudeCodeSettings.decode(from: env.settings)
        marketplaceSource = env.marketplaceSource
        command = settings.commandPath
        await refreshProjects()
        startWatcher()
    }

    public func shutdown() async {
        #if os(macOS)
            watcher?.stop()
            watcher = nil
        #endif
        host = nil
    }

    // MARK: - Ingress translation

    /// Parse the raw Claude hook payload and translate it into a `PluginEvent`.
    /// Returns `nil` to drop frames that produce no state change (the dispatcher
    /// no-ops). Reuses `HookAction.from(jsonData:)` for the 30-case parse and the
    /// durable `HookEvent` / `HookEventMessage` semantics for working state and
    /// notification copy (additive phase — those types still live in networking).
    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        // Drop subagent (`Task`) hook events — those carrying an `agent_id` — the
        // way the legacy shared `HookServerService` did for every agent. They
        // describe a subagent's lifecycle, not the main agent's, and must not drive
        // the main session's status: a trailing `SubagentStop` fires ~seconds AFTER
        // the main `Stop` and would flip the just-stopped session back to "Working".
        // `PermissionRequest` is the sole exception. Shared with Codex so neither
        // core can drift (see `CommonHookFields.droppableSubagentEventName`).
        if let dropped = CommonHookFields.droppableSubagentEventName(payload: frame.payload) {
            await log(.debug, "Ignoring subagent hook event: \(dropped)")
            return nil
        }

        let action: HookAction
        do {
            action = try HookAction.from(jsonData: frame.payload)
        } catch {
            await log(.warn, "Dropping unparseable Claude hook payload: \(error)")
            return nil
        }

        // Drop message-less main-agent Stops. Subagents fire the plain `Stop` too
        // (not always with an `agent_id` for the pre-parse drop above to catch);
        // only main-agent stops carry `last_assistant_message`. Applying a
        // message-less one would flip a mid-task session to doneWorking and fire a
        // bogus notification. Co-located with the subagent drop above (rather than
        // buried in the pure/stateless translator) so a stuck-"Working" report is
        // diagnosable from the log.
        if case let .stop(stopBody) = action, stopBody.lastAssistantMessage == nil {
            await log(.debug, "Ignoring message-less Stop hook (subagent stop)")
            return nil
        }

        // Downgrade Stops that are a pause, not a finish (issue #644): Claude
        // also fires Stop when it parks the turn waiting on background tasks /
        // session crons to wake it back up. The payload's arrays alone can't
        // distinguish the two (a task pending termination lingers after a
        // genuinely final message), so when background work is in flight, Apple
        // Intelligence gets the last word on whether the message reads as final.
        // A still-waiting Stop keeps the session "Working" but still surfaces the
        // interim summary as a notification — flavored "still working", not done;
        // the real final Stop drives the done state (and its notification) later.
        // The classifier fails open to `.final`, so a wrong downgrade can't
        // happen on classifier failure — and a wrong keep is just today's
        // behavior. Opt-out per agent via the `detect_false_stops` setting
        // (Settings → Agents → Claude Code).
        if
            settings.detectFalseStops,
            case let .stop(stopBody) = action,
            let message = stopBody.lastAssistantMessage,
            !message.isEmpty {
            let pendingWork = stopBody.pendingBackgroundWork
            if
                !pendingWork.isEmpty,
                // The classifier judges the message alone — no pending-work
                // info reaches the prompt (task descriptions are agent-authored
                // free text that steers the verdict, and even neutral counts
                // anchor it). The labels go to the log below.
                await stopFinalityClassifier.classify(message: message) == .stillWaiting {
                await log(
                    .info,
                    "Stop hook downgraded to still-working — background work in flight "
                        + "(\(pendingWork.joined(separator: ", "))) and the last assistant "
                        + "message doesn't read as final"
                )
                return stillWorkingEvent(for: stopBody, frame: frame, summary: message)
            }
        }

        guard
            let output = ClaudeCodeTranslator.translate(
                action: action,
                pluginID: frame.pluginID,
                tmuxPane: frame.tmuxPane,
                contextProjectDir: frame.context["CLAUDE_PROJECT_DIR"],
                // Mint a unique id per ingress frame so each opened form gets a
                // distinct requestID. Claude hooks carry no timestamp/sequence, so
                // this is the only disambiguator between two same-type forms in one
                // session — without it iOS reuses the first form's persisted answer.
                occurrenceID: UUID().uuidString,
                closePaneOnSessionEnd: settings.closePaneOnSessionEnd
            )
        else {
            return nil
        }

        // Retain the per-request context keyed by requestID so a later
        // `deliverResponse` can build the right keystrokes. The open form rides
        // the state's `awaiting*` case; `deliverResponse` clears the entry once
        // answered (a non-awaiting state simply opens no form, so nothing to
        // retract here).
        if let form = output.event.state?.openForm, let pending = output.pending {
            pendingRequests[form.requestID] = pending
        }

        return output.event
    }

    /// Builds the event for a Stop downgraded to still-working (issue #644):
    /// the session keeps its spinner (`.working` emitted explicitly, so the
    /// state is guaranteed regardless of what preceded it) while the user still
    /// gets the turn's summary as a notification — flavored as an interim
    /// update, not a finish. No app actions: a pause must not trigger anything
    /// a real finish can (pane close, markdown-open suggestions). The copy
    /// mirrors the translator's Stop notification (project-name prefix, 256-char
    /// truncation) so the two read as siblings.
    private func stillWorkingEvent(
        for body: StopBody,
        frame: IngressFrame,
        summary: String
    ) -> PluginEvent {
        let projectPath = frame.context["CLAUDE_PROJECT_DIR"] ?? body.cwd
        let projectName = projectPath.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
        } ?? ClaudeCodeTranslator.agentDisplayName
        let truncated = summary.count > 256
            ? String(summary.prefix(256)) + "..."
            : summary
        return PluginEvent(
            pluginID: frame.pluginID,
            sessionID: body.sessionId,
            state: .working,
            notification: NotificationSpec(
                title: "Still Working",
                body: "\(projectName): \(truncated)"
            ),
            appActions: [],
            tmuxPane: frame.tmuxPane,
            projectPath: projectPath,
            permissionMode: body.permissionMode
        )
    }

    // MARK: - Response delivery

    /// Translate the structured `AgentResponse` into Claude keystrokes and drive
    /// delivery through the host, then clear the retained context for the request.
    public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
        guard let host else { return }

        let pending = pendingRequests[requestID]
        let deliveries = ClaudeCodeKeystrokes.deliveries(for: response, pending: pending)

        for delivery in deliveries {
            switch delivery {
            case let .text(text):
                await host.sendText(sessionID: sessionID, text)
            case let .keys(keys):
                await host.sendKeys(sessionID: sessionID, keys)
            }
        }

        pendingRequests.removeValue(forKey: requestID)
    }

    // MARK: - Projects

    /// Rescan `~/.claude.json` + `~/.claude/projects/` (and extra config folders)
    /// and push the agent-blind project list to the host.
    public func refreshProjects() async {
        guard let host else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = scanner.scan(
            home: home,
            additionalConfigFolders: settings.additionalConfigFolders
        )
        await host.setProjects(projects)
    }

    // MARK: - Auto-launch

    public func commandForLaunch(projectPath _: String) async -> LaunchCommand? {
        try? await commandForLaunch(projectPath: "", providerID: nil)
    }

    public func providerOptions() async -> [AgentProviderOption] {
        settings.providerOptions
    }

    public func commandForLaunch(projectPath _: String, providerID: String?) async throws -> LaunchCommand? {
        guard settings.autoRun else { return nil }
        let provider = try await providerConfiguration(providerID ?? settings.defaultProviderID)
        return LaunchCommand(
            command: settings.commandPath,
            env: provider.environment,
            unsetEnvironment: provider.unsetEnvironment
        )
    }

    public func commandForFork(sessionID: String, projectPath _: String) async throws -> AgentForkLaunch {
        try await commandForFork(sessionID: sessionID, projectPath: "", targetProviderID: nil)
    }

    public func commandForFork(sessionID: String, projectPath _: String, targetProviderID: String?) async throws -> AgentForkLaunch {
        guard UUID(uuidString: sessionID) != nil else { throw AgentForkError("Invalid Claude Code conversation ID.") }
        @Dependency(AgentForkHistoryClient.self) var history
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let roots = [defaultRoot] + [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]].compactMap { $0 } + settings.additionalConfigFolders
        let root = try await history.root(sessionID, roots, .claude)
        let usesDefaultRoot = root == URL(fileURLWithPath: defaultRoot).resolvingSymlinksInPath().path
        let provider = try await providerConfiguration(targetProviderID)
        var environment = provider.environment
        if !usesDefaultRoot {
            environment["CLAUDE_CONFIG_DIR"] = root
        }
        return AgentForkLaunch(
            command: LaunchCommand(
                command: settings.commandPath,
                args: ["--resume", sessionID, "--fork-session"],
                env: environment
            ),
            // Setting even the default root changes where Claude stores .claude.json.
            unsetEnvironment: Self.unique(provider.unsetEnvironment + (usesDefaultRoot ? ["CLAUDE_CONFIG_DIR"] : []))
        )
    }

    /// Verified with scripts/verify-workspace-agent-resume.py (idle/interrupted/approval).
    private static let verifiedResumeVersion = "2.1.276 (Claude Code)"

    public func recoveryDescriptor(sessionID: String, projectPath: String, invocation: AgentResumeInvocation? = nil) async throws -> AgentResumeDescriptor {
        guard UUID(uuidString: sessionID) != nil else { throw AgentForkError("Invalid Claude Code conversation ID.") }
        @Dependency(AgentForkHistoryClient.self) var history
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
        let roots = invocation.map { [$0.configurationRoots["CLAUDE_CONFIG_DIR"] ?? defaultRoot] }
            ?? ([defaultRoot] + [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]].compactMap { $0 } + settings.additionalConfigFolders)
        let root = try await history.root(sessionID, roots, .claude)
        let arguments = try Self.resumeArguments(invocation?.arguments ?? [])
        return AgentResumeDescriptor(
            pluginID: Self.pluginID,
            sessionID: sessionID,
            projectPath: projectPath,
            configurationRoot: root,
            usesDefaultConfiguration: invocation.map { $0.configurationRoots["CLAUDE_CONFIG_DIR"] == nil } ?? (root == defaultRoot),
            executable: invocation?.executable,
            cliVersion: invocation?.version,
            arguments: arguments,
            automaticResumeUnavailableReason: invocation?.version == Self.verifiedResumeVersion ? nil : (invocation.map { "Automatic resume has not been verified for Claude Code \($0.version ?? "unknown version")." })
                ?? "The original process invocation was not recorded.",
            providerID: invocation?.providerID
        )
    }

    private static func resumeArguments(_ arguments: [String]) throws -> [String] {
        try AgentResumeArguments.capture(
            arguments,
            values: ["--model", "--permission-mode", "--effort", "--fallback-model", "--agent"],
            flags: ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--brief", "--disable-slash-commands", "--chrome", "--no-chrome"],
            ignoredValues: ["--resume", "--name"],
            ignoredFlags: ["--continue", "--fork-session"],
            aliases: ["-r": "--resume", "-c": "--continue", "-n": "--name"]
        )
    }

    public func commandForResume(_ descriptor: AgentResumeDescriptor) async throws -> AgentForkLaunch {
        guard
            descriptor.pluginID == Self.pluginID, UUID(uuidString: descriptor.sessionID) != nil,
            descriptor.configurationRoot.hasPrefix("/"), descriptor.projectPath.hasPrefix("/") else {
            throw AgentForkError("Invalid Claude Code recovery identity.")
        }
        @Dependency(AgentForkHistoryClient.self) var history
        let root = try await history.root(descriptor.sessionID, [descriptor.configurationRoot], .claude)
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
        guard !descriptor.usesDefaultConfiguration || root == defaultRoot else {
            throw AgentForkError("The recorded default Claude configuration directory has changed.")
        }
        guard try Self.resumeArguments(descriptor.arguments) == descriptor.arguments else { throw AgentForkError("Invalid Claude Code recovery options.") }
        let provider = try await providerConfiguration(descriptor.providerID)
        var environment = provider.environment
        if !descriptor.usesDefaultConfiguration {
            environment["CLAUDE_CONFIG_DIR"] = root
        }
        return AgentForkLaunch(
            command: LaunchCommand(
                command: descriptor.executable ?? settings.commandPath,
                args: ["--resume", descriptor.sessionID] + descriptor.arguments,
                env: environment
            ),
            unsetEnvironment: Self.unique(provider.unsetEnvironment + (descriptor.usesDefaultConfiguration ? ["CLAUDE_CONFIG_DIR"] : []))
        )
    }

    // MARK: - Provider launch configuration

    private func providerConfiguration(_ requestedID: String?) async throws -> ClaudeProviderLaunch {
        guard let providerID = requestedID else {
            return ClaudeProviderLaunch(environment: [:], unsetEnvironment: [])
        }
        guard settings.providerOptions.contains(where: { $0.id == providerID }) else {
            throw AgentProviderError("The selected Claude Code Provider no longer exists in Settings → Agents → Claude Code.")
        }
        if providerID == ClaudeCodeSettings.builtInProviderID {
            return ClaudeProviderLaunch(
                environment: [AgentProviderEnvironment.markerKey: providerID],
                unsetEnvironment: Self.providerEnvironmentKeys
            )
        }
        guard let profile = settings.providers.first(where: { $0.id == providerID }) else {
            throw AgentProviderError("The selected Claude Code Provider no longer exists in Settings → Agents → Claude Code.")
        }
        guard
            ClaudeCodeSettings.isValidProviderID(profile.id),
            ClaudeCodeSettings.isValidEnvironmentKey(profile.environmentKey),
            profile.environmentKey == profile.authKind.environmentKey,
            !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let url = URL(string: profile.baseURL), url.scheme == "http" || url.scheme == "https", url.host != nil,
            !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentProviderError("The selected Claude Code Provider has invalid settings. Edit it in Settings → Agents → Claude Code → Providers.")
        }
        let account = AgentProviderKeychainAccount.account(pluginID: Self.pluginID, providerID: profile.id)
        let apiKey: String?
        do {
            apiKey = try await secrets.loadSecret(account)
        } catch {
            throw AgentProviderError("The API key for Claude Code Provider '\(profile.name)' could not be read from Keychain.")
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw AgentProviderError("Add an API key for Claude Code Provider '\(profile.name)' in Settings → Agents → Claude Code → Providers.")
        }
        return ClaudeProviderLaunch(
            environment: [
                "ANTHROPIC_BASE_URL": profile.baseURL,
                profile.environmentKey: apiKey,
                "ANTHROPIC_MODEL": profile.model,
                AgentProviderEnvironment.markerKey: profile.id,
            ],
            unsetEnvironment: Self.providerEnvironmentKeys
        )
    }

    private static let providerEnvironmentKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
    ]

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - CLI-based plugin install

    public func install(configRoot: String?) async throws -> InstallResult {
        try await cliInstaller().install(configRoot: configRoot)
    }

    public func uninstall(configRoot: String?) async throws {
        try await cliInstaller().uninstall(configRoot: configRoot)
    }

    public func installStatus(configRoot: String?) async -> PluginInstallStatus {
        await cliInstaller().installStatus(configRoot: configRoot)
    }

    public func bundledPluginVersion() async throws -> String {
        try await cliInstaller().bundledVersion()
    }

    public func reinstall(configRoot: String?) async throws -> PluginInstallStatus {
        try await cliInstaller().reinstall(configRoot: configRoot)
    }

    // MARK: - Settings

    public func applySettings(_ raw: Data) async -> SettingsResult {
        let decoded = ClaudeCodeSettings.decode(from: raw)
        settings = decoded
        command = decoded.commandPath
        return .applied
    }

    // MARK: - Private helpers

    private func cliInstaller() -> ClaudeCodeCLIInstaller {
        ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: command,
            marketplaceSource: marketplaceSource
        )
    }

    private func startWatcher() {
        #if os(macOS)
            guard watcher == nil else { return }
            let projectsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
                .path
            let created = ClaudeCodeProjectsWatcher(path: projectsPath) { [weak self] in
                Task { [weak self] in
                    await self?.refreshProjects()
                }
            }
            created.start()
            watcher = created
        #endif
    }

    private func log(_ level: LogLevel, _ message: String) async {
        // Honor the per-plugin "Log level" setting (Settings → Agents): drop lines
        // below the configured threshold instead of writing every line.
        guard level >= settings.logLevel else { return }
        await host?.log(LogLine(level: level, message: message))
    }
}

private struct ClaudeProviderLaunch {
    let environment: [String: String]
    let unsetEnvironment: [String]
}
