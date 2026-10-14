import CtrlxNetworking

/// One Fit per tab entry or foreground activation. Geometry and Host snapshots can finish a
/// pending measurement, but cannot schedule another resize.
public struct TerminalTabFit: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public let hostID: String?
        public let sessionName: String
        public let windowID: String?

        public init(hostID: String?, sessionName: String, windowID: String? = nil) {
            self.hostID = hostID
            self.sessionName = sessionName
            self.windowID = windowID
        }
    }

    public private(set) var target: Target?

    public init() { }

    public mutating func request(_ target: Target) {
        self.target = target
    }

    public mutating func cancel() {
        target = nil
    }

    public mutating func takeRequest(
        for current: Target,
        isAvailable: Bool,
        isPresentationReady: Bool,
        measuredRequest: ResizeTmuxPane?
    ) -> ResizeTmuxPane? {
        guard let target else { return nil }
        guard target.hostID == current.hostID, target.sessionName == current.sessionName else {
            cancel()
            return nil
        }
        // Selecting a remote tab may precede the Host's active-window snapshot.
        guard
            isAvailable,
            current.windowID != nil,
            target.windowID == nil || target.windowID == current.windowID,
            isPresentationReady, let measuredRequest else { return nil }
        cancel()
        // Host checks live tmux dimensions; a matching client snapshot may be stale.
        return measuredRequest
    }
}
