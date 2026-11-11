import CtrlxNetworking
import SwiftUI

/// The Host owns the recovery journal and launch command; Viewers only present
/// the advertised choices for the currently displayed pane.
@MainActor
public struct RemoteWorkspaceRecoveryView<Content: View>: View {
    private let pane: PaneState
    private let client: ViewerRelayClient
    private let content: Content
    @State private var isRecovering = false
    @State private var error: String?

    public init(pane: PaneState, client: ViewerRelayClient, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.client = client
        self.content = content()
    }

    public var body: some View {
        if let recovery = pane.workspaceRecovery, recovery.blocksInput, pane.workspaceIdentity != nil {
            let binding = client.workspaceInputState.binding(paneID: pane.paneId)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recovery.name).fontWeight(.medium)
                    Text(recovery.reason).foregroundStyle(.secondary).textSelection(.enabled)
                    ViewThatFits {
                        HStack { actions(recovery, binding: binding) }
                        VStack(alignment: .leading) { actions(recovery, binding: binding) }
                    }
                    .disabled(isRecovering || !recovery.isReady || !client.isHostConnected)
                    if isRecovering {
                        ProgressView()
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    @ViewBuilder
    private func actions(_ recovery: WorkspacePaneRecovery, binding: ViewerWorkspaceInputBinding) -> some View {
        if recovery.canRetry {
            Button("Retry") { recover(.useShell, state: recovery, binding: binding) }
        }
        if recovery.canResume {
            Button("Resume") { recover(.resume, state: recovery, binding: binding) }
        }
        if recovery.canUseShell {
            Button(recovery.keepCurrentTerminal ? "Keep terminal" : "Use Shell") {
                recover(.useShell, state: recovery, binding: binding)
            }
        }
    }

    private func recover(_ action: RecoverWorkspacePane.Action, state: WorkspacePaneRecovery, binding: ViewerWorkspaceInputBinding) {
        guard !isRecovering else { return }
        let request = RecoverWorkspacePane(paneID: pane.paneId, recovery: state, action: action)
        isRecovering = true
        error = nil
        Task {
            defer { isRecovering = false }
            do {
                _ = try await client.sendCommand(request, paneId: request.paneID, timeout: 30, inputBinding: binding).get()
            } catch {
                self.error = error.localizedDescription
            }
            await client.requestSessionState()
        }
    }
}
