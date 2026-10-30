import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Logging

private let modelLogger = Logger(label: "com.jicezeng.ctrlx.agent-models")

struct AgentModelRuntimeCache {
    let runtimeID: String
    let models: [AgentModelOption]
    var selection: AgentModelSelection?
    var inputGeneration: UInt64?
    var unavailableReason: String?
    var catalogWarning: String?
}

extension AppCoordinator {
    func handleAgentModels(_ request: AgentModelControls, paneID: String) async throws -> AgentModelSnapshot {
        let start = ContinuousClock.now
        do {
            let value: AgentModelSnapshot
            if request.selection == nil {
                value = try await agentModelReads.read(paneID: paneID, identity: request.workspacePane, refresh: request.refresh) { [self] in
                    try await performAgentModels(request, paneID: paneID)
                }
            } else {
                try await agentModelReads.waitForRead(paneID: paneID, identity: request.workspacePane)
                value = try await performAgentModels(request, paneID: paneID)
            }
            recordAgentModelDiagnostic(paneID: paneID, phase: request.selection == nil ? "read" : "switch", since: start)
            return value
        } catch {
            recordAgentModelDiagnostic(paneID: paneID, phase: "request-failed", since: start, failure: error.localizedDescription)
            throw error
        }
    }

    func recordAgentModelDiagnostic(paneID: String, phase: String, since start: ContinuousClock.Instant, failure: String? = nil) {
        guard settings.debugModeEnabled else { return }
        modelLogger.info("Model controls", metadata: [
            "pane": "\(paneID)", "phase": "\(phase)",
            "elapsed": "\(ContinuousClock.now - start)", "error": "\(failure ?? "none")",
        ])
    }

    private func performAgentModels(_ request: AgentModelControls, paneID: String) async throws -> AgentModelSnapshot {
        @Dependency(AgentSessionIdentityClient.self) var identities
        let identityClient = identities
        @Dependency(WorkspaceAgentProcessClient.self) var processes
        guard !agentModelRequests.contains(paneID) else { throw AgentModelError("Model controls are refreshing. Try again shortly.") }
        agentModelRequests.insert(paneID)
        defer { agentModelRequests.remove(paneID) }
        let identifyStart = ContinuousClock.now
        guard
            let registry = pluginRegistry,
            let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: request.selection != nil || request.refresh),
            let candidate = detected[paneID], candidate.processIDs.count == 1,
            let pid = candidate.processIDs.first, let runtime = identityClient.runtimeID(pid),
            let provider = registry.core(candidate.pluginID) as? any AgentModelProviding else {
            throw AgentModelError("No supported Agent is running in the selected pane.")
        }
        let captured = try await tmuxService.captureWorkspacePane(target: paneID)
        recordAgentModelDiagnostic(paneID: paneID, phase: "identify", since: identifyStart)
        guard captured.identity.isSamePane(as: request.workspacePane) else { throw AgentModelError("The terminal changed. Reopen this tab's model controls.") }
        if request.selection != nil, request.runtimeID != runtime {
            throw AgentModelError("The Agent restarted. Refresh its model controls.")
        }
        var cache = agentModelCatalogs[paneID]
        if cache?.runtimeID != runtime || request.refresh {
            let catalogStart = ContinuousClock.now
            do {
                let context = try await processes.modelContext(pid, runtime, captured.info.currentPath, provider.modelDiscoveryCommand)
                if let issue = provider.modelRuntimeIssue(context) {
                    if cache?.runtimeID == runtime, cache?.models.isEmpty == false {
                        throw AgentModelError(issue)
                    }
                    cache = AgentModelRuntimeCache(runtimeID: runtime, models: [], unavailableReason: issue)
                } else {
                    let models = try await provider.modelOptions(context)
                    cache = AgentModelRuntimeCache(runtimeID: runtime, models: models)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard cache?.runtimeID == runtime, cache?.models.isEmpty == false, identityClient.runtimeID(pid) == runtime else { throw error }
                cache?.catalogWarning = "Could not refresh models; using this session's previous list. \(error.localizedDescription)"
                recordAgentModelDiagnostic(paneID: paneID, phase: "catalog-refresh-failed", since: catalogStart, failure: error.localizedDescription)
            }
            guard identityClient.runtimeID(pid) == runtime else { throw AgentModelError("The Agent restarted during model discovery.") }
            // Keep a successful catalog even if the following terminal read fails.
            agentModelCatalogs = agentModelCatalogs.filter { windowManager.paneStates[$0.key] != nil }
            agentModelCatalogs[paneID] = cache
            recordAgentModelDiagnostic(paneID: paneID, phase: "catalog", since: catalogStart)
        }
        guard var cache else { throw AgentModelError("Model discovery did not finish.") }
        if let reason = cache.unavailableReason {
            if request.selection != nil {
                throw AgentModelError(reason)
            }
            return AgentModelSnapshot(runtimeID: runtime, models: [], selection: nil, unavailableReason: reason)
        }
        let models = cache.models
        let captureStart = ContinuousClock.now
        let screen = try await tmuxService.captureAgentTerminal(paneID: paneID, identity: request.workspacePane)
        guard identityClient.runtimeID(pid) == runtime else { throw AgentModelError("The Agent restarted while reading its model selection.") }
        recordAgentModelDiagnostic(paneID: paneID, phase: "terminal", since: captureStart)
        let generation = tmuxService.workflowInputGate?.claim(paneID: paneID).generation
        if cache.inputGeneration != generation {
            cache.selection = nil
        }
        if let current = provider.modelSelection(lines: screen.plainLines, models: models) {
            // A missing effort is unknown; never borrow it from last-turn telemetry.
            cache.selection = current
        }
        let reason = agentModelInputIssue(paneID: paneID, screen: screen, provider: provider, models: models)
        if let selection = request.selection {
            guard reason == nil else { throw AgentModelError(reason ?? "The terminal is not ready.") }
            guard let gate = tmuxService.workflowInputGate else { throw AgentModelError("The terminal input queue is not ready.") }
            cache.selection = try await gate.human(paneID: paneID) { [self] in
                let claim = gate.claim(paneID: paneID)
                let current = try await tmuxService.captureAgentTerminal(paneID: paneID, identity: request.workspacePane)
                if let issue = agentModelInputIssue(paneID: paneID, screen: current, provider: provider, models: models) {
                    throw AgentModelError(issue)
                }
                if
                    let expected = request.expectedSelection,
                    let live = provider.modelSelection(lines: current.plainLines, models: models),
                    live.model != expected.model || (live.effort != nil && expected.effort != nil && live.effort != expected.effort) {
                    throw AgentModelError("The model selection changed. Refresh before switching again.")
                }
                let terminal = AgentModelTerminal(
                    read: { [self] in
                        try await MainActor.run {
                            try gate.validate(claim)
                            guard identityClient.runtimeID(pid) == runtime else { throw AgentModelError("The Agent process changed.") }
                        }
                        return try await tmuxService.captureAgentTerminal(paneID: paneID, identity: request.workspacePane).plainLines
                    },
                    submit: { [self] command in
                        try await submitAgentModelCommand(command, paneID: paneID, identity: request.workspacePane, processID: pid, runtimeID: runtime, provider: provider, models: models, gate: gate, claim: claim)
                    },
                    send: { [self] keys in
                        try await sendAgentModelKeys(keys, paneID: paneID, identity: request.workspacePane, processID: pid, runtimeID: runtime, gate: gate, claim: claim)
                    }
                )
                // Recheck the composer immediately before entering the sequence.
                try gate.validate(claim)
                guard identityClient.runtimeID(pid) == runtime else { throw AgentModelError("The Agent process changed.") }
                do {
                    let confirmed = try await provider.selectModel(selection, models: models, terminal: terminal)
                    try gate.validate(claim)
                    return confirmed
                } catch {
                    // Human input is still waiting in the shared queue. Close
                    // only our recognized picker before releasing it, so a
                    // queued Return cannot save a global model default.
                    if
                        identityClient.runtimeID(pid) == runtime,
                        let screen = try? await tmuxService.captureAgentTerminal(paneID: paneID, identity: request.workspacePane),
                        provider.isModelPicker(lines: screen.plainLines, models: models) {
                        _ = try await tmuxService.runWorkspaceCommand([["send-keys", "-t", paneID, "Escape"]], target: paneID, identity: request.workspacePane) { launch in
                            guard identityClient.runtimeID(pid) == runtime else { throw AgentModelError("The Agent process changed.") }
                            try launch()
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    throw error
                }
            }
        }
        cache.inputGeneration = tmuxService.workflowInputGate?.claim(paneID: paneID).generation
        agentModelCatalogs = agentModelCatalogs.filter { windowManager.paneStates[$0.key] != nil }
        agentModelCatalogs[paneID] = cache
        return AgentModelSnapshot(runtimeID: runtime, models: models, selection: cache.selection, unavailableReason: reason, catalogWarning: cache.catalogWarning)
    }

    private func submitAgentModelCommand(
        _ command: String, paneID: String, identity: WorkspacePaneIdentity,
        processID: String, runtimeID: String, provider: any AgentModelProviding, models: [AgentModelOption],
        gate: AgentWorkflowInputGate, claim: AgentWorkflowInputGate.Claim
    ) async throws {
        @Dependency(AgentSessionIdentityClient.self) var identities
        let identityClient = identities
        let screen = try await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity)
        if let issue = agentModelInputIssue(paneID: paneID, screen: screen, provider: provider, models: models) {
            throw AgentModelError(issue)
        }
        let bytes = try AgentModelTerminal.commandBytes(command)
        // Bracketed paste and Return share one write, leaving no half-command
        // for newly queued human input to join.
        let input = ["send-keys", "-t", paneID, "-H"] + bytes.map { String(format: "%02x", $0) }
        let conditions = [
            "#{bracket_paste_flag}", "#{==:#{pane_in_mode},0}",
            "#{==:#{cursor_x},\(screen.cursorX)}", "#{==:#{cursor_y},\(screen.cursorY)}",
            "#{==:#{pane_width},\(screen.width)}", "#{==:#{pane_height},\(screen.height)}",
        ]
        let condition = conditions.dropFirst().reduce(conditions[0]) { "#{&&:\($0),\($1)}" }
        let result = try await tmuxService.runWorkspaceCommand([
            ["if-shell", "-F", "-t", paneID, condition, input.map(\.posixSingleQuoted).joined(separator: " "), "display-message -p ctrlx-model-input-changed"],
        ], target: paneID, identity: identity) { launch in
            try gate.validate(claim)
            guard identityClient.runtimeID(processID) == runtimeID else { throw AgentModelError("The Agent process changed before input was sent.") }
            try launch()
        }
        guard !result.stdoutString.contains("ctrlx-model-input-changed") else { throw AgentModelError("The terminal input changed. Nothing was sent.") }
    }

    func agentModelInputIssue(paneID: String, screen: AgentWorkflowTerminalCapture, provider: any AgentModelProviding, models: [AgentModelOption]) -> String? {
        guard screen.bracketedPaste != nil else {
            return "Model switching requires tmux 3.7 or newer on the Host. Upgrade the running tmux server, or use /model in this terminal."
        }
        guard let pane = windowManager.paneStates[paneID], pane.agentSession != nil else { return "The Agent is not ready." }
        if pane.agentSession?.state.openForm != nil {
            return "Answer the Agent's question or permission request first."
        }
        if pane.agentSession?.state.isActiveWorking == true {
            return "Wait for the Agent to finish before switching models."
        }
        let lines = screen.plainLines
        let first = max(0, screen.cursorY - 8)
        let last = min(lines.count, screen.cursorY + 4)
        if first < last, lines[first..<last].contains(where: { $0.localizedCaseInsensitiveContains("esc to interrupt") || $0.localizedCaseInsensitiveContains("esc to stop") }) {
            return "Wait for the Agent to finish before switching models."
        }
        if pane.editorSession != nil || !recoveredWorkspaceDrafts.localDrafts(paneID: paneID).isEmpty {
            return "Finish or clear the input draft before switching models."
        }
        guard AgentWorkflowComposerInspection.readiness(screen, composer: provider.modelComposer) == .ready else {
            return "Switch models when the Agent is idle and its input is empty."
        }
        return provider.modelSwitchIssue(lines: lines, models: models)
    }

    private func sendAgentModelKeys(
        _ keys: [TmuxKey], paneID: String, identity: WorkspacePaneIdentity,
        processID: String, runtimeID: String, gate: AgentWorkflowInputGate, claim: AgentWorkflowInputGate.Claim
    ) async throws {
        @Dependency(AgentSessionIdentityClient.self) var identities
        let identityClient = identities
        for key in keys {
            try Task.checkCancellation()
            try gate.validate(claim)
            guard identityClient.runtimeID(processID) == runtimeID else { throw AgentModelError("The Agent process changed.") }
            if case let .delay(milliseconds) = key {
                try await Task.sleep(for: .milliseconds(milliseconds))
                continue
            }
            let arguments: [String]
            if case let .text(text) = key {
                arguments = ["send-keys", "-t", paneID, "-l", "--", text]
            } else {
                arguments = ["send-keys", "-t", paneID, key.tmuxKeyName]
            }
            _ = try await tmuxService.runWorkspaceCommand([arguments], target: paneID, identity: identity) { launch in
                try gate.validate(claim)
                guard identityClient.runtimeID(processID) == runtimeID else { throw AgentModelError("The Agent process changed before input was sent.") }
                try launch()
            }
        }
    }
}
