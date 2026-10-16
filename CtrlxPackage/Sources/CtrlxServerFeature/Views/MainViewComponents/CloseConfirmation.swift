import CtrlxCommon
import CtrlxNetworking

struct CloseConfirmation {
    enum Target {
        case session(String, identity: WorkspacePaneIdentity)
        case window(LocalTmuxWindow, identity: WorkspacePaneIdentity)
        case remoteWindow(TmuxWindow, hostId: String, binding: ViewerWorkspaceInputBinding)
        case remoteSession(sessionName: String, hostId: String, binding: ViewerWorkspaceInputBinding)
    }

    let target: Target
    let runningProcesses: [RunningProcessInfo]

    /// Create from local TmuxService processes
    init(target: Target, localProcesses: [TmuxService.RunningProcess]) {
        self.target = target
        self.runningProcesses = localProcesses.map {
            RunningProcessInfo(paneIndex: $0.paneIndex, name: $0.name, isForeground: $0.isForeground)
        }
    }

    /// Create from remote RunningProcessInfo (already in wire format)
    init(target: Target, runningProcesses: [RunningProcessInfo]) {
        self.target = target
        self.runningProcesses = runningProcesses
    }

    var title: String {
        switch target {
        case .session,
             .remoteSession: "Close Session?"
        case .window,
             .remoteWindow: "Close Window?"
        }
    }

    var targetName: String {
        switch target {
        case let .session(name, _): name
        case let .window(window, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteWindow(window, _, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteSession(name, _, _): name
        }
    }

    var message: String {
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Terminal \(paneIndex): \(names)"
        }
        return "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
    }
}
