import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("Terminal close confirmation")
struct TerminalCloseConfirmationTests {
    @Test("Confirmation preserves the selected host and session")
    func targetSnapshot() {
        let confirmation = TerminalCloseConfirmation(
            target: (hostId: "office", sessionName: "coding"),
            runningProcesses: [process(paneIndex: 0, name: "codex")]
        )

        #expect(confirmation.target.hostId == "office")
        #expect(confirmation.target.sessionName == "coding")
        #expect(confirmation.message == "The following processes are still running:\nTerminal 0: codex")
    }

    @Test("Process warnings are grouped, sorted, and deduplicated")
    func processMessage() {
        let confirmation = TerminalCloseConfirmation(
            target: "window",
            runningProcesses: [
                process(paneIndex: 2, name: "sleep"),
                process(paneIndex: 0, name: "node"),
                process(paneIndex: 0, name: "codex"),
                process(paneIndex: 0, name: "node"),
            ]
        )

        #expect(confirmation.message == "The following processes are still running:\nTerminal 0: codex, node\nTerminal 2: sleep")
    }

    private func process(paneIndex: Int, name: String) -> RunningProcessInfo {
        RunningProcessInfo(paneIndex: paneIndex, name: name, isForeground: true)
    }
}
