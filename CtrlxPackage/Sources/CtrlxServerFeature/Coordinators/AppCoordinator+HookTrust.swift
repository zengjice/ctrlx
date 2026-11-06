import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func handleTrustAgentHooks(_ request: TrustAgentHooks, paneID: String) async throws -> AgentHookTrustResult {
        @Dependency(AgentSessionIdentityClient.self) var identities
        let identityClient = identities
        guard !agentHookTrustRequests.contains(paneID) else {
            throw AgentHookTrustError("Hook approval is already in progress.")
        }
        agentHookTrustRequests.insert(paneID)
        defer { agentHookTrustRequests.remove(paneID) }
        guard
            let registry = pluginRegistry,
            let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true),
            let candidate = detected[paneID], candidate.processIDs.count == 1,
            let pid = candidate.processIDs.first, let runtime = identityClient.runtimeID(pid),
            let provider = registry.core(candidate.pluginID) as? any AgentHookTrustProviding,
            let gate = tmuxService.workflowInputGate else {
            throw AgentHookTrustError("No supported Agent is ready in this pane.")
        }
        let identity = request.workspacePane
        return try await gate.human(paneID: paneID) { [self] in
            let claim = gate.claim(paneID: paneID)
            let terminal = AgentHookTrustTerminal(read: { [self] in
                try await MainActor.run {
                    try gate.validate(claim)
                    guard identityClient.runtimeID(pid) == runtime else { throw AgentHookTrustError("The Agent process changed.") }
                }
                return try await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity).plainLines
            }, perform: { [self] action in
                try await performHookTrustAction(action, paneID: paneID, identity: identity, processID: pid, runtimeID: runtime, provider: provider, gate: gate, claim: claim)
            })
            do {
                let result = try await provider.trustHooks(terminal: terminal, refreshIfTrusted: request.refreshIfTrusted == true)
                try gate.validate(claim)
                guard identityClient.runtimeID(pid) == runtime else { throw AgentHookTrustError("The Agent process changed.") }
                return result
            } catch {
                // A newer human claim is still queued behind us. Close our
                // recognized panel before releasing it, so Return cannot toggle
                // a hook. With no queued input, keep failed restoration visible.
                if (error as? AgentHookTrustError)?.preservePanel != true || gate.claim(paneID: paneID).generation != claim.generation {
                    await closeHookTrustPanels(paneID: paneID, identity: identity, processID: pid, runtimeID: runtime, provider: provider)
                }
                throw error
            }
        }
    }

    private func closeHookTrustPanels(paneID: String, identity: WorkspacePaneIdentity, processID: String, runtimeID: String, provider: any AgentHookTrustProviding) async {
        @Dependency(AgentSessionIdentityClient.self) var identities
        for _ in 0..<2 {
            guard
                identities.runtimeID(processID) == runtimeID,
                let screen = try? await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity) else { return }
            let isDetail = provider.hookTrustAllows(.back, lines: screen.plainLines)
            guard isDetail || provider.hookTrustPanel(lines: screen.plainLines) != nil else { return }
            let result = try? await tmuxService.runWorkspaceCommand([["send-keys", "-t", paneID, "Escape"]], target: paneID, identity: identity) { launch in
                guard identities.runtimeID(processID) == runtimeID else { throw AgentHookTrustError("The Agent process changed.") }
                try launch()
            }
            guard result != nil else { return }
            for _ in 0..<30 {
                guard
                    identities.runtimeID(processID) == runtimeID,
                    let current = try? await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity) else { return }
                if isDetail ? provider.hookTrustPanel(lines: current.plainLines) != nil : AgentWorkflowComposerInspection.readiness(current, composer: provider.hookTrustComposer, allowUnknownBracketedPaste: true) == .ready {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func hookTrustInputIssue(paneID: String, screen: AgentWorkflowTerminalCapture, composer: AgentWorkflowComposer, nativeTurnCompleted: Bool = false) -> String? {
        guard let pane = windowManager.paneStates[paneID], pane.agentSession != nil else { return "The Agent is not ready." }
        guard pane.agentSession?.state.openForm == nil else { return "Answer the Agent's pending request first." }
        guard pane.agentSession?.state.isActiveWorking != true || nativeTurnCompleted else {
            return "The running conversation's completed turn could not be verified. Wait for the Agent to finish, or use /hooks in its terminal."
        }
        let nearby = screen.plainLines.dropFirst(max(0, screen.cursorY - 8)).prefix(12)
        guard !nearby.contains(where: { $0.localizedCaseInsensitiveContains("esc to interrupt") || $0.localizedCaseInsensitiveContains("esc to stop") }) else {
            return "Wait for the Agent to finish before approving hooks."
        }
        guard pane.editorSession == nil, recoveredWorkspaceDrafts.localDrafts(paneID: paneID).isEmpty else {
            return "Finish or clear the input draft before approving hooks."
        }
        guard AgentWorkflowComposerInspection.readiness(screen, composer: composer, allowUnknownBracketedPaste: true) == .ready else {
            return "Approve hooks when the Agent is idle and its input is empty."
        }
        return nil
    }

    private func performHookTrustAction(
        _ action: AgentHookTrustAction, paneID: String, identity: WorkspacePaneIdentity,
        processID: String, runtimeID: String, provider: any AgentHookTrustProviding,
        gate: AgentWorkflowInputGate, claim: AgentWorkflowInputGate.Claim
    ) async throws {
        @Dependency(AgentSessionIdentityClient.self) var identities
        let identityClient = identities
        try Task.checkCancellation()
        try gate.validate(claim)
        var nativeTurnCompleted = false
        if action == .open, windowManager.paneStates[paneID]?.agentSession?.state.isActiveWorking == true {
            @Dependency(CodexHookTrustIdleClient.self) var idle
            nativeTurnCompleted = await idle.isIdle(processID, runtimeID)
            try Task.checkCancellation()
            try gate.validate(claim)
            guard identityClient.runtimeID(processID) == runtimeID else { throw AgentHookTrustError("The Agent process changed.") }
        }
        let screen = try await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity)
        if action == .open {
            if let issue = hookTrustInputIssue(paneID: paneID, screen: screen, composer: provider.hookTrustComposer, nativeTurnCompleted: nativeTurnCompleted) {
                throw AgentHookTrustError(issue)
            }
        }
        let commands = try AgentHookTrustTmuxSubmission.commands(action, paneID: paneID, capture: screen, provider: provider)
        let result = try await tmuxService.runWorkspaceCommand(commands, target: paneID, identity: identity) { launch in
            try gate.validate(claim)
            guard identityClient.runtimeID(processID) == runtimeID else { throw AgentHookTrustError("The Agent process changed before input was sent.") }
            try gate.perform(claim, write: launch)
        }
        guard !result.stdoutString.contains(AgentHookTrustTmuxSubmission.rejection) else { throw AgentHookTrustError("The terminal input changed. Nothing was sent.") }
        if action == .close {
            for _ in 0..<30 {
                try Task.checkCancellation()
                try gate.validate(claim)
                guard identityClient.runtimeID(processID) == runtimeID else { throw AgentHookTrustError("The Agent process changed.") }
                let current = try await tmuxService.captureAgentTerminal(paneID: paneID, identity: identity)
                if AgentWorkflowComposerInspection.readiness(current, composer: provider.hookTrustComposer, allowUnknownBracketedPaste: true) == .ready {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AgentHookTrustError("Codex did not return to its input. Check the terminal.")
        }
    }
}
