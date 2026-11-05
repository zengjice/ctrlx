import CtrlxNetworking
import SwiftUI

/// Uses the Host's workflow state; toggling affects all participants in the run.
@MainActor
public struct AgentWorkflowControlButton: View {
    let endpoint: AgentWorkflowEndpoint
    let pane: WorkspacePaneIdentity
    @Environment(\.scenePhase) private var scenePhase
    @State private var run: AgentWorkflowRunState?
    @State private var hostID: UUID?
    @State private var changing = false
    @State private var unavailableReason: String?
    @State private var error: String?

    public init(endpoint: AgentWorkflowEndpoint, pane: WorkspacePaneIdentity) {
        self.endpoint = endpoint
        self.pane = pane
    }

    public var body: some View {
        Group {
            if let run, !run.summary.status.isTerminal {
                let paused = run.summary.status == .paused
                let title = paused ? "Continue workflow" : "Pause workflow"
                Button(action: change) {
                    Label(title, symbol: paused ? .play : .pause)
                        .labelStyle(.iconOnly)
                }
                .disabled(changing || unavailableReason != nil || !endpoint.isConnected || !endpoint.isSupported)
                .help(title)
                .accessibilityValue(run.summary.status.title)
                .accessibilityIdentifier("workflow-terminal-control")
            }
        }
        .task(id: "\(endpoint.id):\(pane.serverID):\(pane.paneID):\(scenePhase):\(endpoint.isConnected)") {
            run = nil
            hostID = nil
            guard scenePhase == .active, endpoint.isSupported, endpoint.isConnected else { return }
            while !Task.isCancelled {
                if !changing {
                    do {
                        let response = try await endpoint.request(.terminal(pane), hostID: hostID)
                        try Task.checkCancellation()
                        hostID = response.hostID
                        run = response.run
                        unavailableReason = nil
                    } catch {
                        if Task.isCancelled {
                            return
                        }
                        unavailableReason = error.localizedDescription
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .alert("Workflow control", isPresented: Binding(get: { error != nil }, set: {
            if !$0 {
                error = nil
            }
        })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func change() {
        guard !changing, let hostID else { return }
        let paused = run?.summary.status != .paused
        changing = true
        Task {
            defer { changing = false }
            do {
                run = try await endpoint.setWorkflowPaused(paused, pane: pane, hostID: hostID)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension AgentWorkflowEndpoint {
    func setWorkflowPaused(_ paused: Bool, pane: WorkspacePaneIdentity, hostID: UUID) async throws -> AgentWorkflowRunState? {
        let current = try await request(.terminal(pane), hostID: hostID)
        guard let state = current.run, !state.summary.status.isTerminal else { return nil }
        // Another operator may already have applied the same intent. A stale
        // button must not turn a pause click into an unintended resume.
        if (state.summary.status == .paused) == paused {
            return state
        }
        let operation: ManageAgentWorkflows.Operation = paused
            ? .pause(state.summary.id, expectedRevision: state.summary.revision)
            : .resume(state.summary.id, expectedRevision: state.summary.revision, roundLimit: nil)
        return try await request(operation, hostID: hostID).run
    }
}
