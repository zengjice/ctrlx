import CtrlxNetworking
import SwiftUI

public struct WorkflowPaneStatusLabel: View {
    public let status: AgentWorkflowPaneStatus

    public init(status: AgentWorkflowPaneStatus) {
        self.status = status
    }

    private var symbol: Symbols {
        switch status.status {
        case .completed: .checkmarkCircleFill
        case .ended: .stopCircleFill
        case .paused: status.needsAttention ? .exclamationmarkTriangle : .pause
        case .running,
             .finishing: .flowchart
        }
    }

    public var body: some View {
        Label("Workflow · \(status.title) · \(status.detail)", symbol: symbol)
            .font(.caption)
            .foregroundStyle(status.status == .completed ? Color.green : .secondary)
            .lineLimit(2)
            .accessibilityIdentifier("workflow-pane-status")
    }
}

/// Uses the Host's workflow state; toggling affects all participants in the run.
@MainActor
public struct AgentWorkflowControlButton: View {
    let endpoint: AgentWorkflowEndpoint
    let pane: WorkspacePaneIdentity
    private let openRun: ((AgentWorkflowNotificationTarget) -> Void)?
    @Environment(\.agentWorkflowNavigation) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var run: AgentWorkflowRunState?
    @State private var hostID: UUID?
    @State private var loadedKey: String?
    @State private var changing = false
    @State private var unavailableReason: String?
    @State private var error: String?
    @State private var authorizationRun: AgentWorkflowRunState?

    public init(endpoint: AgentWorkflowEndpoint, pane: WorkspacePaneIdentity, openRun: ((AgentWorkflowNotificationTarget) -> Void)? = nil) {
        self.endpoint = endpoint
        self.pane = pane
        self.openRun = openRun
    }

    public var body: some View {
        Group {
            if let run, let hostID {
                WorkflowTerminalStatus(run: run, hostID: hostID, offline: !endpoint.isConnected) {
                    let target = AgentWorkflowNotificationTarget(hostID: hostID, runID: run.summary.id, eventID: run.notification?.id ?? run.summary.id)
                    if let openRun {
                        openRun(target)
                    } else {
                        navigation?.open(target, route: endpoint.id)
                    }
                }
            }
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
            let key = "\(endpoint.id):\(pane.serverID):\(pane.paneID)"
            if loadedKey != key {
                run = nil
                hostID = nil
                loadedKey = key
            }
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
        .sheet(isPresented: Binding(get: { authorizationRun != nil }, set: {
            if !$0 {
                authorizationRun = nil
            }
        })) {
            if let target = authorizationRun, let hostID {
                AgentWorkflowAuthorizationSheet(canSubmit: !changing && endpoint.isConnected, cancel: {
                    authorizationRun = nil
                }, confirm: { expiresAt in
                    authorizationRun = nil
                    changing = true
                    Task {
                        defer { changing = false }
                        do {
                            run = try await endpoint.request(.renewAndResume(target.summary.id, expectedRevision: target.summary.revision, roundLimit: nil, authorizationExpiresAt: expiresAt), hostID: hostID).run
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                })
            }
        }
    }

    private func change() {
        guard !changing, let hostID else { return }
        if let run, run.summary.status == .paused, run.summary.authorizationExpiresAt <= Date() {
            authorizationRun = run
            return
        }
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

@MainActor
private struct WorkflowTerminalStatus: View {
    let run: AgentWorkflowRunState
    let offline: Bool
    let open: () -> Void
    @AppStorage private var viewedCompletion: Bool

    init(run: AgentWorkflowRunState, hostID: UUID, offline: Bool, open: @escaping () -> Void) {
        self.run = run
        self.offline = offline
        self.open = open
        self._viewedCompletion = AppStorage(wrappedValue: false, "workflow-viewed-\(hostID)-\(run.summary.id)")
    }

    private var symbol: Symbols {
        switch run.summary.status {
        case .completed: .checkmarkCircleFill
        case .ended: .stopCircleFill
        case .paused: run.notification == nil ? .pause : .exclamationmarkTriangle
        case .running,
             .finishing: .flowchart
        }
    }

    var body: some View {
        Button(action: open) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(offline ? "Workflow · Offline" : "Workflow · \(run.progressTitle)")
                        .font(.caption.weight(.medium))
                    Text("\(run.summary.name) · \(run.progressDetail)")
                        .font(.caption2).lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
            } icon: { symbol.image }
        }
        .buttonStyle(.plain)
        .foregroundStyle(run.summary.status == .completed && !viewedCompletion ? Color.green : Color.secondary)
        .help("\(run.summary.name) · \(run.progressDetail)")
        .accessibilityLabel("\(run.summary.name) · \(run.progressDetail)")
        .accessibilityIdentifier("workflow-terminal-status")
    }
}

public extension AgentWorkflowRunState {
    var progressTitle: String {
        if summary.status == .paused, let notification {
            return notification.approvalRequestID == nil ? "Needs attention" : "Needs approval"
        }
        if
            !summary.status.isTerminal, summary.status != .paused,
            nodes.contains(where: { [.uncertain, .awaitingAcceptance].contains($0.invocation?.status) }) {
            return "Verifying"
        }
        return summary.status.title
    }

    var progressDetail: String {
        let steps = nodes.filter { $0.invocation?.status == .running || $0.invocation?.status == .uncertain || $0.invocation?.status == .awaitingAcceptance }.map(\.name)
        return ([progressTitle, "Round \(summary.round)/\(summary.roundLimit)"] + steps).joined(separator: " · ")
    }
}
