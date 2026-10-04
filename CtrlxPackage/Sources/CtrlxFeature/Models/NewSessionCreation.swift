import CtrlxCommon
import CtrlxNetworking

/// Keeps the creation reply and Host snapshot independent of their arrival order.
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

    mutating func begin(hostID: String, automaticFit: Bool) -> Int {
        cancel()
        self.hostID = hostID
        self.automaticFit = automaticFit
        return revision
    }

    @discardableResult
    mutating func receivePaneID(_ paneID: String, revision: Int) -> Bool {
        guard revision == self.revision, hostID != nil else { return false }
        self.paneID = paneID
        return true
    }

    mutating func takeDestination(
        paneStates: [PaneKey: PaneState],
        isConnected: Bool
    ) -> Destination? {
        guard let hostID else { return nil }
        guard isConnected else {
            cancel()
            return nil
        }
        guard let paneID, let pane = paneStates[PaneKey(pairId: hostID, paneId: paneID)] else { return nil }
        let destination = Destination(
            hostID: hostID,
            sessionName: pane.sessionName,
            initialFit: automaticFit ? .init(hostID: hostID, sessionName: pane.sessionName, paneID: paneID) : nil
        )
        cancel()
        return destination
    }

    mutating func cancel() {
        revision += 1
        hostID = nil
        paneID = nil
    }
}
