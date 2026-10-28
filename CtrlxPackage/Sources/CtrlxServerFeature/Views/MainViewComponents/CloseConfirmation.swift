import CtrlxCommon
import CtrlxNetworking
import Foundation

struct CloseConfirmation: Identifiable {
    let id = UUID()
    enum Target {
        case resourceSession(ResourceSession, hostID: String?)
        case session(String, identity: WorkspacePaneIdentity)
        case window(LocalTmuxWindow, identity: WorkspacePaneIdentity)
        case remoteWindow(TmuxWindow, hostId: String, binding: ViewerWorkspaceInputBinding)
        case remoteSession(sessionName: String, hostId: String, binding: ViewerWorkspaceInputBinding)
    }

    let target: Target
    let runningProcesses: [RunningProcessInfo]
    let closesLastWindow: Bool

    /// Create from local TmuxService processes
    init(target: Target, localProcesses: [TmuxService.RunningProcess], closesLastWindow: Bool = false) {
        self.target = target
        self.closesLastWindow = closesLastWindow
        self.runningProcesses = localProcesses.map {
            RunningProcessInfo(paneIndex: $0.paneIndex, name: $0.name, isForeground: $0.isForeground)
        }
    }

    /// Create from remote RunningProcessInfo (already in wire format)
    init(target: Target, runningProcesses: [RunningProcessInfo], closesLastWindow: Bool = false) {
        self.target = target
        self.closesLastWindow = closesLastWindow
        self.runningProcesses = runningProcesses
    }

    var title: String {
        switch target {
        case .resourceSession,
             .session,
             .remoteSession: "Close Session?"
        case .window,
             .remoteWindow: "Close Tab?"
        }
    }

    var targetName: String {
        switch target {
        case let .resourceSession(session, _): session.name
        case let .session(name, _): name
        case let .window(window, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteWindow(window, _, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteSession(name, _, _): name
        }
    }

    var message: String {
        if case .resourceSession = target {
            return "Close this session and all of its terminal, Files, Browser and iOS Simulator tabs?"
        }
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Terminal \(paneIndex): \(names)"
        }
        let processes = "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
        guard closesLastWindow else { return processes }
        let warning = "This is the last terminal tab. Closing it will close the entire session."
        return runningProcesses.isEmpty ? warning : "\(warning)\n\n\(processes)"
    }
}
