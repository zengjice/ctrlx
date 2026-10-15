import CtrlxCommon
import CtrlxNetworking

/// Captures routing and dimensions before asynchronous Fit execution can change the selection.
struct TerminalFitRequest {
    let hostID: String?
    let sessionName: String
    let windowTarget: String
    let columns: Int
    let rows: Int

    var target: TerminalTabFit.Target {
        .init(hostID: hostID, sessionName: sessionName, windowID: windowTarget)
    }

    var resize: ResizeTmuxPane {
        .init(width: columns, height: rows, userInitiated: true)
    }

    @MainActor
    static func perform(
        _ requests: [Self],
        willStart: (Self) -> Void,
        resize: (Self) async throws -> Void,
        didSucceed: (Self) -> Void
    ) async throws {
        // Invalidate the whole plan: an early failure also leaves later targets unfitted.
        for request in requests {
            willStart(request)
        }
        for request in requests {
            try await resize(request)
            didSucceed(request)
        }
    }
}
