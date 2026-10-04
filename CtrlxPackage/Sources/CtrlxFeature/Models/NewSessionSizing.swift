import CtrlxNetworking

enum NewSessionSizing {
    static let fallbackGrid = TerminalViewportSizing.Grid(columns: 120, rows: 40)

    static func automaticFit(savedPreference: Bool?, width: Int, height: Int) -> Bool {
        savedPreference ?? (width == fallbackGrid.columns && height == fallbackGrid.rows)
    }

    static func creationGrid(automaticFit: Bool, width: Int, height: Int) -> TerminalViewportSizing.Grid {
        automaticFit ? fallbackGrid : .init(columns: width, rows: height)
    }

    /// Owned by the session list, so rebuilding or revisiting a destination
    /// cannot restore permission to resize a created terminal after its first fit.
    struct InitialFit: Equatable, Sendable {
        let hostID: String
        let sessionName: String
        private(set) var paneID: String?

        init(hostID: String, sessionName: String, paneID: String) {
            self.hostID = hostID
            self.sessionName = sessionName
            self.paneID = paneID
        }

        func matches(hostID: String, sessionName: String) -> Bool {
            self.hostID == hostID && self.sessionName == sessionName && paneID != nil
        }

        mutating func takeRequest(
            isAvailable: Bool,
            paneIDs: [String]?,
            measuredRequest: ResizeTmuxPane?,
            isPresentationReady: Bool = true
        ) -> ResizeTmuxPane? {
            guard let paneID else { return nil }
            guard isAvailable else {
                self.paneID = nil
                return nil
            }
            guard let paneIDs else { return nil }
            // A manual window switch or split before measurement cancels the fit.
            guard paneIDs == [paneID] else {
                self.paneID = nil
                return nil
            }
            guard isPresentationReady, let measuredRequest else { return nil }
            self.paneID = nil
            return measuredRequest
        }

        mutating func cancel(hostID: String, sessionName: String) {
            guard matches(hostID: hostID, sessionName: sessionName) else { return }
            paneID = nil
        }
    }
}
