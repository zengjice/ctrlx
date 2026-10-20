#if os(macOS)
    import CtrlxCommon
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Simulator kernel process routing")
    @MainActor
    struct SimulatorRoutingTests {
        @Test("Kernel ancestors route against current tmux metadata without a full ps snapshot",
              arguments: ["live", "linked", "missing-parent", "missing-agent"])
        func liveRouting(_ scenario: String) async throws {
            func row(_ session: String) -> String {
                ["100", "%1", session, "1", "0", "codex", "/tmp", "80", "24", "1", "@1", "123:456", "", "", ""]
                    .joined(separator: String(PaneInfo.fieldSeparator))
            }
            let output = row("current") + (scenario == "linked" ? "\n" + row("linked") : "")
            let runner = ProcessRunner(run: { executable, arguments, _, _ in
                #expect(executable != "/bin/ps")
                #expect(arguments.contains("list-panes"))
                return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            })
            try await withDependencies {
                $0[ProcessRunner.self] = runner
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                var ancestors: Set<Int32> = [100, 200]
                if scenario == "missing-parent" { ancestors.remove(100) }
                if scenario == "missing-agent" { ancestors.remove(200) }
                if scenario == "live" {
                    let pane = try await service.agentBrowserPane(processID: 200, ancestorPIDs: ancestors)
                    #expect(pane.sessionName == "current")
                    #expect(pane.stableWindowId == "@1")
                    #expect(service.panes.isEmpty)
                } else {
                    do {
                        _ = try await service.agentBrowserPane(processID: 200, ancestorPIDs: ancestors)
                        Issue.record("Invalid or ambiguous ancestry must fail closed")
                    } catch let error as AgentBrowserRoutingError {
                        switch error {
                        case .ambiguousPane: #expect(scenario == "linked")
                        case .processNotInPane: #expect(scenario != "linked")
                        }
                    }
                }
            }
        }

        @Test("Multiline tmux annotations do not prevent live source routing",
              .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")))
        func multilineAnnotations() async throws {
            let tmux = "/opt/homebrew/bin/tmux"
            let socket = "/tmp/ctrlx-routing-\(UUID().uuidString).sock"
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin:/opt/homebrew/bin" })
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                @Dependency(ProcessRunner.self) var runner
                func native(_ arguments: [String]) async throws -> String {
                    let result = try await runner.run(tmux, ["-S", socket, "-f", "/dev/null"] + arguments,
                                                      ["TMUX": "", "TMUX_PANE": ""], 5)
                    try #require(result.isSuccess, Comment(rawValue: result.stderrString))
                    return result.stdoutString
                }
                _ = try await native(["new-session", "-d", "-s", "source-label-control", "/bin/sleep", "30"])
                do {
                    _ = try await native(["set-option", "-t", "source-label-control", "@ctrlx-description", "label\nsecond line"])
                    _ = try await native(["select-pane", "-t", "source-label-control", "-T", "title\nsecond line"])
                    let pidOutput = try await native(["display-message", "-p", "-t", "source-label-control", "#{pane_pid}"])
                    let pid = try #require(Int32(pidOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
                    let windowID = try await native(["display-message", "-p", "-t", "source-label-control", "#{window_id}"])
                    let service = TmuxService(tmuxPath: tmux, socketPath: socket)
                    let pane = try await service.agentBrowserPane(processID: pid, ancestorPIDs: [pid])
                    #expect(pane.sessionName == "source-label-control")
                    #expect(pane.stableWindowId == windowID.trimmingCharacters(in: .whitespacesAndNewlines))
                    #expect(service.panes.isEmpty)
                } catch {
                    _ = try await native(["kill-server"])
                    throw error
                }
                _ = try await native(["kill-server"])
            }
        }

        @Test("Malformed source records still fail closed", arguments: ["missing-fields", "bad-width"])
        func malformedRecords(_ scenario: String) async {
            let output = scenario == "missing-fields" ? "100\u{1F}%1" :
                ["100", "%1", "current", "1", "0", "codex", "/tmp", "invalid", "24", "1", "@1"]
                    .joined(separator: String(PaneInfo.fieldSeparator))
            await withDependencies {
                $0[ProcessRunner.self] = ProcessRunner(run: { _, _, _, _ in
                    ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                })
            } operation: {
                let service = TmuxService(tmuxPath: "/usr/bin/true")
                await #expect(throws: TmuxError.self) {
                    _ = try await service.agentBrowserPane(processID: 200, ancestorPIDs: [100, 200])
                }
            }
        }

        @Test("Ancestry stops at another user, PID one, and cycles")
        func ancestryBoundaries() throws {
            let uid = getuid()
            var client = SimulatorSystemClient.liveValue
            client.inspect = { pid in
                SimulatorProcess(owner: SimulatorOwner(pid: pid, uid: pid == 50 ? uid + 1 : uid,
                                                       startSeconds: 1, startMicros: 0),
                                 parentPID: pid == 200 ? 100 : 50, executable: "/bin/test")
            }
            #expect(try client.ancestors(of: 200) == [200, 100])
            #expect(try client.ancestors(of: 1).isEmpty)
            client.inspect = { pid in
                SimulatorProcess(owner: SimulatorOwner(pid: pid, uid: uid, startSeconds: 1, startMicros: 0),
                                 parentPID: pid == 200 ? 100 : 200, executable: "/bin/test")
            }
            #expect(try client.ancestors(of: 200) == [200, 100])
        }
    }
#endif
