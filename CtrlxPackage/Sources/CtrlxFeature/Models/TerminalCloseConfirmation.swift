import CtrlxNetworking

struct TerminalCloseConfirmation<Target> {
    let target: Target
    let runningProcesses: [RunningProcessInfo]

    var message: String {
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Terminal \(paneIndex): \(names)"
        }
        return "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
    }
}
