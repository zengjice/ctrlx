import CtrlxCommon
import CtrlxNetworking
import Foundation

struct TerminalCloseConfirmation<Target>: Identifiable {
    let id = UUID()
    let target: Target
    let runningProcesses: [RunningProcessInfo]
    let inputBinding: ViewerWorkspaceInputBinding
    var closesSession = false
    var resourceSessionID: UUID? = nil

    var title: String {
        closesSession ? "Close Session?" : "Close Tab?"
    }

    var actionTitle: String {
        closesSession ? "Close Session" : "Close Anyway"
    }

    var message: String {
        if resourceSessionID != nil {
            return "Close this session and all of its terminal, Files, Browser and iOS Simulator tabs?"
        }
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Terminal \(paneIndex): \(names)"
        }
        let processes = "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
        guard closesSession else { return processes }
        let warning = "This is the last terminal tab. Closing it will close the entire session."
        return runningProcesses.isEmpty ? warning : "\(warning)\n\n\(processes)"
    }
}
