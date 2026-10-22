import CtrlxCommon
import CtrlxNetworking

/// Captures routing and dimensions before asynchronous Fit execution can change the selection.
struct TerminalFitRequest {
    let hostID: String?
    let sessionName: String
    let windowTarget: String
    let columns: Int
    let rows: Int
    var workspaceScope: WorkspaceIdentityScope?
    var inputBinding: ViewerWorkspaceInputBinding?
    var workspacePane: WorkspacePaneIdentity?

    var target: TerminalTabFit.Target {
        .init(hostID: hostID, sessionName: sessionName, windowID: windowTarget)
    }

    var resize: ResizeTmuxPane {
        .init(width: columns, height: rows, userInitiated: true)
    }

    @MainActor
    static func perform(
        _ requests: [Self],
        isCurrent: (Self) -> Bool = { _ in true },
        willStart: (Self) -> Void,
        resize: (Self) async throws -> Void,
        didSucceed: (Self) -> Void
    ) async throws {
        // Invalidate the whole plan: an early failure also leaves later targets unfitted.
        for request in requests where isCurrent(request) {
            willStart(request)
        }
        for request in requests where isCurrent(request) {
            do { try await resize(request) }
            catch {
                guard isCurrent(request) else { continue }
                throw error
            }
            guard isCurrent(request) else { continue }
            didSucceed(request)
        }
    }
}
