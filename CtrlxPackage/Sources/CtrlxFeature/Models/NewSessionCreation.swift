import CtrlxCommon
import CtrlxNetworking

/// Shared by session and window creation to reconcile replies with Host snapshots.
struct NewSessionCreation: Equatable, Sendable {
    struct Destination: Equatable, Sendable {
        let hostID: String
        let sessionName: String
        let initialFit: NewSessionSizing.InitialFit?
    }

    private(set) var revision = 0
    private(set) var hostID: String?
    private(set) var paneID: String?
    private var automaticFit = false
    private var sessionBinding: ViewerWorkspaceInputBinding?
    private var createdPaneScope: WorkspaceIdentityScope?

    mutating func begin(hostID: String, automaticFit: Bool, sessionBinding: ViewerWorkspaceInputBinding? = nil) -> Int {
        cancel()
        self.hostID = hostID
        self.automaticFit = automaticFit
        self.sessionBinding = sessionBinding
        return revision
    }

    @discardableResult
    mutating func validateSessionBinding(_ current: ViewerWorkspaceInputBinding) -> Bool {
        guard let sessionBinding else { return true }
        do {
            _ = try sessionBinding.expectedPane(current: current)
            return true
        } catch {
            cancel()
            return false
        }
    }

    @discardableResult
    mutating func receivePaneID(_ paneID: String, revision: Int, createdPaneScope: WorkspaceIdentityScope? = nil) -> Bool {
        guard revision == self.revision, hostID != nil else { return false }
        self.paneID = paneID
        self.createdPaneScope = createdPaneScope
        return true
    }

    mutating func takeDestination(
        paneStates: [PaneKey: PaneState],
        isConnected: Bool,
        inputState: ViewerWorkspaceInputState? = nil
    ) -> Destination? {
        guard let hostID else { return nil }
        guard isConnected else {
            cancel()
            return nil
        }
        guard let paneID, let pane = paneStates[PaneKey(pairId: hostID, paneId: paneID)] else { return nil }
        if let inputState {
            guard let binding = inputState.createdSessionBinding(pane: pane, scope: createdPaneScope) else { return nil }
            sessionBinding = binding
        }
        let destination = Destination(
            hostID: hostID,
            sessionName: pane.sessionName,
            initialFit: automaticFit ? .init(hostID: hostID, sessionName: pane.sessionName, paneID: paneID, sessionBinding: sessionBinding) : nil
        )
        cancel()
        return destination
    }

    mutating func takeWindowDestination(
        selectedPaneID: String?,
        paneStates: [PaneKey: PaneState],
        isConnected: Bool
    ) -> Destination? {
        guard let paneID, paneID == selectedPaneID else { return nil }
        return takeDestination(paneStates: paneStates, isConnected: isConnected)
    }

    mutating func cancel() {
        revision += 1
        hostID = nil
        paneID = nil
        sessionBinding = nil
        createdPaneScope = nil
    }
}
