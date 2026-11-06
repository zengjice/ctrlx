#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    struct AgentDaemonRoutingTests {
        @Test("A detached Codex daemon cannot borrow the pane of its terminal UI")
        func detachedDaemonCannotBorrowPane() async throws {
            let row = [
                "100", "%1", "work", "1", "0", "codex", "/tmp", "80", "24", "1", "@1", "123:456", "", "", "",
            ].joined(separator: String(PaneInfo.fieldSeparator))
            let runner = ProcessRunner(run: { executable, _, _, _ in
                let output = executable == "/bin/ps"
                    ? "100 1 zsh\n200 100 codex\n300 1 codex\n400 300 codex\n"
                    : row
                return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            })
            try await withDependencies {
                $0[ProcessRunner.self] = runner
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                let attached = try await service.agentPaneRoute(processID: 200)
                #expect(attached.pane.paneId == "%1")
                await #expect(throws: AgentBrowserRoutingError.self) {
                    try await service.agentPaneRoute(processID: 400)
                }
            }
        }
    }
#endif
