import ClaudeCodePluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// The OpenAI Codex CLI agent, behind the agent-blind `PluginCore` contract.
/// An in-process actor constructed from the compile-time registry.
///
/// All Codex-specific behavior lives here: project scanning of
/// `~/.codex/sessions/` rollout files, the pane↔session correlation file at
/// `~/.ctrlx/codex-sessions/<tmux_pane>.json` (core-internal — spec §12),
/// the hook-bridge install, the raw-hook → `PluginEvent` translation, and
/// keystroke building. The per-event behavioral contract is documented in
/// `docs/plugins/codex.md`.
///
/// Defensive by mandate (spec §13): never trap on hostile on-disk data.
public actor CodexPluginCore: AgentProviderSelecting, AgentProviderForking, AgentSessionResuming, AgentPluginMaintenance, AgentAccountReporting {
    public static let pluginID = "codex"

    private var host: (any PluginHost)?
    private var settings = CodexSettings()

    private let scanner = CodexScanner()
    private var correlation: CodexSessionCorrelation
    private let correlationWasInjected: Bool
    private let configReader = CodexConfigReader()
    private let postureReader = CodexRolloutPostureReader()
    private let accountReporter = CodexAccountReporter()

    @Dependency(ProcessRunner.self) private var processRunner
    @Dependency(SecretsService.self) private var secrets

    private var marketplaceSource = URL(fileURLWithPath: "/")
    private var command = "codex"
    private var stateDirectory: URL?

    /// Base URL of the Mac-local OTLP receiver (e.g. `http://127.0.0.1:24318`),
    /// from `PluginEnv`. Used to build the `-c otel.…` launch overrides that
    /// point Codex's OTLP log export here (issue #602). `nil` when no receiver
    /// is running, in which case Codex launches with no OTEL overrides.
    private var otlpReceiverEndpoint: URL?

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]
    private var notifiedQuestionCalls: [String: Set<String>] = [:]

    /// Per-session reviewer snapshots (issue #585, multi-session divergence):
    /// what the session's CODEX_HOME `config.toml` said when the session
    /// started — the same value Codex itself loaded. `approvals_reviewer` is a
    /// GLOBAL file but a PER-SESSION runtime value: a TUI "Approve for me"
    /// toggle overrides only the toggling session's turn context while
    /// persisting the new value globally, so with two live sessions the file
    /// and a session's actual posture can diverge. See
    /// `approvalsReviewer(for:)` for how the snapshot gates suppression.
    private var reviewerSnapshots: [String: CodexApprovalsReviewer] = [:]

    /// Per-session cache of the last RESOLVED effective posture, so the
    /// per-tool events that only feed the permission-mode chip (`PreToolUse`
    /// / `PostToolUse` / `Stop`) don't re-read the rollout file on every tool
    /// call. Refreshed by every full resolution (session start, turn start,
    /// permission request) — see `approvalsReviewer(for:)`.
    private var reviewerPostures: [String: CodexApprovalsReviewer] = [:]

    #if os(macOS)
        private var watchers: [CodexSessionsWatcher] = []

        /// Panes confirmed running a `codex` process on the previous monitor tick.
        /// A recorded pane dropping out of this set means its Codex process exited.
        private var previouslyAlivePanes: Set<String> = []
        /// On its first tick the monitor reconciles correlation files left over
        /// from a prior app run instead of reporting them as fresh session ends.
        private var didReconcileOrphans = false
        private var sessionEndMonitor: Task<Void, Never>?

        /// How often to poll for Codex process exits (seconds). Codex CLI emits no
        /// `SessionEnd` hook, so this poll is the only end signal.
        private static let sessionEndPollSeconds: Double = 5
    #endif

    public init() {
        self.correlation = .live()
        self.correlationWasInjected = false
    }

    /// Test seam: inject the pane↔session correlation store so a test can point
    /// it at a temp directory instead of the real `~/.ctrlx/codex-sessions/`.
    init(correlation: CodexSessionCorrelation) {
        self.correlation = correlation
        self.correlationWasInjected = true
    }

    // MARK: - Lifecycle

    public func dashboardAccounts() async -> [DashboardAccount] {
        await accountReporter.accounts(command: command, roots: codexHomeRoots())
    }

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        if !correlationWasInjected {
            correlation = .live(stateDirectory: env.stateDir)
        }
        self.host = host
        // `env.settings` is the authoritative initial settings value (spec §11).
        settings = CodexSettings.decode(from: env.settings)
        marketplaceSource = env.marketplaceSource
        stateDirectory = env.stateDir
        otlpReceiverEndpoint = env.otlpReceiverEndpoint
        command = settings.commandPath
        await refreshProjects()
        #if os(macOS)
            startWatchers()
            startSessionEndMonitor()
        #endif
    }

    public func shutdown() async {
        notifiedQuestionCalls.removeAll()
        #if os(macOS)
            stopWatchers()
            stopSessionEndMonitor()
        #endif
        host = nil
    }

    // MARK: - Ingress translation

    /// Parse the raw Codex hook payload and translate it into a `PluginEvent`.
    /// Returns `nil` to drop frames that produce no state change (the dispatcher
    /// no-ops). Codex routes through the SAME `HookAction.from(jsonData:)` parse
    /// and the durable `HookEvent` / `HookEventMessage` semantics as Claude
    /// Code, so the parser is reused (additive phase).
    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        // Drop subagent (`Task`) hook events the way the legacy shared
        // `HookServerService` did for every agent. Codex's bridge forwards
        // SubagentStart/SubagentStop, and a trailing SubagentStop after the main
        // `Stop` would otherwise flip a just-stopped session back to "Working".
        // `PermissionRequest` is the sole exception. Shared with Claude Code so
        // neither core can drift (see `CommonHookFields.droppableSubagentEventName`).
        if let dropped = CommonHookFields.droppableSubagentEventName(payload: frame.payload) {
            await log(.debug, "Ignoring subagent hook event: \(dropped)")
            return nil
        }

        let action: HookAction
        do {
            action = try HookAction.from(jsonData: frame.payload)
        } catch {
            await log(.warn, "Dropping unparseable Codex hook payload: \(error)")
            return nil
        }

        // Resolve the pane: prefer the frame's TMUX_PANE; on a session start
        // persist the pane↔session correlation; otherwise, if the frame has no
        // pane, fall back to the correlation file by session id (spec §12).
        let tmuxPane = resolvePane(action: action, frame: frame)

        if
            case let .preToolUse(body) = action,
            let question = CodexQuestionNotification(payload: frame.payload) {
            guard notifiedQuestionCalls[body.sessionId, default: []].insert(question.callID).inserted else { return nil }
            // A question can be asynchronous. Notify without opening a blocking
            // form, retracting another form, or changing the agent's working state.
            let event = PluginEvent(
                pluginID: frame.pluginID,
                sessionID: body.sessionId,
                notification: question.notification,
                tmuxPane: tmuxPane,
                projectPath: frame.context["CODEX_PROJECT_DIR"] ?? body.cwd
            )
            return PluginWorkflowHook.addingEvidence(to: event, from: frame, nativeTurnKey: "turn_id")
        }

        // Maintain the per-session reviewer snapshots: a session start is the
        // moment Codex itself loads `config.toml`, so capture what it read; a
        // session end (synthesized by the pane poll today, honored here too in
        // case the bridge ever forwards a real one) drops the entry.
        switch action {
        case let .sessionStart(body):
            recordReviewerSnapshot(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .sessionEnd(body):
            notifiedQuestionCalls.removeValue(forKey: body.sessionId)
            reviewerSnapshots.removeValue(forKey: body.sessionId)
            reviewerPostures.removeValue(forKey: body.sessionId)
        default:
            break
        }

        let reviewer = await approvalsReviewer(for: action)
        guard
            let output = CodexTranslator.translate(
                action: action,
                pluginID: frame.pluginID,
                tmuxPane: tmuxPane,
                contextProjectDir: frame.context["CODEX_PROJECT_DIR"],
                // Mint a unique id per ingress frame so each opened form gets a
                // distinct requestID. Hooks carry no timestamp/sequence, so this is
                // the only disambiguator between two same-type forms in one session
                // — without it iOS reuses the first form's persisted answer.
                occurrenceID: UUID().uuidString,
                closePaneOnSessionEnd: settings.closePaneOnSessionEnd,
                approvalsReviewer: reviewer
            )
        else {
            return nil
        }

        if output.guardianHandled {
            await log(
                .debug,
                "Guardian (auto_review) will decide this permission request — suppressing notification and form"
            )
        }

        // Retain the per-request context keyed by requestID so a later
        // `deliverResponse` can build the right keystrokes. The open form rides
        // the state's `awaiting*` case; `deliverResponse` clears the entry once
        // answered (a non-awaiting state simply opens no form, so nothing to
        // retract here).
        if let form = output.event.state?.openForm, let pending = output.pending {
            pendingRequests[form.requestID] = pending
        }

        return PluginWorkflowHook.addingEvidence(to: output.event, from: frame, nativeTurnKey: "turn_id")
    }

    /// Resolve the tmux pane for an event. On a session start with a pane,
    /// persist the correlation file so later events that only carry a session id
    /// can still be routed. When the frame omits the pane, look it up by session
    /// id from the correlation store.
    private func resolvePane(action: HookAction, frame: IngressFrame) -> String? {
        if let pane = frame.tmuxPane, !pane.isEmpty {
            if CodexTranslator.isSessionStart(action) {
                correlation.record(
                    sessionID: action.sessionId,
                    tmuxPane: pane,
                    cwd: CodexTranslator.cwd(of: action),
                    startedAt: action.timestamp ?? Date()
                )
            }
            return pane
        }
        return correlation.pane(forSessionID: action.sessionId)
    }

    // MARK: - Response delivery

    /// Translate the structured `AgentResponse` into Codex keystrokes and drive
    /// delivery through the host, then clear the retained context for the request.
    public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
        guard let host else { return }

        let pending = pendingRequests[requestID]
        let deliveries = CodexKeystrokes.deliveries(for: response, pending: pending)

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

    /// Rescan all configured CODEX_HOME roots (default + additionalConfigFolders)
    /// for rollout files and push the agent-blind project list to the host.
    public func refreshProjects() async {
        guard let host else { return }
        let projects = scanner.scan(codexHomeRoots: codexHomeRoots())
        await host.setProjects(projects)
    }

    // MARK: - Approvals-reviewer posture (issue #585)

    /// The effective reviewer posture governing this event's session. It
    /// decides permission suppression AND the chip's mode mapping (`default`
    /// → `auto` while the guardian decides approvals, PR #718).
    ///
    /// Which events resolve the posture fresh vs. reuse the session cache:
    /// - `PermissionRequest`: fresh — the suppress-or-notify decision must
    ///   track the ground truth exactly (a stale suppress eats a real prompt).
    /// - `SessionStart` / `UserPromptSubmit`: fresh — session birth and turn
    ///   boundaries are when codex (re)binds its runtime posture, so the chip
    ///   heals with at most one turn of lag after a toggle.
    /// - `PreToolUse` / `PostToolUse` / `Stop`: cached — they only feed the
    ///   permission-mode chip, and a fresh resolve per tool event would read
    ///   the whole rollout file once per tool call.
    /// - everything else: `.user` — those events carry no `permission_mode`,
    ///   so the posture is never consulted.
    private func approvalsReviewer(for action: HookAction) async -> CodexApprovalsReviewer {
        switch action {
        case let .permissionRequest(body):
            await refreshedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .sessionStart(body):
            await refreshedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .userPromptSubmit(body):
            await refreshedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .preToolUse(body):
            await cachedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .postToolUse(body):
            await cachedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .stop(body):
            await cachedPosture(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        default:
            .user
        }
    }

    private func refreshedPosture(
        sessionID: String,
        transcriptPath: String?
    ) async -> CodexApprovalsReviewer {
        let resolved = await resolvePosture(sessionID: sessionID, transcriptPath: transcriptPath)
        reviewerPostures[sessionID] = resolved
        return resolved
    }

    private func cachedPosture(
        sessionID: String,
        transcriptPath: String?
    ) async -> CodexApprovalsReviewer {
        if let cached = reviewerPostures[sessionID] {
            return cached
        }
        return await refreshedPosture(sessionID: sessionID, transcriptPath: transcriptPath)
    }

    /// One full posture resolution.
    ///
    /// The hook's `transcript_path` (the rollout file, which lives under
    /// `<CODEX_HOME>/sessions/`) attributes the session to a known root.
    /// Suppression requires positive attribution: an event with no transcript
    /// path, or one under a CODEX_HOME we don't track, resolves to `.user`.
    /// Both sides of the prefix match are symlink-resolved so `/var/…` vs
    /// `/private/var/…` spellings (or a symlinked CODEX_HOME) still match.
    ///
    /// **Primary source (codex ≥ 0.146, issue #717):** the rollout's latest
    /// `turn_context` record, which persists the session's own
    /// `approvals_reviewer` + `approval_policy` — exact per-session ground
    /// truth. It survives resumes (which fire NO SessionStart hook, so the
    /// snapshot path below can only guess from timestamps — and for a
    /// multi-day thread any config write since the rollout's birth made that
    /// guess permanently "ambiguous" → notify-noise on every
    /// guardian-approved request), and it attributes mid-session "Approve
    /// for me" toggles to the toggling session.
    ///
    /// **Fallback (older rollouts, no turn_context signal):** the root's
    /// `config.toml` read fresh (rare, human-paced, tiny file), gated by the
    /// session's start snapshot. Codex loads `config.toml` once at session
    /// start; a mid-session TUI toggle overrides only the toggling session's
    /// runtime context while persisting globally — other live sessions keep
    /// their start-time posture. So suppression requires the fresh value AND
    /// the snapshot to agree on `auto_review`; disagreement means SOME
    /// session toggled and we cannot attribute which → fail safe to `.user`
    /// (notify): a still-`user` session can never have a real prompt eaten.
    private func resolvePosture(
        sessionID: String,
        transcriptPath: String?
    ) async -> CodexApprovalsReviewer {
        guard
            let transcriptPath,
            let root = codexHomeRoot(forTranscriptPath: transcriptPath)
        else { return .user }

        if let posture = postureReader.posture(transcriptPath: transcriptPath) {
            return posture
        }

        let fresh = configReader.approvalsReviewer(codexHome: root)
        let snapshot = reviewerSnapshot(sessionID: sessionID, root: root, transcriptPath: transcriptPath)
        guard fresh == snapshot else {
            await log(
                .debug,
                "approvals_reviewer changed since session \(sessionID) started "
                    + "(config.toml says \(fresh), session started under \(snapshot)) — "
                    + "cannot attribute the toggle, notifying"
            )
            return .user
        }
        return fresh
    }

    /// Captures the session's start-time reviewer posture (what Codex itself
    /// just loaded). Re-recorded on every session start, so resumed sessions —
    /// which re-read `config.toml` — refresh their snapshot.
    private func recordReviewerSnapshot(sessionID: String, transcriptPath: String?) {
        guard
            let transcriptPath,
            let root = codexHomeRoot(forTranscriptPath: transcriptPath)
        else { return }
        reviewerSnapshots[sessionID] = configReader.approvalsReviewer(codexHome: root)
    }

    /// The session's start snapshot, reconstructing one when the session
    /// started before this app did (no SessionStart hook was seen).
    private func reviewerSnapshot(
        sessionID: String,
        root: URL,
        transcriptPath: String
    ) -> CodexApprovalsReviewer {
        if let known = reviewerSnapshots[sessionID] {
            return known
        }
        let reconstructed = reconstructedSnapshot(root: root, transcriptPath: transcriptPath)
        reviewerSnapshots[sessionID] = reconstructed
        return reconstructed
    }

    /// Reconstructs a missed start snapshot from file timestamps: if
    /// `config.toml` hasn't been modified since the session's rollout file was
    /// created, the current file value is exactly what the session loaded at
    /// startup. Otherwise — a write happened during the session's lifetime, or
    /// either file can't be dated — the posture is ambiguous → `.user`.
    private func reconstructedSnapshot(root: URL, transcriptPath: String) -> CodexApprovalsReviewer {
        let fileManager = FileManager.default
        let configPath = root.appendingPathComponent("config.toml").path
        guard
            let rolloutCreated = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[
                .creationDate
            ] as? Date,
            let configModified = (try? fileManager.attributesOfItem(atPath: configPath))?[
                .modificationDate
            ] as? Date,
            configModified < rolloutCreated
        else { return .user }
        return configReader.approvalsReviewer(codexHome: root)
    }

    /// Attributes a hook `transcript_path` to one of the tracked CODEX_HOME
    /// roots (the rollout lives under `<CODEX_HOME>/sessions/`), or nil when
    /// it belongs to none of them.
    private func codexHomeRoot(forTranscriptPath transcript: String) -> URL? {
        let transcriptPath = URL(fileURLWithPath: transcript).resolvingSymlinksInPath().path
        for root in codexHomeRoots() {
            let sessionsPrefix = root.appendingPathComponent("sessions")
                .resolvingSymlinksInPath().path + "/"
            if transcriptPath.hasPrefix(sessionsPrefix) {
                return root
            }
        }
        return nil
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
            args: provider.arguments + terminalTelemetryArguments(),
            env: provider.environment
        )
    }

    public func commandForFork(sessionID: String, projectPath: String) async throws -> AgentForkLaunch {
        try await commandForFork(sessionID: sessionID, projectPath: projectPath, targetProviderID: nil)
    }

    public func commandForFork(sessionID: String, projectPath: String, targetProviderID: String?) async throws -> AgentForkLaunch {
        guard UUID(uuidString: sessionID) != nil else { throw AgentForkError("Invalid Codex conversation ID.") }
        @Dependency(AgentForkHistoryClient.self) var history
        let root = try await history.root(sessionID, codexHomeRoots().map(\.path), .codex)
        let provider = try await providerConfiguration(targetProviderID)
        var environment = provider.environment
        // The fork must read history from the source root; Provider overrides
        // only change how the copied conversation talks to its model endpoint.
        environment["CODEX_HOME"] = root
        return AgentForkLaunch(command: LaunchCommand(
            command: settings.commandPath,
            args: ["fork", sessionID, "-C", projectPath] + provider.arguments + terminalTelemetryArguments(),
            env: environment
        ))
    }

    /// Verified with scripts/verify-workspace-agent-resume.py (idle/interrupted/approval).
    private static let verifiedResumeVersion = "codex-cli 0.162.1"

    public func recoveryDescriptor(sessionID: String, projectPath: String, invocation: AgentResumeInvocation? = nil) async throws -> AgentResumeDescriptor {
        guard UUID(uuidString: sessionID) != nil else { throw AgentForkError("Invalid Codex conversation ID.") }
        @Dependency(AgentForkHistoryClient.self) var history
        let roots: [String]
        if let invocation {
            roots = [invocation.configurationRoots["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path]
        } else {
            roots = codexHomeRoots().map(\.path)
        }
        let root = try await history.root(sessionID, roots, .codex)
        let arguments = try Self.resumeArguments(
            invocation?.arguments ?? [],
            allowsProviderOverrides: invocation?.providerID != nil
        )
        return AgentResumeDescriptor(
            pluginID: Self.pluginID,
            sessionID: sessionID,
            projectPath: projectPath,
            configurationRoot: root,
            usesDefaultConfiguration: false,
            executable: invocation?.executable,
            cliVersion: invocation?.version,
            arguments: arguments,
            automaticResumeUnavailableReason: invocation?.version == Self.verifiedResumeVersion ? nil : (invocation.map { "Automatic resume has not been verified for Codex \($0.version ?? "unknown version")." })
                ?? "The original process invocation was not recorded.",
            providerID: invocation?.providerID
        )
    }

    private static func resumeArguments(_ arguments: [String], allowsProviderOverrides: Bool = false) throws -> [String] {
        let arguments = allowsProviderOverrides ? removingProviderOverrides(arguments) : arguments
        return try AgentResumeArguments.capture(
            arguments,
            values: ["--model", "--profile", "--sandbox", "--ask-for-approval", "--add-dir", "--local-provider"],
            flags: ["--oss", "--search", "--no-alt-screen", "--no-daemon", "--strict-config", "--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"],
            ignoredValues: ["--cd", "--image"],
            ignoredFlags: ["--last", "--all", "--include-non-interactive", "--worktree"],
            aliases: ["-c": "--config", "-m": "--model", "-p": "--profile", "-s": "--sandbox", "-a": "--ask-for-approval", "-C": "--cd", "-i": "--image"],
            configKeys: ["model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "service_tier", "approval_policy", "sandbox_mode"],
            ignoredConfigPrefixes: allowsProviderOverrides ? ["model_providers.", "model_catalog_json"] : []
        )
    }

    public func commandForResume(_ descriptor: AgentResumeDescriptor) async throws -> AgentForkLaunch {
        guard
            descriptor.pluginID == Self.pluginID, UUID(uuidString: descriptor.sessionID) != nil,
            descriptor.configurationRoot.hasPrefix("/"), descriptor.projectPath.hasPrefix("/") else {
            throw AgentForkError("Invalid Codex recovery identity.")
        }
        @Dependency(AgentForkHistoryClient.self) var history
        // Only the recorded root is eligible. A changed settings list must not
        // silently resume another account's copy of the same conversation.
        let root = try await history.root(descriptor.sessionID, [descriptor.configurationRoot], .codex)
        guard try Self.resumeArguments(descriptor.arguments, allowsProviderOverrides: descriptor.providerID != nil) == descriptor.arguments else {
            throw AgentForkError("Invalid Codex recovery options.")
        }
        let provider = try await providerConfiguration(
            descriptor.providerID,
            catalogCommand: descriptor.executable
        )
        var arguments = descriptor.providerID == nil ? descriptor.arguments : Self.removingProviderOverrides(descriptor.arguments)
        // A recovered TUI owns its process lifetime; no shared daemon keeps an
        // interrupted launch running after its pane disappears.
        if descriptor.cliVersion == Self.verifiedResumeVersion, !arguments.contains("--no-daemon") {
            arguments.append("--no-daemon")
        }
        return AgentForkLaunch(command: LaunchCommand(
            command: descriptor.executable ?? settings.commandPath,
            args: ["resume", descriptor.sessionID, "-C", descriptor.projectPath] + arguments + provider.arguments + terminalTelemetryArguments(),
            env: provider.environment.merging(["CODEX_HOME": root]) { _, root in root }
        ))
    }

    // MARK: - Provider launch configuration

    private func providerConfiguration(
        _ requestedID: String?,
        catalogCommand: String? = nil
    ) async throws -> CodexProviderLaunch {
        guard let providerID = requestedID else { return CodexProviderLaunch(arguments: [], environment: [:]) }
        guard settings.providerOptions.contains(where: { $0.id == providerID }) else {
            throw AgentProviderError("The selected Codex Provider no longer exists in Settings → Agents → Codex.")
        }
        if providerID == CodexSettings.builtInProviderID {
            return CodexProviderLaunch(
                arguments: ["-c", #"model_provider="openai""#],
                environment: [AgentProviderEnvironment.markerKey: providerID]
            )
        }
        guard let profile = settings.providers.first(where: { $0.id == providerID }) else {
            throw AgentProviderError("The selected Codex Provider no longer exists in Settings → Agents → Codex.")
        }
        guard
            CodexSettings.isValidProviderID(profile.id),
            CodexSettings.isValidEnvironmentKey(profile.environmentKey),
            !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let url = URL(string: profile.baseURL), url.scheme == "http" || url.scheme == "https", url.host != nil,
            !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentProviderError("The selected Codex Provider has invalid settings. Edit it in Settings → Agents → Codex → Providers.")
        }
        let account = AgentProviderKeychainAccount.account(pluginID: Self.pluginID, providerID: profile.id)
        let apiKey: String?
        do {
            apiKey = try await secrets.loadSecret(account)
        } catch {
            throw AgentProviderError("The API key for Codex Provider '\(profile.name)' could not be read from Keychain.")
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw AgentProviderError("Add an API key for Codex Provider '\(profile.name)' in Settings → Agents → Codex → Providers.")
        }
        let prefix = "model_providers.\(profile.id)"
        var arguments = [
            "-c", "model_provider=\(Self.tomlString(profile.id))",
            "-c", "\(prefix).name=\(Self.tomlString(profile.name))",
            "-c", "\(prefix).base_url=\(Self.tomlString(profile.baseURL))",
            "-c", "\(prefix).env_key=\(Self.tomlString(profile.environmentKey))",
            "-c", #"\#(prefix).wire_api="responses""#,
            "-c", "\(prefix).requires_openai_auth=false",
        ]
        if let reasoningEffort = profile.reasoningEffort {
            arguments += ["-c", "model_reasoning_effort=\(Self.tomlString(reasoningEffort.rawValue))"]
        }
        let catalogURL = try await providerModelCatalogURL(
            for: profile,
            command: catalogCommand ?? settings.commandPath
        )
        arguments += ["-c", "model_catalog_json=\(Self.tomlString(catalogURL.path))"]
        arguments += ["--model", profile.model]
        return CodexProviderLaunch(
            arguments: arguments,
            environment: [
                profile.environmentKey: apiKey,
                AgentProviderEnvironment.markerKey: profile.id,
            ]
        )
    }

    private func providerModelCatalogURL(
        for profile: CodexProviderProfile,
        command: String
    ) async throws -> URL {
        guard let stateDirectory else {
            throw AgentProviderError("The Codex plugin state directory is unavailable.")
        }
        do {
            return try await CodexProviderModelCatalog.write(
                provider: profile,
                command: command,
                stateDirectory: stateDirectory,
                processRunner: processRunner
            )
        } catch {
            throw AgentProviderError(
                "Could not prepare /model reasoning options for Codex Provider '\(profile.name)': \(error.localizedDescription)"
            )
        }
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x09: escaped += "\\t"
            case 0x00..<0x20,
                 0x7F: escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private static func removingProviderOverrides(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--model" || value == "-m" {
                index += min(2, arguments.count - index)
                continue
            }
            if value.hasPrefix("--model=") || value.hasPrefix("-m=") {
                index += 1
                continue
            }
            if value == "--config" || value == "-c" {
                guard index + 1 < arguments.count else {
                    result.append(value)
                    index += 1
                    continue
                }
                let override = arguments[index + 1]
                if isProviderOverride(override) {
                    index += 2
                    continue
                }
                result += [value, override]
                index += 2
                continue
            }
            if let override = inlineConfigValue(value), isProviderOverride(override) {
                index += 1
                continue
            }
            result.append(value)
            index += 1
        }
        return result
    }

    private static func inlineConfigValue(_ value: String) -> String? {
        for prefix in ["--config=", "-c="] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return nil
    }

    private static func isProviderOverride(_ value: String) -> Bool {
        value.hasPrefix("model_provider=") || value.hasPrefix("model_providers.")
            || value.hasPrefix("model_catalog_json=")
    }

    /// Manual launches opt into the same telemetry as UI launches, independently
    /// of Auto-run (typing `codex` is already an explicit launch request).
    public func terminalTelemetryArguments() -> [String] {
        // Point Codex's OTLP log export at the Mac-local receiver via `-c`
        // overrides (issue #602). Gated on the per-agent `exportTelemetry`
        // setting; empty (no overrides) when off or when no receiver is running.
        settings.exportTelemetry
            ? CodexOtelConfig.launchOverrides(otlpEndpoint: otlpReceiverEndpoint)
            : []
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
        let decoded = CodexSettings.decode(from: raw)
        let foldersChanged = decoded.additionalConfigFolders != settings.additionalConfigFolders
        settings = decoded
        command = decoded.commandPath
        #if os(macOS)
            if foldersChanged {
                stopWatchers()
                startWatchers()
            }
        #endif
        return .applied
    }

    // MARK: - Private helpers

    private func cliInstaller() -> CodexCLIInstaller {
        CodexCLIInstaller(
            processRunner: processRunner,
            command: command,
            marketplaceSource: marketplaceSource
        )
    }

    /// Returns all CODEX_HOME roots to scan/watch: the default root plus any
    /// additional roots from settings.
    private func codexHomeRoots() -> [URL] {
        [CodexScanner.defaultCodexHome()] + settings.additionalConfigFolders.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    // MARK: - Session-end monitor (no Codex `SessionEnd` hook)

    #if os(macOS)
        /// Codex CLI emits no `SessionEnd` event, so the core can't learn from a
        /// hook when a session ends. Instead poll which panes still run a `codex`
        /// process and synthesize a `.sessionEnded` (via `host.emit`) for any
        /// recorded session whose process has exited — reusing the app's existing
        /// yolo-reset + pane-close handling. `host.agentPanesIfAvailable()`
        /// is only called while there are recorded sessions to watch.
        private func startSessionEndMonitor() {
            guard sessionEndMonitor == nil else { return }
            sessionEndMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(CodexPluginCore.sessionEndPollSeconds))
                    if Task.isCancelled {
                        return
                    }
                    await self?.pollSessionEnds()
                }
            }
        }

        private func stopSessionEndMonitor() {
            sessionEndMonitor?.cancel()
            sessionEndMonitor = nil
        }

        /// One monitor tick. Internal (not `private`) so tests can drive it
        /// deterministically instead of waiting on the timer.
        func pollSessionEnds() async {
            guard let host else { return }
            let known = correlation.allPanes()
            // Nothing recorded and nothing was live → skip the ps walk entirely.
            guard !known.isEmpty || !previouslyAlivePanes.isEmpty else { return }

            // Failed/unsupported introspection is not a process exit. Preserve
            // both the live baseline and first-successful-tick reconciliation.
            guard let panes = await host.agentPanesIfAvailable() else { return }
            let alive = Set(panes).intersection(known)

            // First tick after launch: a recorded pane whose process is already
            // gone is an orphan from a previous run (its session ended while we
            // were down). Drop the stale file silently — a late pane-kill now would
            // be useless and could target an unrelated, reused pane.
            if !didReconcileOrphans {
                didReconcileOrphans = true
                for orphan in known.subtracting(alive) {
                    // Correlation files only — NOT reviewer snapshots. Orphan
                    // correlations are leftovers from a PREVIOUS app run, and
                    // the in-memory snapshot map starts empty, so there is
                    // nothing of theirs to drop; a snapshot recorded since
                    // launch belongs to a live session (its pane merely has no
                    // codex process yet — e.g. synthetic E2E sessions) and
                    // must survive this reconcile.
                    correlation.remove(pane: orphan)
                }
                previouslyAlivePanes = alive
                return
            }

            let ended = previouslyAlivePanes.subtracting(alive)
            for pane in ended {
                await emitSessionEnded(pane: pane)
                removeReviewerSnapshot(pane: pane)
                correlation.remove(pane: pane)
            }
            previouslyAlivePanes = alive
        }

        /// Drops the reviewer snapshot for the session correlated to an ended
        /// pane (the snapshot map is keyed by session id; the poll only knows
        /// panes). Must run before `correlation.remove(pane:)`.
        private func removeReviewerSnapshot(pane: String) {
            guard let sessionID = correlation.record(forPane: pane)?.sessionID else { return }
            notifiedQuestionCalls.removeValue(forKey: sessionID)
            reviewerSnapshots.removeValue(forKey: sessionID)
        }

        /// Synthesize the `.sessionEnded` the missing Codex `SessionEnd` hook would
        /// have produced. `closePaneEligible` folds in the per-agent pref the same
        /// way `CodexTranslator` does for the hook path; we only emit once the
        /// process is actually gone, which is the clean-exit condition.
        private func emitSessionEnded(pane: String) async {
            guard let host else { return }
            await log(.debug, "Codex process exited; synthesizing session end for pane \(pane)")
            await host.emit(PluginEvent(
                pluginID: CodexPluginCore.pluginID,
                sessionID: pane,
                appActions: [.sessionEnded(
                    sessionID: pane,
                    closePaneEligible: settings.closePaneOnSessionEnd
                )],
                tmuxPane: pane
            ))
        }

        private func startWatchers() {
            guard watchers.isEmpty else { return }
            for root in codexHomeRoots() {
                let sessionsPath = root.appendingPathComponent("sessions").path
                let watcher = CodexSessionsWatcher(path: sessionsPath) { [weak self] in
                    Task { [weak self] in
                        await self?.refreshProjects()
                    }
                }
                watcher.start()
                watchers.append(watcher)
            }
        }

        private func stopWatchers() {
            for watcher in watchers {
                watcher.stop()
            }
            watchers = []
        }
    #endif

    private func log(_ level: LogLevel, _ message: String) async {
        // Honor the per-plugin "Log level" setting (Settings → Agents): drop lines
        // below the configured threshold instead of writing every line.
        guard level >= settings.logLevel else { return }
        await host?.log(LogLine(level: level, message: message))
    }
}

private struct CodexProviderLaunch {
    let arguments: [String]
    let environment: [String: String]
}
