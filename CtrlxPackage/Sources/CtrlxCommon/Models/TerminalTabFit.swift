import CtrlxNetworking

/// One Fit per tab entry, foreground activation or terminal focus/content click after a viewport change.
/// Geometry and Host snapshots can finish a pending measurement, but cannot schedule a resize.
public struct TerminalTabFit: Equatable, Sendable {
    public struct Target: Hashable, Sendable {
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
    private var fittedViewports: [Target: ResizeTmuxPane] = [:]

    public init() { }

    public mutating func request(_ target: Target) {
        self.target = target
    }

    public mutating func cancel() {
        target = nil
    }

    /// Terminal focus and content clicks are deduplicated. Tab/window activation must still ask the Host
    /// to check live dimensions, which another client may have changed in the meantime.
    public mutating func requestAfterViewportChange(_ target: Target, measuredRequest: ResizeTmuxPane) {
        let previous = fittedViewports[target]
        guard previous?.width != measuredRequest.width || previous?.height != measuredRequest.height else { return }
        request(target)
    }

    public mutating func recordFit(for target: Target, request: ResizeTmuxPane) {
        guard target.windowID != nil else { return }
        fittedViewports[target] = request
    }

    public mutating func invalidateFit(for target: Target) {
        fittedViewports.removeValue(forKey: target)
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
